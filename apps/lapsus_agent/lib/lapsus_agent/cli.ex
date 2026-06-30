defmodule LapsusAgent.CLI do
  @moduledoc """
  The `lps` consumer command line — a small framed dashboard + actions.

      lps                 home: balance, your recent usage, top models
      lps models [all|<q>] list network models (top 5, all, or search)
      lps ask [<#|model>] "<prompt>" [--max N]
      lps usage [--days N] what you used + per-day bars
      lps history [N]      your recent prompts (local, ~/.lapsus/history.jsonl)
      lps balance | version | update | help

  Invoked by the release launcher `bin/lps` (argv via base64 LPS_ARGV →
  `main_from_env/0`) and the `mix lapsus.*` tasks.

  Local state (opt-in): a usage/balance cache (offline fallback) and a chat
  history log, both under `~/.lapsus/`.
  """

  alias LapsusAgent.{Consumer, Version}

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

    case argv do
      [] -> cmd_home()
      [h | _] when h in ["help", "-h", "--help"] -> help()
      [v | _] when v in ["version", "--version", "-v"] -> cmd_version()
      [u | _] when u in ["update", "--update"] -> cmd_update()
      ["models" | rest] -> cmd_models(rest)
      [b | _] when b in ["balance", "whoami"] -> cmd_balance()
      ["usage" | rest] -> cmd_usage(rest)
      ["ask" | rest] -> cmd_ask(rest)
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
    howto("lps models [search]", "browse / search models")
    howto("lps history", "your recent prompts")
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
    {opts, pos} = split_opts(rest)
    max = int_opt(opts, "--max", default_max())

    {model, prompt} =
      case pos do
        [m, p | _] -> {resolve_model(m), p}
        [p] -> {pick_model(), p}
        [] -> {pick_model(), read_line("prompt> ")}
      end

    cond do
      model in [nil, ""] -> err("no model selected.")
      prompt in [nil, ""] -> err("no prompt given.")
      true -> do_ask(model, prompt, max)
    end
  end

  defp do_ask(model, prompt, max) do
    result =
      with_spinner("asking #{model} (max #{max} tokens)", fn ->
        Consumer.ask(model, prompt, max_tokens: max)
      end)

    case result do
      {:ok, res} ->
        answer = res.response || res[:reasoning] || "(empty — raise --max; the model used its budget on reasoning)"
        hdr("\n#{model}")
        IO.puts(render_md(answer))
        IO.puts("")
        IO.puts(dim("  #{num(res.in_tokens)} in / #{num(res.out_tokens)} out tok · #{billing(res)}"))

        if is_integer(res.out_tokens) and res.out_tokens >= max do
          IO.puts(dim("  ⚠ hit the #{num(max)}-token cap — answer may be cut. This is a reasoning model"))
          IO.puts(dim("    (it \"thinks\" before answering); raise it, e.g. --max 1500."))
        end

        append_history(model, prompt, res)

      {:error, :no_provider} ->
        err("No provider online for #{model} right now — try `lps models`, or again shortly.")

      {:error, :insufficient_funds} ->
        err("Not enough credits — see `lps balance` (lower --max or top up).")

      {:error, :timeout} ->
        err("The provider didn't answer in time. It may be busy or slow — try again, or a smaller --max.")

      {:error, {:provider_error, reason}} ->
        if String.contains?(to_string(reason), "busy"),
          do: err("The provider is busy with another request — try again in a moment."),
          else: err("The provider hit an error: #{reason}")

      {:error, e} ->
        err("Ask failed: #{inspect(e)}")
    end
  end

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

  defp cmd_config([]) do
    ensure_config_file()
    cfg = read_config()
    hdr("Config")
    IO.puts("  max_tokens   #{cfg["max_tokens"] || 800}")
    IO.puts("")
    IO.puts(dim("  edit this file directly → #{config_path()}"))
    IO.puts(dim("  or quick-set         → lps config max <N>"))
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
  defp cmd_config(_), do: err("usage: lps config  |  lps config init  |  lps config max <N>")

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
  defp billing(%{billed: false, cc: cc}), do: "NOT billed (#{num(cc)} CC — insufficient funds)"
  defp billing(_), do: "not billed"

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

  defp pick_model, do: pick_loop(sorted_models())

  defp pick_loop([]) do
    err("no models on the network right now.")
    nil
  end

  defp pick_loop(list) do
    shown = Enum.take(list, 5)
    IO.puts("")
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
          {n, ""} -> Enum.at(list, n - 1)
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

  defp append_history(model, prompt, res) do
    File.mkdir_p(lapsus_dir())

    line =
      Jason.encode!(%{
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
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
        "max_tokens" => "default output budget for `lps ask` (a ceiling, not a target; --max overrides per call)"
      },
      "max_tokens" => 800
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

  # Tiny Markdown → ANSI renderer for chat answers (headings, bold, code, bullets).
  defp render_md(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &md_line/1)
  end

  defp md_line(line) do
    cond do
      Regex.match?(~r/^\s*```/, line) ->
        dim(line)

      Regex.match?(~r/^\s*\#{1,6}\s+/, line) ->
        IO.ANSI.bright() <> Regex.replace(~r/^\s*\#{1,6}\s+/, line, "") <> IO.ANSI.reset()

      Regex.match?(~r/^\s*(---+|\*\*\*+)\s*$/, line) ->
        dim(String.duplicate("─", 48))

      match = Regex.run(~r/^(\s*)[-*]\s+(.*)$/, line) ->
        [_, indent, rest] = match
        indent <> "• " <> inline_md(rest)

      true ->
        inline_md(line)
    end
  end

  defp inline_md(s) do
    s
    |> then(&Regex.replace(~r/\*\*(.+?)\*\*/, &1, fn _, x -> IO.ANSI.bright() <> x <> IO.ANSI.reset() end))
    |> then(&Regex.replace(~r/`([^`]+)`/, &1, fn _, x -> IO.ANSI.bright() <> x <> IO.ANSI.reset() end))
  end

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
      lps ask [<#|model>] "<prompt>" [--max N]
                                          ask — pick by number/name, or interactive picker
      lps usage [--days N]                what you used + per-day bars
      lps history [N]                     your recent prompts (local)
      lps config [init | max <N>]         show / write / set the editable config file
      lps balance                         peer id + CC balance
      lps version                         running version + update check
      lps update                          update to the latest release (in place)
      lps help                            this help

    Examples
      lps
      lps models gemma
      lps ask 1 "what is peer-to-peer?" --max 1500
    """)
  end
end
