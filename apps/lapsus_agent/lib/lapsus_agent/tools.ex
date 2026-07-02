defmodule LapsusAgent.Tools do
  @moduledoc """
  Consumer-side tools — executed by `lps` on the *consumer's* machine, never on a
  provider. See `doc/tech/tools.md`.

  A tool is a pure `name + args -> text` function. The CLI runs a small ReAct loop:
  it advertises these tools in the prompt, the model emits a `TOOL:` line as text,
  `lps` runs the tool here and feeds the result back. Providers never see or execute
  anything — the "no tools on providers" guarantee is untouched.
  """

  # Registry. Each entry: name, one-line description, and an args example for the
  # prompt's tool spec. Add a tool = add an entry + a `run/2` clause.
  @tools [
    %{
      name: "fetch_url",
      desc: "fetch a web page and return its readable text",
      args: ~s({"url": "https://..."})
    }
  ]

  @doc "All available tools (for `lps tools` and the prompt spec)."
  def list, do: @tools

  @doc "The tool list rendered for the prompt preamble."
  def spec_text do
    Enum.map_join(@tools, "\n", fn t -> "- #{t.name} — #{t.desc}. Args: #{t.args}" end)
  end

  @doc "Run a tool call. Always returns a string (never raises) — errors become text."
  def run("fetch_url", %{"url" => url}) when is_binary(url), do: fetch_url(url)
  def run(name, args), do: "(error: malformed call to #{name}: #{inspect(args)})"

  # --- fetch_url ---

  # Clip fetched text so a huge page can't blow up the transcript / token budget.
  @max_chars 6_000

  @doc """
  HTTP GET a URL and return its readable text. Refuses non-http(s) and private/local
  addresses — the provider's model output is attacker-influenceable, so a hostile
  provider could aim a `TOOL:` line at the consumer's own LAN.
  """
  @max_redirects 3

  def fetch_url(url), do: fetch_url(url, @max_redirects)

  defp fetch_url(_url, left) when left < 0, do: "(error: too many redirects)"

  defp fetch_url(url, left) do
    case validate(url) do
      :ok -> do_fetch(url, left)
      {:error, msg} -> msg
    end
  end

  # Follow redirects manually (redirect: false) so every hop's target is re-validated —
  # otherwise a hostile page could 3xx-redirect us at a private/metadata address.
  defp do_fetch(url, left) do
    case Req.get(url,
           headers: [{"user-agent", "lapsus-lps/1.0 (+https://lapsus.pyrates.io)"}],
           redirect: false,
           connect_options: [timeout: 10_000],
           receive_timeout: 15_000,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status} = resp} when status in 300..399 ->
        case redirect_target(resp, url) do
          nil -> "(error: redirect without a location)"
          next -> fetch_url(next, left - 1)
        end

      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        render_body(resp)

      {:ok, %Req.Response{status: status}} ->
        "(error: HTTP #{status})"

      {:error, e} ->
        "(error: #{Exception.message(e)})"
    end
  rescue
    e -> "(error: #{Exception.message(e)})"
  end

  # Absolute URL of a redirect's Location (relative locations resolved against `base`).
  defp redirect_target(resp, base) do
    case Req.Response.get_header(resp, "location") do
      [loc | _] when is_binary(loc) and loc != "" -> base |> URI.merge(loc) |> URI.to_string()
      _ -> nil
    end
  end

  defp render_body(resp) do
    ctype = resp |> Req.Response.get_header("content-type") |> List.first() |> to_string()

    cond do
      resp.body == "" or is_nil(resp.body) ->
        "(error: empty response)"

      not is_binary(resp.body) ->
        clip(inspect(resp.body))

      String.contains?(ctype, "html") ->
        resp.body |> html_to_text() |> clip()

      String.starts_with?(ctype, "text/") or ctype == "" ->
        resp.body |> collapse_ws() |> clip()

      true ->
        "(error: unsupported content-type: #{ctype})"
    end
  end

  # Cheap HTML → text: drop script/style/head, strip tags, decode a few entities,
  # collapse whitespace. Not a full readability pass — good enough to feed a model.
  defp html_to_text(html) do
    html
    |> String.slice(0, 500_000)
    |> String.replace(~r/<(script|style|head|noscript)\b[^>]*>.*?<\/\1>/is, " ")
    |> String.replace(~r/<!--.*?-->/s, " ")
    |> String.replace(~r/<\/(p|div|br|li|tr|h[1-6])\s*>/i, "\n")
    |> String.replace(~r/<[^>]+>/, " ")
    |> decode_entities()
    |> collapse_ws()
  end

  defp decode_entities(s) do
    s
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
  end

  defp collapse_ws(s) do
    s
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n[ \t]*\n\s*/, "\n\n")
    |> String.trim()
  end

  defp clip(text, max \\ @max_chars) do
    if String.length(text) > max,
      do: String.slice(text, 0, max) <> "\n…(truncated)",
      else: text
  end

  # --- URL safety (SSRF) ---

  # One rule, checked on every hop: http(s) only, then RESOLVE the host and reject if
  # *any* resolved address is private/local. Guarding the resolved IP (not the URL
  # string) closes redirects, DNS-rebinding, IPv4-mapped IPv6, 0.0.0.0/8 and trailing
  # dots at once. (Pragmatic: we resolve-then-connect, so a fast-flipping DNS TOCTOU
  # isn't fully pinned — good enough for this threat model; pin-to-IP is a later upgrade.)
  defp validate(url) do
    uri = URI.parse(url)
    host = uri.host && (uri.host |> String.downcase() |> String.trim_trailing("."))

    cond do
      uri.scheme not in ["http", "https"] -> {:error, "(error: only http(s) URLs are allowed)"}
      host in [nil, ""] -> {:error, "(error: bad URL)"}
      local_name?(host) -> {:error, "(error: refusing to fetch a private/local address)"}
      true -> validate_resolved(host)
    end
  end

  defp local_name?(host),
    do: host in ["localhost", "localhost.localdomain"] or String.ends_with?(host, ".localhost")

  defp validate_resolved(host) do
    case resolve(host) do
      {:ok, addrs} ->
        if Enum.any?(addrs, &private_ip?/1),
          do: {:error, "(error: refusing to fetch a private/local address)"},
          else: :ok

      :error ->
        {:error, "(error: could not resolve host)"}
    end
  end

  # Resolve to IP tuples (v4 + v6). A literal IP resolves to itself.
  defp resolve(host) do
    hl = String.to_charlist(host)

    v4 =
      case :inet.getaddrs(hl, :inet) do
        {:ok, a} -> a
        _ -> []
      end

    v6 =
      case :inet.getaddrs(hl, :inet6) do
        {:ok, a} -> a
        _ -> []
      end

    case v4 ++ v6 do
      [] -> :error
      addrs -> {:ok, addrs}
    end
  end

  # Private / loopback / link-local / CGNAT — takes an IP TUPLE (already resolved).
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp private_ip?({_, _, _, _}), do: false
  # IPv6
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # IPv4-mapped ::ffff:a.b.c.d → check the embedded v4 address
  defp private_ip?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: private_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  defp private_ip?({h, _, _, _, _, _, _, _}) when h >= 0xFC00 and h <= 0xFDFF, do: true
  defp private_ip?({h, _, _, _, _, _, _, _}) when h >= 0xFE80 and h <= 0xFEBF, do: true
  defp private_ip?(_), do: false
end
