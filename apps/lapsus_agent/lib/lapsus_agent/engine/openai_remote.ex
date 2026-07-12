defmodule LapsusAgent.Engine.OpenAIRemote do
  @moduledoc """
  `LapsusAgent.Engine` adapter for a **remote** OpenAI-compatible API — e.g. NVIDIA
  `build.nvidia.com` (`https://integrate.api.nvidia.com/v1`), OpenRouter, Together.

  Unlike the local `OpenAICompat` engine there is no "loaded/unloaded" state: every
  configured model is always available. So this adapter announces its configured
  **model allowlist** as the loaded set and synthesises capabilities — no network
  call at start, so a seed node is always "online" (a dead backend surfaces at
  generate time, where consumer failover takes over).

  Config precedence is **opts → env → Settings**:

    * base URL — `LAPSUS_API_BASE_URL` | settings `api_base_url`
    * API key  — `LAPSUS_API_KEY` | settings `api_key` (sent as `Bearer`)
    * models   — settings `api_models` (the allowlist)

  The actual HTTP (generate + `/models`) is delegated to `OpenAICompat` with the base
  URL and Bearer key threaded through, so there is a single OpenAI wire implementation.
  """
  @behaviour LapsusAgent.Engine

  alias LapsusAgent.Engine.OpenAICompat
  alias LapsusAgent.Settings

  @default_ctx 8192

  @impl true
  def generate(model, prompt, opts \\ []) when is_binary(model) and is_binary(prompt),
    do: OpenAICompat.generate(model, prompt, remote_opts(opts))

  @impl true
  def list_models(opts \\ []), do: OpenAICompat.list_models(remote_opts(opts))

  @impl true
  def loaded_models(_opts \\ []), do: {:ok, models()}

  @impl true
  def caps(_models, _opts \\ []), do: {:ok, default_caps(models())}

  @doc "Loaded state + caps — the configured allowlist is always 'available'."
  def model_status(_opts \\ []) do
    ms = models()
    {:ok, %{loaded: ms, caps: default_caps(ms)}}
  end

  # --- config (public: used by the CLI/UI to show what's configured) ---

  @doc "Configured base URL (env overrides settings; nil if unset)."
  def base_url(settings \\ Settings.load()),
    do: System.get_env("LAPSUS_API_BASE_URL") || nonblank(settings.api_base_url)

  @doc "Configured Bearer key (env overrides settings; nil if unset)."
  def api_key(settings \\ Settings.load()),
    do: System.get_env("LAPSUS_API_KEY") || nonblank(settings.api_key)

  @doc "Configured model allowlist."
  def models(settings \\ Settings.load()), do: settings.api_models || []

  # --- internals ---

  # Thread base_url + key into the shared OpenAICompat HTTP client, labelled :other.
  # Caller opts win (handy for tests).
  defp remote_opts(opts) do
    s = Settings.load()

    [engine: :other]
    |> put_if(:base_url, base_url(s))
    |> put_if(:api_key, api_key(s))
    |> Keyword.merge(opts)
  end

  defp default_caps(models),
    do: Map.new(models, &{&1, %{"ctx" => @default_ctx, "vision" => false}})

  defp put_if(kw, _k, nil), do: kw
  defp put_if(kw, k, v), do: Keyword.put(kw, k, v)

  defp nonblank(v) when v in ["", nil], do: nil
  defp nonblank(v), do: v
end
