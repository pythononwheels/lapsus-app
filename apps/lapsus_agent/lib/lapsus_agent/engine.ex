defmodule LapsusAgent.Engine do
  @moduledoc """
  Unified interface over local inference engines.

  The provider agent must not care *which* engine a user runs (Ollama, LM Studio,
  …). This behaviour + dispatcher hides that: callers use
  `LapsusAgent.Engine.generate(:ollama, model, prompt)` and always get a
  `LapsusAgent.Engine.Result`.

  Adapters:
    * `:ollama` → `LapsusAgent.Engine.Ollama` (native Ollama API)
    * `:openai` → `LapsusAgent.Engine.OpenAICompat` (LM Studio & OpenAI-compatible)

  A module can also be passed directly in place of the atom.
  """

  defmodule Result do
    @moduledoc """
    Normalised outcome of a single generation across engines.

    `out_tokens` is the total completion-token count and **includes reasoning
    tokens** — reasoning is real GPU compute and is billed (see
    `doc/tech/design.md` §4.2b). `reasoning_tokens` breaks out how many of those
    were reasoning (0 when unknown). `ttft_ms` (time-to-first-token) is only
    available on engines that report timing (Ollama); `nil` otherwise.
    """
    @enforce_keys [:engine, :model, :in_tokens, :out_tokens]
    defstruct [
      :engine,
      :model,
      :response,
      :reasoning,
      :in_tokens,
      :out_tokens,
      :reasoning_tokens,
      :tokens_per_sec,
      :elapsed_ms,
      :ttft_ms
    ]

    @type t :: %__MODULE__{
            engine: atom(),
            model: String.t(),
            response: String.t() | nil,
            reasoning: String.t() | nil,
            in_tokens: non_neg_integer(),
            out_tokens: non_neg_integer(),
            reasoning_tokens: non_neg_integer(),
            tokens_per_sec: float(),
            elapsed_ms: float() | nil,
            ttft_ms: float() | nil
          }
  end

  @typedoc "Engine selector: a known atom or an adapter module."
  @type engine :: atom() | module()

  @doc "List available model ids."
  @callback list_models(opts :: keyword()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "Run a single non-streaming generation, returning a normalised `Result`."
  @callback generate(model :: String.t(), prompt :: String.t(), opts :: keyword()) ::
              {:ok, Result.t()} | {:error, term()}

  @doc "List models currently *loaded* in memory (≠ merely available). May be empty."
  @callback loaded_models(opts :: keyword()) :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Per-model capabilities for the given model ids: context length and whether the
  model is multimodal (vision). Returns a map `name => %{"ctx" => int | nil,
  "vision" => boolean}`. Missing models are simply absent from the map.
  """
  @callback caps(models :: [String.t()], opts :: keyword()) ::
              {:ok, %{String.t() => map()}} | {:error, term()}

  @engines %{
    ollama: LapsusAgent.Engine.Ollama,
    openai: LapsusAgent.Engine.OpenAICompat
  }

  @doc "Map of built-in engine selectors to adapter modules."
  @spec engines() :: %{atom() => module()}
  def engines, do: @engines

  @doc "List models for the given engine. See `c:list_models/1`."
  @spec list_models(engine(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(engine, opts \\ []), do: module!(engine).list_models(opts)

  @doc "Generate for the given engine. See `c:generate/3`."
  @spec generate(engine(), String.t(), String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def generate(engine, model, prompt, opts \\ []),
    do: module!(engine).generate(model, prompt, opts)

  @doc "Models currently loaded in memory for the given engine."
  @spec loaded_models(engine(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def loaded_models(engine, opts \\ []), do: module!(engine).loaded_models(opts)

  @doc "Per-model capabilities (context length + multimodal). See `c:caps/2`."
  @spec caps(engine(), [String.t()], keyword()) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def caps(engine, models, opts \\ []), do: module!(engine).caps(models, opts)

  @doc """
  Auto-detect a running local engine and its models. Tries OpenAI-compatible
  (LM Studio) first, then native Ollama. Returns `{:ok, engine, models}` or
  `:error` if none is reachable with at least one model.
  """
  @spec detect() :: {:ok, atom(), [String.t()]} | :error
  def detect do
    Enum.find_value([:openai, :ollama], :error, fn engine ->
      case list_models(engine) do
        {:ok, [_ | _] = models} -> {:ok, engine, models}
        _ -> nil
      end
    end)
  end

  defp module!(engine) when is_atom(engine) do
    case Map.fetch(@engines, engine) do
      {:ok, mod} -> mod
      # Not a known selector — assume it's an adapter module passed directly.
      :error -> engine
    end
  end
end
