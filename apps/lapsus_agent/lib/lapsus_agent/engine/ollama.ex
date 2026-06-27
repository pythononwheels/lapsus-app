defmodule LapsusAgent.Engine.Ollama do
  @moduledoc """
  `LapsusAgent.Engine` adapter for the native Ollama HTTP API.

  We do **not** fork Ollama — we wrap its HTTP API. Ollama's non-streaming
  `/api/generate` response carries the billing metrics we need: `prompt_eval_count`
  (input tokens), `eval_count` (output tokens) and `eval_duration` (→ tokens/sec).
  It also reports `prompt_eval_duration`, used as a time-to-first-token signal for
  the physical-plausibility fraud check (see `doc/tech/design.md` §5).

  Base URL comes from `OLLAMA_HOST` (default `http://localhost:11434`).

  > Note: Ollama's native API counts chat-template overhead into `prompt_eval_count`,
  > so input-token counts run higher than an OpenAI-compatible engine for the same
  > prompt (see §4.2b).
  """
  @behaviour LapsusAgent.Engine

  alias LapsusAgent.Engine.Result

  @default_base_url "http://localhost:11434"
  @receive_timeout 120_000

  @doc "Base URL of the local Ollama server."
  @spec base_url() :: String.t()
  def base_url, do: System.get_env("OLLAMA_HOST", @default_base_url)

  @impl true
  def list_models(opts \\ []) do
    case Req.get(client(opts), url: "/api/tags") do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        {:ok, Enum.map(models, & &1["name"])}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def loaded_models(opts \\ []) do
    case Req.get(client(opts), url: "/api/ps") do
      {:ok, %{status: 200, body: %{"models" => models}}} -> {:ok, Enum.map(models, & &1["name"])}
      {:ok, %{status: 200}} -> {:ok, []}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def caps(models, opts \\ []) when is_list(models) do
    caps =
      models
      |> Enum.map(fn model -> {model, show_caps(model, opts)} end)
      |> Enum.reject(fn {_m, c} -> is_nil(c) end)
      |> Map.new()

    {:ok, caps}
  end

  # `/api/show` exposes `capabilities` (incl. "vision") and a `model_info` map with
  # an arch-specific "<arch>.context_length" key.
  defp show_caps(model, opts) do
    case Req.post(client(opts), url: "/api/show", json: %{name: model}) do
      {:ok, %{status: 200, body: body}} ->
        info = body["model_info"] || %{}

        ctx =
          info
          |> Enum.find(fn {k, _v} -> String.ends_with?(k, ".context_length") end)
          |> case do
            {_k, v} when is_integer(v) -> v
            _ -> nil
          end

        %{"ctx" => ctx, "vision" => "vision" in (body["capabilities"] || [])}

      _ ->
        nil
    end
  end

  @impl true
  def generate(model, prompt, opts \\ []) when is_binary(model) and is_binary(prompt) do
    body =
      %{model: model, prompt: prompt, stream: false}
      |> maybe_put("system", Keyword.get(opts, :system))
      |> maybe_put("options", Keyword.get(opts, :options))
      |> maybe_put("format", json_format(Keyword.get(opts, :format)))

    case Req.post(client(opts), url: "/api/generate", json: body) do
      {:ok, %{status: 200, body: body}} -> {:ok, to_result(model, body)}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- internals ---

  defp client(opts) do
    Req.new(
      base_url: Keyword.get(opts, :base_url, base_url()),
      receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout)
    )
  end

  defp to_result(model, body) do
    out_tokens = body["eval_count"] || 0
    eval_ns = body["eval_duration"] || 0

    tps =
      if eval_ns > 0 and out_tokens > 0,
        do: Float.round(out_tokens / (eval_ns / 1.0e9), 2),
        else: 0.0

    %Result{
      engine: :ollama,
      model: model,
      response: body["response"],
      reasoning: nil,
      in_tokens: body["prompt_eval_count"] || 0,
      out_tokens: out_tokens,
      reasoning_tokens: 0,
      tokens_per_sec: tps,
      elapsed_ms: ns_to_ms(body["total_duration"]),
      ttft_ms: ns_to_ms(body["prompt_eval_duration"])
    }
  end

  defp ns_to_ms(nil), do: nil
  defp ns_to_ms(ns) when is_integer(ns), do: Float.round(ns / 1.0e6, 1)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Ollama structured-output mode (`format: "json"`).
  defp json_format("json"), do: "json"
  defp json_format(_), do: nil
end
