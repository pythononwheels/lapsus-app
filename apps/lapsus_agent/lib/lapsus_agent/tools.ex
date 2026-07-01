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
  def fetch_url(url) do
    cond do
      not http_url?(url) -> "(error: only http(s) URLs are allowed)"
      blocked_host?(url) -> "(error: refusing to fetch a private/local address)"
      true -> do_fetch(url)
    end
  end

  defp do_fetch(url) do
    case Req.get(url,
           headers: [{"user-agent", "lapsus-lps/1.0 (+https://lapsus.pyrates.io)"}],
           max_redirects: 3,
           connect_options: [timeout: 10_000],
           receive_timeout: 15_000,
           retry: false,
           decode_body: false
         ) do
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

  # --- URL safety ---

  defp http_url?(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" -> true
      _ -> false
    end
  end

  defp blocked_host?(url) do
    host = (URI.parse(url).host || "") |> String.downcase()

    cond do
      host == "" -> true
      host in ["localhost", "localhost.localdomain"] -> true
      String.ends_with?(host, ".localhost") -> true
      true -> private_ip?(host)
    end
  end

  # Block literal private / loopback / link-local addresses (v4 + v6). A hostname that
  # DNS-resolves to a private IP is not caught yet (see doc/tech/tools.md).
  defp private_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {10, _, _, _}} -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {169, 254, _, _}} -> true
      {:ok, {172, b, _, _}} when b >= 16 and b <= 31 -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, addr} when tuple_size(addr) == 8 -> v6_private?(elem(addr, 0))
      _ -> false
    end
  end

  # fc00::/7 (unique-local) or fe80::/10 (link-local)
  defp v6_private?(first), do: (first >= 0xFC00 and first <= 0xFDFF) or (first >= 0xFE80 and first <= 0xFEBF)
end
