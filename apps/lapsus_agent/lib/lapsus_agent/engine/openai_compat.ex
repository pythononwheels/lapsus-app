defmodule LapsusAgent.Engine.OpenAICompat do
  @moduledoc """
  `LapsusAgent.Engine` adapter for OpenAI-compatible local engines — notably
  **LM Studio** (`http://localhost:1234/v1`), but also Ollama's `/v1` surface.

  The OpenAI `usage` object gives token counts (`prompt_tokens`,
  `completion_tokens`) but **no timing**, so tokens/sec is a wall-clock estimate
  (a cold first call includes model-load time). `ttft_ms` is therefore `nil`.

  Reasoning models (e.g. `gemma-4-e2b`) emit `reasoning_content` separately from
  `content`; `completion_tokens` already includes the reasoning tokens, so they
  are billed as the real GPU compute they are (see `doc/tech/design.md` §4.2b).

  Base URL comes from `OPENAI_BASE_URL` (default `http://localhost:1234/v1`).
  """
  @behaviour LapsusAgent.Engine

  alias LapsusAgent.Engine.Result

  @default_base_url "http://localhost:1234/v1"
  @receive_timeout 120_000

  @doc "Base URL of the OpenAI-compatible server."
  @spec base_url() :: String.t()
  def base_url, do: System.get_env("OPENAI_BASE_URL", @default_base_url)

  @impl true
  def list_models(opts \\ []) do
    case Req.get(client(opts), url: "/models") do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, Enum.map(data, & &1["id"])}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def loaded_models(opts \\ []) do
    # LM Studio's native REST (not the OpenAI surface) reports per-model load state.
    native = String.replace_suffix(Keyword.get(opts, :base_url, base_url()), "/v1", "/api/v0")

    case Req.get(Req.new(base_url: native, receive_timeout: 5_000), url: "/models") do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, data |> Enum.filter(&(&1["state"] == "loaded")) |> Enum.map(& &1["id"])}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def caps(_models, opts \\ []) do
    with {:ok, %{caps: caps}} <- model_status(opts), do: {:ok, caps}
  end

  @doc """
  Loaded state *and* capabilities from a single native `/api/v0/models` call —
  both parse the same (verbose) response, so fetching them together halves how
  often the engine logs a full model-list dump.
  """
  def model_status(opts \\ []) do
    # LM Studio's native REST reports per-model load state + type + context length.
    native = String.replace_suffix(Keyword.get(opts, :base_url, base_url()), "/v1", "/api/v0")

    case Req.get(Req.new(base_url: native, receive_timeout: 5_000), url: "/models") do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        loaded = data |> Enum.filter(&(&1["state"] == "loaded")) |> Enum.map(& &1["id"])

        caps =
          Map.new(data, fn m ->
            {m["id"],
             %{
               "ctx" => m["max_context_length"] || m["loaded_context_length"],
               "vision" => m["type"] == "vlm"
             }}
          end)

        {:ok, %{loaded: loaded, caps: caps}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def generate(model, prompt, opts \\ []) when is_binary(model) and is_binary(prompt) do
    messages =
      case Keyword.get(opts, :system) do
        nil -> [%{role: "user", content: prompt}]
        sys -> [%{role: "system", content: sys}, %{role: "user", content: prompt}]
      end

    body =
      %{model: model, messages: messages, stream: false}
      |> maybe_put("max_tokens", Keyword.get(opts, :max_tokens))
      |> maybe_put("temperature", Keyword.get(opts, :temperature))

    started = System.monotonic_time(:millisecond)

    case Req.post(client(opts), url: "/chat/completions", json: body) do
      {:ok, %{status: 200, body: resp}} ->
        wall_ms = (System.monotonic_time(:millisecond) - started) * 1.0
        {:ok, to_result(model, resp, wall_ms)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- internals ---

  defp client(opts) do
    Req.new(
      base_url: Keyword.get(opts, :base_url, base_url()),
      receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout)
    )
  end

  defp to_result(model, resp, wall_ms) do
    usage = resp["usage"] || %{}
    out_tokens = usage["completion_tokens"] || 0
    message = get_in(resp, ["choices", Access.at(0), "message"]) || %{}
    reasoning_tokens = get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0

    tps =
      if wall_ms > 0 and out_tokens > 0,
        do: Float.round(out_tokens / (wall_ms / 1000.0), 2),
        else: 0.0

    %Result{
      engine: :openai,
      model: model,
      response: message["content"],
      reasoning: message["reasoning_content"],
      in_tokens: usage["prompt_tokens"] || 0,
      out_tokens: out_tokens,
      reasoning_tokens: reasoning_tokens,
      tokens_per_sec: tps,
      elapsed_ms: Float.round(wall_ms, 1),
      ttft_ms: nil
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
