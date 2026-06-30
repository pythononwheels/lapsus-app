defmodule LapsusAgent.CLI do
  @moduledoc """
  The `lps` consumer command line — list models, check balance, ask, see usage.

  Invoked two ways, both routing through `main/1`:
    * the release launcher `bin/lps`, which base64-encodes argv into `LPS_ARGV`
      and calls `main_from_env/0`;
    * the `mix lapsus.*` tasks in dev.
  """

  alias LapsusAgent.Consumer

  @bars ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

  @doc "Release launcher entry point — reads argv from the LPS_ARGV env var."
  def main_from_env do
    argv =
      case System.get_env("LPS_ARGV") do
        b when is_binary(b) and b != "" ->
          b |> Base.decode64!() |> String.split(<<0>>, trim: true)

        _ ->
          []
      end

    main(argv)
  end

  @doc "Dispatch a CLI invocation (argv is a list of strings)."
  def main(argv) do
    # Quiet the local-engine probe / reconnect warnings so CLI output stays clean.
    Logger.configure(level: :error)
    {:ok, _} = Application.ensure_all_started(:lapsus_agent)

    case argv do
      [] -> help()
      [h | _] when h in ["help", "-h", "--help"] -> help()
      ["models" | _] -> cmd_models()
      ["balance" | _] -> cmd_balance()
      ["whoami" | _] -> cmd_balance()
      ["usage" | rest] -> cmd_usage(rest)
      ["ask" | rest] -> cmd_ask(rest)
      [other | _] -> err("unknown command: #{other}\n"); help()
    end
  end

  # --- commands ---

  defp cmd_models do
    case Consumer.network_models() do
      {:ok, []} -> IO.puts("No models on the network right now — is a provider online and sharing?")
      {:ok, models} -> print_models(models)
      {:error, e} -> err("couldn't reach the coordinator: #{inspect(e)}")
    end
  end

  defp cmd_balance do
    pid = Consumer.peer_id()

    case Consumer.full_usage(1) do
      {:ok, u} ->
        hdr("LAPSUS · #{short(pid)}")
        IO.puts("  balance       #{num(u["balance"] || 0)} CC")
        IO.puts("  spent today   #{num(get_in(u, ["consumer", "totals", "cc"]) || 0)} CC")
        IO.puts("  earned today  #{num(get_in(u, ["provider", "totals", "cc"]) || 0)} CC")

      {:error, e} ->
        err("couldn't reach the coordinator: #{inspect(e)}")
    end
  end

  defp cmd_usage(rest) do
    days = int_opt(rest, "--days", 7)
    pid = Consumer.peer_id()

    case Consumer.full_usage(days) do
      {:ok, u} ->
        cons = u["consumer"] || %{}
        prov = u["provider"] || %{}
        ct = cons["totals"] || %{}
        pt = prov["totals"] || %{}

        hdr("LAPSUS · #{short(pid)}    balance #{num(u["balance"] || 0)} CC")
        IO.puts(dim("  last #{days} day(s)"))
        IO.puts("")
        IO.puts("  used   #{num(ct["jobs"] || 0)} req(s) · #{num(ct["cc"] || 0)} CC · #{num(ct["in"] || 0)} in / #{num(ct["out"] || 0)} out tok")
        spark(cons["days"] || [])
        print_by_model(cons["by_model"] || [])

        if (pt["jobs"] || 0) > 0 do
          IO.puts("")
          IO.puts("  served #{num(pt["jobs"])} job(s) · earned #{num(pt["cc"])} CC")
        end

      {:error, e} ->
        err("couldn't reach the coordinator: #{inspect(e)}")
    end
  end

  defp cmd_ask(rest) do
    {opts, pos} = split_opts(rest)
    max = int_opt(opts, "--max", 300)

    {model, prompt} =
      case pos do
        [m, p | _] -> {resolve_model(m), p}
        [p] -> {pick_model(), p}
        [] -> {pick_model(), read_prompt()}
      end

    cond do
      model in [nil, ""] -> err("no model selected.")
      prompt in [nil, ""] -> err("no prompt given.")
      true -> do_ask(model, prompt, max)
    end
  end

  defp do_ask(model, prompt, max) do
    IO.puts(dim("asking #{model} (max #{max} tokens)…"))

    case Consumer.ask(model, prompt, max_tokens: max) do
      {:ok, res} ->
        hdr("\n#{model}")
        IO.puts(res.response || res[:reasoning] || "(empty — raise --max; the model spent its budget on reasoning)")
        IO.puts("")
        IO.puts(dim("  #{num(res.in_tokens)} in / #{num(res.out_tokens)} out tok · #{billing(res)}"))

      {:error, :no_provider} ->
        err("no provider online for #{model} right now.")

      {:error, :insufficient_funds} ->
        err("insufficient funds — check `lps balance` (lower --max or top up).")

      {:error, e} ->
        err("ask failed: #{inspect(e)}")
    end
  end

  defp billing(%{billed: true, cc: cc, balance: bal}), do: "#{num(cc)} CC charged · balance #{num(bal)} CC"
  defp billing(%{billed: false, cc: cc}), do: "NOT billed (#{num(cc)} CC — insufficient funds)"
  defp billing(_), do: "not billed"

  # --- model selection ---

  defp resolve_model(token) do
    if Regex.match?(~r/^\d+$/, token) do
      case Consumer.network_models() do
        {:ok, models} -> models |> Enum.map(& &1["model"]) |> Enum.at(String.to_integer(token) - 1)
        _ -> nil
      end
    else
      token
    end
  end

  defp pick_model do
    case Consumer.network_models() do
      {:ok, []} ->
        err("no models on the network right now.")
        nil

      {:ok, models} ->
        print_models(models)
        names = Enum.map(models, & &1["model"])

        case IO.gets("\npick a model #: ") do
          input when is_binary(input) ->
            case Integer.parse(String.trim(input)) do
              {n, _} -> Enum.at(names, n - 1)
              :error -> err("not a number."); nil
            end

          _ ->
            err("no selection (need a model: `lps ask <#|model> \"prompt\"`).")
            nil
        end

      {:error, e} ->
        err("couldn't reach the coordinator: #{inspect(e)}")
        nil
    end
  end

  defp read_prompt do
    case IO.gets("prompt> ") do
      input when is_binary(input) -> String.trim(input)
      _ -> nil
    end
  end

  # --- rendering ---

  defp print_models(models) do
    hdr("Models on the network")

    models
    |> Enum.with_index(1)
    |> Enum.each(fn {m, i} ->
      caps =
        [
          "ctx #{num(m["ctx"] || 0)}",
          m["multimodal"] && "multimodal",
          "#{m["providers"] || 1} provider(s)"
        ]
        |> Enum.filter(& &1)
        |> Enum.join(" · ")

      IO.puts("  #{i}. #{m["model"]}   #{dim(caps)}")
    end)
  end

  defp print_by_model([]), do: :ok

  defp print_by_model(rows) do
    IO.puts(dim("  by model"))

    Enum.each(rows, fn r ->
      IO.puts("    #{r["model"]}   #{num(r["jobs"] || 0)} req(s) · #{num(r["cc"] || 0)} CC")
    end)
  end

  # Tiny sparkline of total tokens (in+out) per day.
  defp spark([]), do: :ok

  defp spark(days) do
    vals = Enum.map(days, &((&1["in"] || 0) + (&1["out"] || 0)))
    maxv = Enum.max(vals, fn -> 0 end)

    line =
      vals
      |> Enum.map(fn v ->
        if maxv == 0, do: Enum.at(@bars, 0), else: Enum.at(@bars, round(v / maxv * (length(@bars) - 1)))
      end)
      |> Enum.join(" ")

    first = days |> List.first() |> then(&(&1 && short_date(&1["date"]))) || ""
    last = days |> List.last() |> then(&(&1 && short_date(&1["date"]))) || ""
    IO.puts("  #{line}")
    IO.puts(dim("  #{first}#{String.duplicate(" ", max(1, byte_size(line) - byte_size(first) - byte_size(last)))}#{last}  (tokens/day)"))
  end

  defp short_date(nil), do: ""
  defp short_date(iso), do: String.slice(iso, 5, 5)

  # --- helpers ---

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

  # First "--flag value" pair matching `flag`, else default.
  defp int_opt(args, flag, default) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> default
      i -> with v when is_binary(v) <- Enum.at(args, i + 1), {n, _} <- Integer.parse(v), do: n, else: (_ -> default)
    end
  end

  # Split argv into {flag-args, positional-args}; flags are "--x value" pairs.
  defp split_opts(args), do: do_split(args, [], [])
  defp do_split([], opts, pos), do: {Enum.reverse(opts), Enum.reverse(pos)}

  defp do_split(["--" <> _ = f, v | rest], opts, pos),
    do: do_split(rest, [v, f | opts], pos)

  defp do_split([p | rest], opts, pos), do: do_split(rest, opts, [p | pos])

  defp hdr(s), do: IO.puts(IO.ANSI.bright() <> s <> IO.ANSI.reset())
  defp dim(s), do: IO.ANSI.faint() <> s <> IO.ANSI.reset()
  defp err(s), do: IO.puts(:stderr, IO.ANSI.red() <> s <> IO.ANSI.reset())

  defp help do
    IO.puts("""
    #{IO.ANSI.bright()}lps#{IO.ANSI.reset()} — LAPSUS consumer CLI

      lps models                          list models on the network (numbered)
      lps balance                         your peer id + CC balance (spent/earned today)
      lps ask [<#|model>] "<prompt>" [--max N]
                                          ask — pick by number or name; no model → picker
      lps usage [--days N]                what you used (default 7 days) + per-day bars
      lps help                            this help

    Examples
      lps models
      lps ask 1 "what is peer-to-peer?" --max 300
      lps ask              # interactive: pick a model, then type a prompt
      lps usage --days 30
    """)
  end
end
