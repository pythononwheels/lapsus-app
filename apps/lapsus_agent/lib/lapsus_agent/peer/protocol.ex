defmodule LapsusAgent.Peer.Protocol do
  @moduledoc """
  Wire protocol for inference over a `LapsusAgent.Peer.Session` DataChannel.

  JSON frames, one request → one response (no multiplexing in the MVP):

    * request  — `%{"t" => "req",  "id" => id, "model" => m, "prompt" => p, "options" => %{}}`
    * response — `%{"t" => "resp", "id" => id, "ok" => true,  "result" => %{...}}`
                 `%{"t" => "resp", "id" => id, "ok" => false, "error" => "..."}`

  `result` is the engine-normalised `LapsusAgent.Engine.Result` as a plain map —
  it carries the token counts the Compute-Credit accounting needs (§4).
  """

  alias LapsusAgent.Engine.Result

  @doc "Encode an inference request frame."
  @spec encode_request(String.t(), String.t(), String.t(), map()) :: iodata()
  def encode_request(id, model, prompt, options \\ %{}) do
    Jason.encode!(%{"t" => "req", "id" => id, "model" => model, "prompt" => prompt, "options" => options})
  end

  @doc """
  Encode a response frame from an engine result or an error.

  `extra` is merged into the frame — used to attach the provider-signed receipt
  (`%{"receipt" => ..., "provider_sig" => ...}`) so the consumer can co-sign it.
  """
  @spec encode_response(String.t(), {:ok, Result.t()} | {:error, term()}, map()) :: iodata()
  def encode_response(id, result, extra \\ %{})

  def encode_response(id, {:ok, %Result{} = result}, extra) do
    Jason.encode!(
      Map.merge(
        %{"t" => "resp", "id" => id, "ok" => true, "result" => Map.from_struct(result)},
        extra
      )
    )
  end

  def encode_response(id, {:error, reason}, extra) do
    Jason.encode!(
      Map.merge(%{"t" => "resp", "id" => id, "ok" => false, "error" => inspect(reason)}, extra)
    )
  end

  @doc """
  Decode an incoming frame.

  Returns `{:request, %{id, model, prompt, options}}`, `{:response, map}`, or
  `{:error, reason}`.
  """
  @spec decode(binary()) ::
          {:request, map()} | {:response, map()} | {:error, term()}
  def decode(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, %{"t" => "req"} = m} ->
        {:request,
         %{
           id: m["id"],
           model: m["model"],
           prompt: m["prompt"],
           options: m["options"] || %{}
         }}

      {:ok, %{"t" => "resp"} = m} ->
        {:response, m}

      {:ok, other} ->
        {:error, {:unknown_frame, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Convert a request's string-keyed `options` map into the keyword options the
  engine expects (`:max_tokens`, `:temperature`, `:system`, `:options`, `:format`).

  This is a strict **allow-list**: only these keys are forwarded to the engine.
  Anything else a consumer puts in `options` (e.g. `tools`, `functions`,
  `tool_choice`) is silently dropped, so a remote prompt can never switch on
  function/tool calling on the provider's machine. LAPSUS serves pure
  text-in/text-out inference — there is no tool executor on the provider side.
  """
  @spec engine_opts(map()) :: keyword()
  def engine_opts(options) when is_map(options) do
    [
      max_tokens: options["max_tokens"],
      temperature: options["temperature"],
      system: options["system"],
      options: options["options"],
      format: options["format"]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end
end
