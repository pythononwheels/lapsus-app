defmodule LapsusAgent.CLI do
  @moduledoc """
  The `lps` consumer command line — a small framed dashboard + actions.

      lps                 home: balance, your recent usage, top models
      lps models [all|<q>] list network models (top 5, all, or search)
      lps ask [<#|model>] "<prompt>" [--max N]
      lps chat [<#|model>] multi-turn chat (context kept across turns)
      lps usage [--days N] what you used + per-day bars
      lps history [N]      your recent prompts (local, ~/.lapsus/history.jsonl)
      lps balance | version | update | help

  Invoked by the release launcher `bin/lps` (argv via base64 LPS_ARGV →
  `main_from_env/0`) and the `mix lapsus.*` tasks.

  Local state (opt-in): a usage/balance cache (offline fallback) and a chat
  history log, both under `~/.lapsus/`.
  """

  alias LapsusAgent.{Consumer, Tools, Version}
  alias LapsusCore.Credits

  # Max tool round-trips per ask before we force a final answer (bounds cost + loops).
  @max_tool_steps 4

  @bars ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  @spinner ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  @w 58

  @doc "Release launcher entry point — reads argv from the LPS_ARGV env var."
  def main_from_env do
    argv =
      case System.get_env("LPS_ARGV") do
        b when is_binary(b) and b != "" -> b |> Base.decode64!() |> String.split(<<0>>, trim: true)
        _ -> []
      end

    main(argv)
  end

  @doc "Dispatch a CLI invocation (argv is a list of strings)."
  def main(argv) do
    Logger.configure(level: :error)
    {:ok, _} = Application.ensure_all_started(:lapsus_agent)
    # New installs get an editable base config on their first lps command.
    ensure_config_file()

    case argv do
      [] -> cmd_home()
      [h | _] when h in ["help", "-h", "--help"] -> help()
      [v | _] when v in ["version", "--version", "-v"] -> cmd_version()
      [u | _] when u in ["update", "--update"] -> cmd_update()
      ["models" | rest] -> cmd_models(rest)
      [b | _] when b in ["balance", "whoami"] -> cmd_balance()
      ["usage" | rest] -> cmd_usage(rest)
      ["ask" | rest] -> cmd_ask(rest)
      ["chat" | rest] -> cmd_chat(rest)
      ["tools" | rest] -> cmd_tools(rest)
      ["projects" | _] -> cmd_projects()
      ["donate" | rest] -> cmd_donate(rest)
      ["config" | rest] -> cmd_config(rest)
      [h | n] when h in ["history", "last", "log"] -> cmd_history(n)
      [other | _] -> err("unknown command: #{other}\n"); help()
    end
  end

  # --- home dashboard ---

  defp cmd_home do
    pid = Consumer.peer_id()
    {usage, src} = fetch_usage(7)
    bal = (usage && usage["balance"]) || 0
    {models, nodes} = network_data()

    box(pid, num(bal) <> " CC")
    IO.puts("")
    print_you(usage, 7, src)
    IO.puts("")
    print_network_home(models, nodes)
    IO.puts("")
    print_howto()
  end

  defp print_network_home(all, nodes) do
    section(net_header(nodes))

    case all do
      [] ->
        IO.puts(dim("    no models online — is a provider sharing?"))

      _ ->
        shown = Enum.take(all, 5)
        IO.puts(dim("    available models:"))
        Enum.each(Enum.with_index(shown, 1), fn {m, i} -> IO.puts("      #{i}. #{model_line(m)}") end)

        if length(all) > length(shown),
          do: IO.puts(dim("      (+#{length(all) - length(shown)} more · lps models all · lps models <search>)"))
    end
  end

  defp print_howto do
    section("How to use")
    howto("lps ask 1 \"your prompt\"", "ask a model by number")
    howto("lps chat 1", "multi-turn chat (keeps context)")
    howto("lps models [search]", "browse / search models")
    howto("lps projects", "open-source projects to support")
    howto("lps help", "all commands")
  end

  defp howto(cmd, desc), do: IO.puts("    " <> String.pad_trailing(cmd, 26) <> dim(desc))

  # --- commands ---

  defp cmd_models([]) do
    {all, nodes} = network_data()
    render_models(Enum.take(all, 5), {:top, length(all)}, nodes)
  end

  defp cmd_models(["all" | _]) do
    {all, nodes} = network_data()
    render_models(all, {:all, length(all)}, nodes)
  end

  defp cmd_models([q | _]) do
    {all, nodes} = network_data()
    matches = Enum.filter(all, &String.contains?(String.downcase(&1["model"]), String.downcase(q)))
    render_models(matches, {:search, q}, nodes)
  end

  defp cmd_balance do
    pid = Consumer.peer_id()
    {u, src} = fetch_usage(1)

    box(pid, ((u && num(u["balance"] || 0)) || "?") <> " CC")
    IO.puts("")
    IO.puts("  spent today    #{num(get_in(u || %{}, ["consumer", "totals", "cc"]) || 0)} CC")
    IO.puts("  earned today   #{num(get_in(u || %{}, ["provider", "totals", "cc"]) || 0)} CC")
    if src == :cached, do: IO.puts(dim("  (cached — coordinator unreachable)"))
  end

  defp cmd_usage(rest) do
    days = int_opt(rest, "--days", 7)
    pid = Consumer.peer_id()
    {u, src} = fetch_usage(days)

    box(pid, ((u && num(u["balance"] || 0)) || "?") <> " CC")
    IO.puts("")
    print_you(u, days, src)

    pt = get_in(u || %{}, ["provider", "totals"]) || %{}

    if (pt["jobs"] || 0) > 0 do
      IO.puts("")
      IO.puts("  served #{num(pt["jobs"])} job(s) · earned #{num(pt["cc"])} CC")
    end
  end

  defp cmd_ask(rest) do
    {tools?, rest} = take_flag(rest, ["-t", "--tools"])
    {opts, pos} = split_opts(rest)
    max = int_opt(opts, "--max", default_max())
    fetch_urls = opts |> all_opts("--fetch") |> Enum.flat_map(&split_csv/1)

    {model, prompt} =
      case pos do
        [m, p | _] -> {resolve_model(m), p}
        [p] -> {default_or_pick(), p}
        [] -> {default_or_pick(), read_line("prompt> ")}
      end

    cond do
      model in [nil, ""] ->
        err("no model selected.")

      prompt in [nil, ""] ->
        err("no prompt given.")

      true ->
        show_estimate(prompt, max, fetch_urls != [] or tools?)
        # explicit: prefetch the named URLs and prepend their text as context.
        seed = if fetch_urls == [], do: prompt, else: fetch_context(fetch_urls) <> "\n\nQuestion: " <> prompt

        if tools?,
          do: with({:ok, res} <- agent_run(model, prompt, seed, max), do: append_history(model, prompt, res)),
          else: do_ask(model, prompt, seed, max)
    end
  end

  # A pre-send cost estimate: worst case is the whole output budget, billed with
  # weight 1.0 (the client doesn't know the model's real weight). `more?` flags cases
  # (--fetch / -t) where fetched pages or extra tool turns push the real cost higher.
  defp show_estimate(prompt, max, more?) do
    in_est = div(byte_size(prompt), 4) + 8
    est = Credits.cost(in_est, max, 1.0)
    plus = if more?, do: "+ pages/tools", else: ""
    IO.puts(margin(dim("≈ up to #{num(est)} CC #{plus}(max output · actual usually less)")))

    case read_cache() do
      %{"balance" => bal} when is_integer(bal) and bal > 0 and est > bal ->
        IO.puts(margin(dim("⚠ estimate exceeds your cached balance (#{num(bal)} CC) — it may not be billed")))

      _ ->
        :ok
    end
  end

  # Fetch each URL up front (explicit `--fetch`), showing per-page status, and build a
  # context block for the prompt. Unlike `-t`, this doesn't rely on the model asking.
  defp fetch_context(urls) do
    body =
      Enum.map_join(urls, "\n\n", fn url ->
        IO.puts(margin(dim("⚙ fetch_url · #{truncate(url, 60)}")))
        text = Tools.fetch_url(url)
        IO.puts(margin(dim("↳ #{obs_summary(text)}")))
        "[#{url}]\n#{text}"
      end)

    "Here are the contents of the pages I fetched:\n\n" <> body
  end

  # `shown` is echoed in the frame + saved to history (the user's question); `seed` is
  # what we actually send (may carry prefetched page text prepended to the question).
  defp do_ask(model, shown, seed, max) do
    case ask_with_spinner(model, seed, max) do
      {:ok, res} ->
        print_answer(model, shown, res, max)
        append_history(model, shown, res)

      error ->
        print_ask_error(error, model)
    end
  end

  # Shared by `ask` and `chat`: run the request behind a spinner.
  defp ask_with_spinner(model, prompt, max) do
    with_spinner("asking #{model} (max #{max} tokens)", fn ->
      Consumer.ask(model, prompt, max_tokens: max)
    end)
  end

  # Shared framed render of one answer. `shown_prompt` is what we echo in the header
  # (the user's actual message — in chat we send a larger flattened transcript).
  defp print_answer(model, shown_prompt, res, max) do
    answer = res.response || res[:reasoning] || "(empty — raise --max; the model used its budget on reasoning)"
    w = term_width()
    IO.puts("")
    IO.puts(frame_top(model, w))
    IO.puts(margin(dim("▸ " <> truncate(shown_prompt, w - 6))))
    IO.puts("")
    IO.puts(render_md(answer, w))
    IO.puts("")
    IO.puts(margin(dim("#{num(res.in_tokens)} in / #{num(res.out_tokens)} out tok · #{billing(res)}")))

    if is_integer(res.out_tokens) and res.out_tokens >= max do
      IO.puts(margin(dim("⚠ hit the #{num(max)}-token cap — raise --max, e.g. --max 1500.")))
    end

    IO.puts(frame_bottom(w))
  end

  defp print_ask_error({:error, :no_provider}, model),
    do: err("No provider online for #{model} right now — try `lps models`, or again shortly.")

  defp print_ask_error({:error, :insufficient_funds}, _),
    do: err("Not enough credits — see `lps balance` (lower --max or top up).")

  defp print_ask_error({:error, :timeout}, _),
    do: err("The provider didn't answer in time. It may be busy or slow — try again, or a smaller --max.")

  defp print_ask_error({:error, {:provider_error, reason}}, _) do
    if String.contains?(to_string(reason), "busy"),
      do: err("The provider is busy with another request — try again in a moment."),
      else: err("The provider hit an error: #{reason}")
  end

  defp print_ask_error({:error, e}, _), do: err("Ask failed: #{inspect(e)}")

  # --- tools (consumer-side ReAct loop; nothing runs on the provider) ---

  defp cmd_tools(_rest) do
    hdr("Tools — run by lps on your machine, never on a provider")
    IO.puts("")

    Enum.each(Tools.list(), fn t ->
      IO.puts("  #{IO.ANSI.bright()}#{t.name}#{IO.ANSI.reset()}  #{dim(t.desc)}")
    end)

    IO.puts("")
    IO.puts(dim("  enable per call:  lps ask -t \"summarise https://…\"   ·   lps chat -t"))
    IO.puts(dim("  the model asks for a tool, lps runs it locally and feeds the result back."))
  end

  # Drives the ReAct loop and prints the final framed answer. `shown` is echoed in the
  # frame (the user's line); `seed` seeds the transcript (raw prompt, or chat context).
  # Returns {:ok, res} on a final answer, :error otherwise.
  defp agent_run(model, shown, seed, max) do
    agent_step(model, shown, tool_preamble(seed), max, 0, 0)
  end

  defp agent_step(model, shown, transcript, max, step, acc_cc) do
    case ask_with_spinner(model, transcript, max) do
      {:ok, res} ->
        text = res.response || ""
        acc = acc_cc + (res[:cc] || 0)

        case parse_tool_call(text) do
          {:ok, name, args} when step < @max_tool_steps ->
            IO.puts(margin(dim("⚙ #{name} · #{arg_summary(args)}")))
            obs = Tools.run(name, args)
            IO.puts(margin(dim("↳ #{obs_summary(obs)}")))
            next = transcript <> "\n" <> text <> "\nRESULT: " <> obs <> "\n\nAssistant:"
            agent_step(model, shown, next, max, step + 1, acc)

          {:ok, _name, _args} ->
            # step cap reached — force one final, tool-free answer.
            forced =
              transcript <>
                "\n" <>
                text <> "\nRESULT: (tool limit reached — answer now with what you have, no TOOL line)\n\nAssistant:"

            agent_final(model, shown, forced, max, acc, step)

          :none ->
            agent_render(model, shown, res, max, acc, step)
        end

      error ->
        print_ask_error(error, model)
        :error
    end
  end

  defp agent_final(model, shown, transcript, max, acc_cc, steps) do
    case ask_with_spinner(model, transcript, max) do
      {:ok, res} -> agent_render(model, shown, res, max, acc_cc + (res[:cc] || 0), steps)
      error -> print_ask_error(error, model); :error
    end
  end

  defp agent_render(model, shown, res, max, acc_cc, steps) do
    print_answer(model, shown, res, max)
    if steps > 0, do: IO.puts(margin(dim("used #{steps} tool step(s) · #{num(acc_cc)} CC total")))
    {:ok, res}
  end

  # Tool instructions live in the *prompt text* (the wire carries no system field), so
  # the provider stays a plain text function that never knows a tool was offered.
  defp tool_preamble(seed) do
    """
    You can use tools to help answer. Available tools:
    #{Tools.spec_text()}

    To use a tool, reply with EXACTLY one line and nothing else:
    TOOL: fetch_url {"url": "https://example.com"}
    I will run it and reply with: RESULT: <text>. You may call tools multiple times.
    When you can answer, reply normally in prose with NO TOOL line.

    Question: #{seed}

    Assistant:\
    """
  end

  # Find the first `TOOL: <name> {json}` line anywhere in the reply.
  defp parse_tool_call(text) do
    case Regex.run(~r/TOOL:\s*([a-z_]+)\s*(\{[^}]*\})/i, text) do
      [_, name, json] ->
        case Jason.decode(json) do
          {:ok, args} when is_map(args) -> {:ok, name, args}
          _ -> :none
        end

      _ ->
        :none
    end
  end

  defp arg_summary(%{"url" => url}), do: truncate(url, 60)
  defp arg_summary(args), do: truncate(inspect(args), 60)

  defp obs_summary("(error:" <> _ = e), do: e
  defp obs_summary(obs), do: "#{num(String.length(obs))} chars"

  # --- chat (a multi-turn REPL; context resent each turn, bounded by config) ---

  defp cmd_chat(rest) do
    {tools?, rest} = take_flag(rest, ["-t", "--tools"])
    {opts, pos} = split_opts(rest)
    max = int_opt(opts, "--max", default_max())

    model =
      case pos do
        [m | _] -> resolve_model(m)
        [] -> default_or_pick()
      end

    cond do
      model in [nil, ""] -> err("no model selected.")
      true -> start_chat(model, max, tools?)
    end
  end

  defp start_chat(model, max, tools?) do
    w = term_width()
    label = "chat · #{model}" <> if tools?, do: " · tools", else: ""
    IO.puts("")
    IO.puts(frame_top(label, w))
    IO.puts(margin(dim("empty line or ‘exit’ to quit · context up to #{num(default_history_tokens())} tok (lps config history <N>)")))
    IO.puts(frame_bottom(w))
    chat_loop(model, max, new_thread_id(), [], tools?)
  end

  # turns :: [%{u: user_msg, a: assistant_msg}] in chronological order.
  defp chat_loop(model, max, thread, turns, tools?) do
    case read_chat_line("\nyou> ") do
      q when q in [nil, "", "exit", "quit", ":q", "/q"] ->
        IO.puts(dim("  chat ended — saved to your history (lps history)."))

      q ->
        base = build_chat_prompt(turns, q)
        result = if tools?, do: agent_run(model, q, base, max), else: plain_chat_turn(model, q, base, max)

        case result do
          {:ok, res} ->
            append_history(model, q, res, thread)
            chat_loop(model, max, thread, turns ++ [%{u: q, a: res.response || ""}], tools?)

          # stay in the chat so a transient error (busy/timeout) can be retried.
          _ ->
            chat_loop(model, max, thread, turns, tools?)
        end
    end
  end

  defp plain_chat_turn(model, shown, prompt, max) do
    case ask_with_spinner(model, prompt, max) do
      {:ok, res} -> print_answer(model, shown, res, max); {:ok, res}
      error -> print_ask_error(error, model); :error
    end
  end

  # First message → send it verbatim (identical to a plain `lps ask`). Once there's
  # history, prepend a transcript of the most recent turns that fit the token budget.
  defp build_chat_prompt([], q), do: q

  defp build_chat_prompt(turns, q) do
    included = take_within_budget(Enum.reverse(turns), default_history_tokens(), [], 0)

    transcript =
      included
      |> Enum.map_join("\n\n", fn %{u: u, a: a} -> "User: #{u}\nAssistant: #{a}" end)

    transcript <> "\n\nUser: #{q}\nAssistant:"
  end

  # Walk turns newest→oldest, keep them while the running estimate fits the budget;
  # always keep at least the most recent turn. Returns oldest→newest.
  defp take_within_budget([], _budget, acc, _sum), do: acc

  defp take_within_budget([turn | rest], budget, acc, sum) do
    cost = est_tokens(turn.u) + est_tokens(turn.a)

    if sum + cost > budget and acc != [],
      do: acc,
      else: take_within_budget(rest, budget, [turn | acc], sum + cost)
  end

  # Cheap token proxy — no local tokenizer; ~4 bytes/token is close enough to budget.
  defp est_tokens(s) when is_binary(s), do: div(byte_size(s), 4)
  defp est_tokens(_), do: 0

  defp new_thread_id, do: "t" <> Integer.to_string(System.system_time(:second))

  defp cmd_history(args) do
    n = case args do
      [s | _] -> case Integer.parse(s) do
                   {i, _} -> i
                   _ -> 10
                 end
      _ -> 10
    end

    case read_history(n) do
      [] -> IO.puts("No history yet — ask something with `lps ask`.")
      entries ->
        hdr("Your recent prompts")
        Enum.each(entries, fn e ->
          IO.puts("  #{dim(short_ts(e["ts"]))}  #{e["model"]}  #{dim(num(e["cc"] || 0) <> " CC")}")
          IO.puts("    #{truncate(e["prompt"], 64)}")
        end)
    end
  end

  # --- projects & donations (§03) ---

  defp cmd_projects do
    case Consumer.projects() do
      {:ok, %{"projects" => []}} ->
        IO.puts("No registered projects yet — see https://lapsus.pyrates.io/register")

      {:ok, %{"projects" => list}} ->
        section("Open-source projects · support with  lps donate <#> <cc>")

        list
        |> Enum.with_index(1)
        |> Enum.each(fn {p, i} ->
          IO.puts("  #{i}. #{p["name"]}  #{dim(num(p["balance"] || 0) <> " CC")}")
          IO.puts("     #{dim(p["repo_url"])}")
        end)

      {:error, e} ->
        err("Couldn't fetch projects: #{inspect(e)}")
    end
  end

  defp cmd_donate([target, amount | _]) do
    case Integer.parse(amount) do
      {cc, _} when cc > 0 -> do_donate(target, cc)
      _ -> err("usage: lps donate <#|peer_id> <cc-amount>")
    end
  end

  defp cmd_donate(_), do: err("usage: lps donate <#|peer_id> <cc-amount>  (see: lps projects)")

  defp do_donate(target, cc) do
    with {:ok, %{"projects" => list}} <- Consumer.projects(),
         {:ok, project} <- resolve_project(target, list) do
      name = project["name"] || project["peer_id"]
      IO.puts("Donating #{num(cc)} CC to #{IO.ANSI.bright()}#{name}#{IO.ANSI.reset()} …")

      case with_spinner("donating", fn -> Consumer.donate(project["peer_id"], cc) end) do
        {:ok, %{"balance" => bal}} ->
          IO.puts(margin(dim("✓ donated #{num(cc)} CC · your balance #{num(bal)} CC · thank you 💚")))

        {:error, reason} ->
          donate_error(reason)
      end
    else
      {:error, :no_such_project} -> err("no project ##{target} — see `lps projects`.")
      {:error, e} -> err("donate failed: #{inspect(e)}")
    end
  end

  # Resolve a donate target: a number picks from the list, otherwise treat it as a
  # peer id (looked up for its name, or used as-is if not in the list).
  defp resolve_project(target, list) do
    case Integer.parse(target) do
      {n, ""} ->
        case Enum.at(list, n - 1) do
          nil -> {:error, :no_such_project}
          p -> {:ok, p}
        end

      _ ->
        {:ok, Enum.find(list, %{"peer_id" => target, "name" => target}, &(&1["peer_id"] == target))}
    end
  end

  defp donate_error(%{"reason" => r}), do: donate_error(r)
  defp donate_error("insufficient_funds"), do: err("Not enough available credits — see `lps balance`.")
  defp donate_error("unknown_project"), do: err("That project isn't registered — see `lps projects`.")
  defp donate_error("self_donation"), do: err("You can't donate to your own account.")
  defp donate_error(r), do: err("Donation failed: #{r}")

  defp cmd_config([]) do
    ensure_config_file()
    cfg = read_config()
    hdr("Config")
    IO.puts("  max_tokens          #{cfg["max_tokens"] || 800}")
    IO.puts("  default_model       #{model_display(cfg["default_model"])}")
    IO.puts("  max_history_tokens  #{cfg["max_history_tokens"] || 2000}")
    IO.puts("")
    IO.puts(dim("  edit directly → #{config_path()}"))
    IO.puts(dim("  or: lps config max <N> · model <#|name> · history <N>"))
  end

  defp cmd_config(["init" | _]) do
    write_config(Map.merge(config_template(), Map.drop(read_config(), ["_help"])))
    IO.puts("Wrote an editable config (all defaults + notes) → #{config_path()}")
  end

  defp cmd_config(["max", v | _]) do
    case Integer.parse(v) do
      {n, _} when n > 0 ->
        write_config(Map.put(read_config(), "max_tokens", n))
        IO.puts("Default ask budget set to #{num(n)} tokens (override per-call with --max).")

      _ ->
        err("usage: lps config max <number>")
    end
  end

  defp cmd_config(["max"]), do: IO.puts("max_tokens = #{read_config()["max_tokens"] || "800 (default)"}")

  defp cmd_config(["model", m | _]) when m in ["none", "clear"] do
    write_config(Map.put(read_config(), "default_model", ""))
    IO.puts("Default model cleared — lps ask will show the picker.")
  end

  defp cmd_config(["model", v | _]) do
    name = resolve_model(v) || v
    write_config(Map.put(read_config(), "default_model", name))
    IO.puts("Default model set to #{name} — lps ask can now skip the picker.")
  end

  defp cmd_config(["history", v | _]) do
    case Integer.parse(v) do
      {n, _} when n > 0 ->
        write_config(Map.put(read_config(), "max_history_tokens", n))
        IO.puts("Chat context budget set to #{num(n)} tokens (resent each turn in lps chat).")

      _ ->
        err("usage: lps config history <number>")
    end
  end

  defp cmd_config(["history"]),
    do: IO.puts("max_history_tokens = #{read_config()["max_history_tokens"] || "2000 (default)"}")

  defp cmd_config(["model"]), do: IO.puts("default_model = #{model_display(read_config()["default_model"])}")
  defp cmd_config(_), do: err("usage: lps config [init | max <N> | model <#|name|none>]")

  defp model_display(m) when is_binary(m) and m != "", do: m
  defp model_display(_), do: "(none — picker)"

  defp cmd_version do
    IO.puts("lps #{Version.current()}")

    case Version.check_update() do
      {:update, tag, _} -> IO.puts(dim("  update available — #{tag}   (run: lps update)"))
      :current -> IO.puts(dim("  up to date ✓"))
      {:dev, tag, _} -> IO.puts(dim("  dev build · latest published is #{tag}"))
      :dev -> IO.puts(dim("  dev build"))
      _ -> IO.puts(dim("  (couldn't check for updates)"))
    end
  end

  defp cmd_update do
    case Version.check_update() do
      {:update, tag, _} ->
        IO.puts("Updating to #{tag} …")

        {_, status} =
          System.cmd("sh", ["-c", "curl -fsSL https://lapsus.pyrates.io/install.sh | sh"],
            into: IO.stream(:stdio, :line),
            stderr_to_stdout: true
          )

        if status == 0,
          do: IO.puts(dim("\nDone — run `lps version` to confirm.")),
          else: err("update failed (installer exit #{status}).")

      :current ->
        IO.puts("Already up to date (#{Version.current()}).")

      x when x in [:dev] or (is_tuple(x) and elem(x, 0) == :dev) ->
        IO.puts("Dev build — nothing to update.")

      _ ->
        err("couldn't check for updates (offline or GitHub unreachable).")
    end
  end

  defp billing(%{billed: true, cc: cc, balance: bal}), do: "#{num(cc)} CC charged · balance #{num(bal)} CC"

  # Show the *actual* settlement failure reason, not a hardcoded one.
  defp billing(%{billed: false, cc: cc, billing_error: err}),
    do: "NOT billed (#{num(cc)} CC — #{billing_reason(err)})"

  defp billing(%{billed: false, cc: cc}), do: "NOT billed (#{num(cc)} CC — settlement failed)"
  defp billing(_), do: "not billed (no receipt)"

  defp billing_reason(%{"reason" => r}), do: billing_reason(r)
  defp billing_reason("insufficient_funds"), do: "insufficient funds"
  defp billing_reason("duplicate_job"), do: "already booked (duplicate)"
  defp billing_reason("invalid_" <> what), do: "rejected — invalid #{what}"
  defp billing_reason(other), do: to_string(other)

  # --- models ---

  # One coordinator round-trip → {models sorted by provider count, nodes online}.
  defp network_data do
    case Consumer.network() do
      {:ok, %{"models" => models} = r} ->
        {Enum.sort_by(models, &{-(&1["providers"] || 0), -(&1["ctx"] || 0)}), r["nodes"]}

      _ ->
        {[], nil}
    end
  end

  defp sorted_models, do: elem(network_data(), 0)

  defp net_header(nodes) when is_integer(nodes) and nodes > 0,
    do: "LAPSUS P2P network · #{nodes} #{if nodes == 1, do: "node", else: "nodes"} active"

  defp net_header(_), do: "LAPSUS P2P network"

  # Full `lps models` view — P2P network header + "available models".
  defp render_models([], {:search, q}, nodes) do
    section(net_header(nodes))
    IO.puts(dim("    no models match \"#{q}\"."))
  end

  defp render_models([], _mode, nodes) do
    section(net_header(nodes))
    IO.puts(dim("    no models online — is a provider sharing?"))
  end

  defp render_models(models, mode, nodes) do
    sub =
      case mode do
        {:top, total} -> "available models · top #{length(models)} of #{total}"
        {:all, total} -> "available models · all #{total}"
        {:search, q} -> "available models matching \"#{q}\" (#{length(models)})"
      end

    section(net_header(nodes))
    IO.puts(dim("    " <> sub <> ":"))
    Enum.each(Enum.with_index(models, 1), fn {m, i} -> IO.puts("      #{i}. #{model_line(m)}") end)

    case mode do
      {:top, total} when total > length(models) ->
        IO.puts(dim("      (+#{total - length(models)} more · lps models all · lps models <search>)"))

      _ ->
        :ok
    end
  end

  defp model_line(m) do
    caps =
      [ctx_k(m["ctx"]), m["multimodal"] && "multimodal", provider_count(m["providers"])]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    "#{m["model"]}   #{dim(caps)}"
  end

  defp ctx_k(nil), do: nil
  defp ctx_k(c) when c >= 1000, do: "ctx #{round(c / 1000)}k"
  defp ctx_k(c), do: "ctx #{c}"

  defp provider_count(1), do: "1 provider"
  defp provider_count(n) when is_integer(n), do: "#{n} providers"
  defp provider_count(_), do: "1 provider"

  # --- interactive picker (number or search) ---

  # Model when none is given on the command line: the config default, else the picker.
  defp default_or_pick do
    case read_config()["default_model"] do
      m when is_binary(m) and m != "" -> m
      _ -> pick_model()
    end
  end

  defp pick_model, do: pick_loop(sorted_models())

  defp pick_loop([]) do
    err("no models on the network right now.")
    nil
  end

  defp pick_loop(list) do
    shown = Enum.take(list, 5)
    IO.puts("")
    section("Pick a model")
    Enum.each(Enum.with_index(shown, 1), fn {m, i} -> IO.puts("  #{i}. #{model_line(m)}") end)
    if length(list) > 5, do: IO.puts(dim("  (#{length(list)} total — type a word to search)"))

    case read_line("\npick # or search: ") do
      nil ->
        err("no selection (try: lps ask <#|model> \"prompt\").")
        nil

      "" ->
        nil

      input ->
        case Integer.parse(input) do
          {n, ""} ->
            case Enum.at(list, n - 1) do
              %{"model" => name} -> name
              _ -> err("no model ##{n} in the list."); nil
            end

          _ ->
            filtered = Enum.filter(sorted_models(), &String.contains?(String.downcase(&1["model"]), String.downcase(input)))
            if filtered == [], do: (IO.puts(dim("  no match — showing all")); pick_loop(sorted_models())), else: pick_loop(filtered)
        end
    end
  end

  defp resolve_model(token) do
    if Regex.match?(~r/^\d+$/, token),
      do: sorted_models() |> Enum.at(String.to_integer(token) - 1) |> then(&(&1 && &1["model"])),
      else: token
  end

  # --- "You" block (usage) ---

  defp print_you(nil, days, _src) do
    section("Usage stats · last #{days}d")
    IO.puts(dim("    no data (coordinator unreachable, no cache)"))
  end

  defp print_you(u, days, src) do
    ct = get_in(u, ["consumer", "totals"]) || %{}
    suffix = if src == :cached, do: dim(" (cached)"), else: ""
    section("Usage stats · last #{days}d", suffix)
    IO.puts("    #{num(ct["jobs"] || 0)} req · #{num(ct["cc"] || 0)} CC   #{spark(get_in(u, ["consumer", "days"]) || [])}")
    print_by_model(get_in(u, ["consumer", "by_model"]) || [])
  end

  defp print_by_model([]), do: :ok

  defp print_by_model(rows) do
    rows
    |> Enum.take(3)
    |> Enum.each(fn r -> IO.puts(dim("      #{r["model"]}  #{num(r["jobs"] || 0)} req · #{num(r["cc"] || 0)} CC")) end)
  end

  defp spark([]), do: ""

  defp spark(days) do
    vals = Enum.map(days, &((&1["in"] || 0) + (&1["out"] || 0)))
    maxv = Enum.max(vals, fn -> 0 end)

    vals
    |> Enum.map(fn v -> if maxv == 0, do: hd(@bars), else: Enum.at(@bars, round(v / maxv * (length(@bars) - 1))) end)
    |> Enum.join("")
  end

  # --- usage cache (offline fallback) ---

  defp fetch_usage(days) do
    case Consumer.full_usage(days) do
      {:ok, u} -> write_cache(days, u); {u, :live}
      _ -> {read_cache(), :cached}
    end
  end

  defp write_cache(days, usage) do
    File.mkdir_p(lapsus_dir())
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    File.write(cache_path(), Jason.encode!(%{"fetched_at" => ts, "days" => days, "usage" => usage}))
  rescue
    _ -> :ok
  end

  defp read_cache do
    with {:ok, raw} <- File.read(cache_path()),
         {:ok, %{"usage" => u}} <- Jason.decode(raw) do
      u
    else
      _ -> nil
    end
  end

  # --- chat history (local) ---

  defp append_history(model, prompt, res, thread \\ nil) do
    File.mkdir_p(lapsus_dir())

    line =
      Jason.encode!(%{
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "thread" => thread,
        "model" => model,
        "prompt" => prompt,
        "response" => res.response,
        "in" => res.in_tokens,
        "out" => res.out_tokens,
        "cc" => res[:cc],
        "billed" => res[:billed]
      })

    File.write(history_path(), line <> "\n", [:append])
  rescue
    _ -> :ok
  end

  defp read_history(n) do
    case File.read(history_path()) do
      {:ok, raw} ->
        raw
        |> String.split("\n", trim: true)
        |> Enum.map(&safe_decode/1)
        |> Enum.filter(& &1)
        |> Enum.take(-n)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  defp safe_decode(line) do
    case Jason.decode(line) do
      {:ok, m} -> m
      _ -> nil
    end
  end

  # --- paths ---

  defp lapsus_dir do
    case System.get_env("LAPSUS_IDENTITY") do
      p when is_binary(p) and p != "" -> Path.dirname(p)
      _ -> Path.join(System.user_home!() || ".", ".lapsus")
    end
  end

  defp cache_path, do: Path.join(lapsus_dir(), "usage-cache.json")
  defp history_path, do: Path.join(lapsus_dir(), "history.jsonl")
  defp config_path, do: Path.join(lapsus_dir(), "config.json")

  # --- CLI config (~/.lapsus/config.json) ---

  defp read_config do
    with {:ok, raw} <- File.read(config_path()),
         {:ok, map} when is_map(map) <- Jason.decode(raw) do
      map
    else
      _ -> %{}
    end
  end

  defp write_config(map) do
    File.mkdir_p(lapsus_dir())
    File.write(config_path(), Jason.encode!(map, pretty: true) <> "\n")
  rescue
    _ -> :ok
  end

  # A full, self-documenting config (all keys at their defaults + a `_help` block),
  # so the file explains itself when edited by hand. Reader ignores `_help`.
  defp config_template do
    %{
      "_help" => %{
        "max_tokens" => "default output budget for `lps ask` (a ceiling, not a target; --max overrides per call)",
        "default_model" => "model `lps ask` uses when you don't name one (empty = show the picker)",
        "max_history_tokens" => "tokens of prior conversation `lps chat` resends as context each turn — you pay for these as input, so higher = more memory, more cost"
      },
      "max_tokens" => 800,
      "default_model" => "",
      "max_history_tokens" => 2000
    }
  end

  # Make sure an editable config file exists (keeps any values the user already set).
  defp ensure_config_file do
    unless File.exists?(config_path()) do
      write_config(Map.merge(config_template(), Map.drop(read_config(), ["_help"])))
    end
  end

  # Default ask budget: config max_tokens, else 800. --max always overrides.
  defp default_max do
    case read_config()["max_tokens"] do
      n when is_integer(n) and n > 0 -> n
      _ -> 800
    end
  end

  # How many tokens of prior chat `lps chat` resends as context. Config, else 2000.
  defp default_history_tokens do
    case read_config()["max_history_tokens"] do
      n when is_integer(n) and n > 0 -> n
      _ -> 2000
    end
  end

  # --- rendering helpers ---

  # A two-line header box: title bar + "left … right" line.
  defp box(left, right) do
    inner = @w - 2
    title = " LAPSUS "
    IO.puts("╭─" <> title <> String.duplicate("─", max(0, @w - 3 - String.length(title))) <> "╮")
    content = pad_lr("id  " <> short(left), right, inner - 2)
    IO.puts("│ " <> content <> " │")
    IO.puts("╰" <> String.duplicate("─", inner) <> "╯")
  end

  defp pad_lr(left, right, width) do
    gap = max(1, width - String.length(left) - String.length(right))
    left <> String.duplicate(" ", gap) <> right
  end

  defp truncate(nil, _), do: ""
  defp truncate(s, n) when byte_size(s) > n, do: String.slice(s, 0, n - 1) <> "…"
  defp truncate(s, _), do: s

  defp short_ts(nil), do: ""
  defp short_ts(iso), do: String.slice(iso, 5, 11) |> String.replace("T", " ")

  defp short(id) when is_binary(id) and byte_size(id) > 18,
    do: String.slice(id, 0, 10) <> "…" <> String.slice(id, -4, 4)

  defp short(id), do: id

  defp num(n) when is_integer(n) and n < 0, do: "-" <> num(-n)

  defp num(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp num(n), do: to_string(n)

  defp int_opt(args, flag, default) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> default
      i -> with v when is_binary(v) <- Enum.at(args, i + 1), {n, _} <- Integer.parse(v), do: n, else: (_ -> default)
    end
  end

  # Pull a boolean flag (any of `names`) out of argv; returns {present?, remaining}.
  defp take_flag(args, names) do
    if Enum.any?(args, &(&1 in names)),
      do: {true, Enum.reject(args, &(&1 in names))},
      else: {false, args}
  end

  # All values given for a repeatable `--flag v` option (opts is a flat [f, v, …] list).
  defp all_opts(opts, flag) do
    opts
    |> Enum.chunk_every(2)
    |> Enum.filter(&match?([^flag, _], &1))
    |> Enum.map(fn [_, v] -> v end)
  end

  defp split_csv(s), do: s |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp split_opts(args), do: do_split(args, [], [])
  defp do_split([], opts, pos), do: {Enum.reverse(opts), Enum.reverse(pos)}
  defp do_split(["--" <> _ = f, v | rest], opts, pos), do: do_split(rest, [v, f | opts], pos)
  defp do_split([p | rest], opts, pos), do: do_split(rest, opts, [p | pos])

  defp read_line(prompt) do
    case IO.gets(prompt) do
      s when is_binary(s) -> String.trim(s)
      _ -> nil
    end
  end

  # A small line editor for the chat prompt: Shift+Enter inserts a newline, Enter
  # submits. Uses raw terminal mode when available; on any failure it falls back to a
  # plain `IO.gets` line read, so the chat never breaks. Returns the trimmed input, or
  # nil on EOF/Ctrl+C.
  defp read_chat_line(prompt) do
    IO.write(prompt)

    case enable_raw() do
      {:ok, saved} ->
        try do
          edit_loop("")
        catch
          :cancel -> nil
        after
          disable_raw(saved)
        end

      :error ->
        # prompt already printed; fall back to a normal line read (no multi-line)
        case IO.gets("") do
          s when is_binary(s) -> String.trim(s)
          _ -> nil
        end
    end
  end

  defp enable_raw do
    with {saved, 0} <- System.cmd("sh", ["-c", "stty -g < /dev/tty 2>/dev/null"]),
         {_, 0} <- System.cmd("sh", ["-c", "stty -icanon -echo min 1 time 0 < /dev/tty 2>/dev/null"]) do
      {:ok, String.trim(saved)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp disable_raw(saved), do: System.cmd("sh", ["-c", "stty #{saved} < /dev/tty 2>/dev/null"])

  # Character-at-a-time edit loop over the raw tty. `acc` is the input so far.
  defp edit_loop(acc) do
    case IO.getn("", 1) do
      :eof ->
        String.trim(acc)

      <<c>> when c in [0x0D, 0x0A] ->
        IO.write("\n")
        String.trim(acc)

      # Ctrl+C / Ctrl+D (on empty) → cancel
      <<0x03>> ->
        IO.write("\n")
        throw(:cancel)

      <<0x04>> ->
        if acc == "", do: throw(:cancel), else: edit_loop(acc)

      # Backspace / Delete
      <<c>> when c in [0x7F, 0x08] ->
        edit_loop(backspace(acc))

      # ESC — could be Shift+Enter or an arrow/other escape sequence
      <<0x1B>> ->
        edit_loop(handle_esc(acc))

      # any printable char (getn returns a full UTF-8 grapheme)
      ch when is_binary(ch) ->
        IO.write(ch)
        edit_loop(acc <> ch)
    end
  end

  defp backspace(""), do: ""

  defp backspace(acc) do
    {keep, last} = String.split_at(acc, -1)
    # can't visually un-wrap a previous newline; just drop it from the buffer
    unless last == "\n", do: IO.write("\b \b")
    keep
  end

  # After an ESC: ESC+CR/LF is Shift+Enter (this terminal) → newline; a CSI sequence
  # (arrows etc.) is consumed and ignored, unless it encodes a modified Enter.
  defp handle_esc(acc) do
    case IO.getn("", 1) do
      <<c>> when c in [0x0D, 0x0A] ->
        IO.write("\n")
        acc <> "\n"

      <<?[>> ->
        seq = consume_csi("")

        if shift_enter_csi?(seq) do
          IO.write("\n")
          acc <> "\n"
        else
          acc
        end

      <<?O>> ->
        _ = IO.getn("", 1)
        acc

      _ ->
        acc
    end
  end

  # Read a CSI sequence up to and including its final byte (0x40–0x7e).
  defp consume_csi(seq) do
    case IO.getn("", 1) do
      :eof -> seq
      <<c>> when c in 0x40..0x7E -> seq <> <<c>>
      <<c>> -> consume_csi(seq <> <<c>>)
      _ -> seq
    end
  end

  # xterm modifyOtherKeys (27;2;13~) or kitty (13;2u) encodings of Shift+Enter.
  defp shift_enter_csi?(seq), do: String.contains?(seq, "27;2;13") or String.contains?(seq, "13;2")

  # Run `fun` while animating a small spinner on stderr; clears the line when done.
  # stderr keeps stdout (and pipes like `| head`) clean.
  defp with_spinner(label, fun) do
    task = Task.async(fun)
    spin(task, label, 0)
  end

  defp spin(task, label, i) do
    case Task.yield(task, 90) do
      {:ok, result} -> IO.write(:stderr, "\r\e[K"); result
      {:exit, reason} -> IO.write(:stderr, "\r\e[K"); {:error, reason}
      nil ->
        frame = Enum.at(@spinner, rem(i, length(@spinner)))
        IO.write(:stderr, "\r" <> dim("#{frame} #{label}…"))
        spin(task, label, i + 1)
    end
  end

  # Markdown → ANSI for chat answers: word-wrapped to a readable width, with a
  # 2-space margin and hanging indents for lists.
  defp render_md(text, width) do
    cw = max(width - 4, 24)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", &md_line(&1, cw))
  end

  defp md_line(line, cw) do
    cond do
      Regex.match?(~r/^\s*```/, line) ->
        margin(dim(line))

      Regex.match?(~r/^\s*\#{1,6}\s+/, line) ->
        line
        |> then(&Regex.replace(~r/^\s*\#{1,6}\s+/, &1, ""))
        |> wrap_words(cw)
        |> Enum.map_join("\n", &margin(IO.ANSI.bright() <> &1 <> IO.ANSI.reset()))

      Regex.match?(~r/^\s*(---+|\*\*\*+)\s*$/, line) ->
        margin(dim(String.duplicate("─", min(cw, 48))))

      m = Regex.run(~r/^(\s*)[-*]\s+(.*)$/, line) ->
        [_, indent, rest] = m
        list_item(indent, "• ", inline_md(rest), cw)

      m = Regex.run(~r/^(\s*)(\d+\.)\s+(.*)$/, line) ->
        [_, indent, num, rest] = m
        list_item(indent, num <> " ", inline_md(rest), cw)

      String.trim(line) == "" ->
        ""

      true ->
        line |> inline_md() |> wrap_words(cw) |> Enum.map_join("\n", &margin/1)
    end
  end

  # A list item with a hanging indent: continuation lines align under the text.
  defp list_item(indent, marker, text, cw) do
    avail = max(cw - String.length(indent) - String.length(marker), 12)
    [first | more] = wrap_words(text, avail)
    hang = indent <> String.duplicate(" ", String.length(marker))

    ([indent <> marker <> first] ++ Enum.map(more, &(hang <> &1)))
    |> Enum.map_join("\n", &margin/1)
  end

  # Word-wrap ANSI-containing text to `width` *visible* columns → list of lines.
  defp wrap_words(text, width) do
    {lines, cur} =
      text
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce({[], ""}, fn word, {lines, cur} ->
        cond do
          cur == "" -> {lines, word}
          vlen(cur) + 1 + vlen(word) <= width -> {lines, cur <> " " <> word}
          true -> {[cur | lines], word}
        end
      end)

    Enum.reverse([cur | lines])
  end

  defp vlen(s), do: s |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.length()

  defp inline_md(s) do
    s
    |> then(&Regex.replace(~r/\*\*(.+?)\*\*/, &1, fn _, x -> IO.ANSI.bright() <> x <> IO.ANSI.reset() end))
    |> then(&Regex.replace(~r/`([^`]+)`/, &1, fn _, x -> IO.ANSI.bright() <> x <> IO.ANSI.reset() end))
  end

  defp margin(s), do: "  " <> s

  # Terminal width for wrapping (falls back to 80; capped at 92 for readability).
  defp term_width do
    case :io.columns() do
      {:ok, c} -> c |> max(40) |> min(92)
      _ -> 80
    end
  end

  defp frame_top(label, w) do
    vis = 2 + String.length(label) + 1

    IO.ANSI.faint() <>
      "─ " <>
      IO.ANSI.reset() <>
      IO.ANSI.bright() <>
      label <>
      IO.ANSI.reset() <>
      " " <> IO.ANSI.faint() <> String.duplicate("─", max(w - vis, 0)) <> IO.ANSI.reset()
  end

  defp frame_bottom(w), do: dim(String.duplicate("─", w))

  defp hdr(s), do: IO.puts(IO.ANSI.bright() <> s <> IO.ANSI.reset())
  defp hdr_s(s), do: "  " <> IO.ANSI.bright() <> s <> IO.ANSI.reset()

  # A bold section header with a thin rule under it.
  defp section(title, suffix \\ "") do
    IO.puts(hdr_s(title) <> suffix)
    IO.puts("  " <> dim(String.duplicate("─", 54)))
  end
  defp dim(s), do: IO.ANSI.faint() <> s <> IO.ANSI.reset()
  defp err(s), do: IO.puts(:stderr, IO.ANSI.red() <> s <> IO.ANSI.reset())

  defp help do
    IO.puts("""
    #{IO.ANSI.bright()}lps#{IO.ANSI.reset()} — LAPSUS consumer CLI

      lps                                 home: balance · your usage · top models
      lps models [all | <search>]         list models (top 5 by providers, all, or search)
      lps ask [<#|model>] "<prompt>" [--max N] [-t] [--fetch <url,url>]
                                          ask — pick by number/name, or interactive picker
                                          -t: let the model fetch on its own (implicit)
                                          --fetch: pre-fetch these URLs as context (explicit)
      lps chat [<#|model>] [--max N]      multi-turn chat (keeps context across turns)
                                          add -t to let the model use tools (web fetch)
      lps tools                           list consumer-side tools (run locally by lps)
      lps projects                        open-source projects you can support (§03)
      lps donate <#|peer_id> <cc>         donate credits to a registered project
      lps usage [--days N]                what you used + per-day bars
      lps history [N]                     your recent prompts (local)
      lps config [max <N> | model <m> | history <N>]
                                          show / set defaults (ask budget, model, chat context)
      lps balance                         peer id + CC balance
      lps version                         running version + update check
      lps update                          update to the latest release (in place)
      lps help                            this help

    Examples
      lps
      lps models gemma
      lps ask 1 "what is peer-to-peer?" --max 1500
      lps ask -t "summarise https://example.com"
      lps ask --fetch https://a.io,https://b.io "compare the h1 of these pages"
    """)
  end
end
