defmodule LapsusCore.Credits do
  @moduledoc """
  Compute-Credit (CC) accounting — the abstract economic unit of LAPSUS.

  Raw tokens are the wrong unit: an output token on `gemma-2b` is not worth the
  same as one on `kimi2-512b`, otherwise offering large models would never pay
  off. So we normalise to abstract **Compute-Credits**.

  ## Formula

      cost = model_weight * (in_tokens * a + out_tokens * b)

  - `b > a` — generation (output) is the expensive part; prefill (input) is cheap.
  - `model_weight` scales the whole job, because a bigger model costs more compute
    for *both* prefill and generation. It is relative to a 1B-parameter baseline
    (`model_weight = 1.0` ≈ a 1B dense model).

  > Note: this refines `doc/tech/design.md`, which wrote
  > `cost = (in_tokens·a) + (out_tokens·b)·model_weight`. We apply `model_weight`
  > to both terms — prefill compute also scales with model size.

  The credited amount equals the cost: what the consumer pays is what the provider
  earns (a clean tit-for-tat ledger, minus any later protocol fee).
  """

  @typedoc "Per-token cost coefficients."
  @type coeffs :: %{a: number(), b: number()}

  # Defaults: input token = 1 unit, output token = 4 units (generation ~4x prefill).
  @default_coeffs %{a: 1.0, b: 4.0}

  @doc """
  Cost in Compute-Credits for a single job.

  ## Options
    * `:coeffs` — `%{a: number, b: number}` per-token coefficients
      (default `#{inspect(@default_coeffs)}`).
    * `:round` — round the result to the nearest integer (default `true`).

  ## Examples

      iex> LapsusCore.Credits.cost(100, 200, 1.0)
      900

      iex> LapsusCore.Credits.cost(100, 200, 8.0)
      7200
  """
  @spec cost(non_neg_integer(), non_neg_integer(), number(), keyword()) :: number()
  def cost(in_tokens, out_tokens, model_weight, opts \\ [])
      when is_integer(in_tokens) and in_tokens >= 0 and
             is_integer(out_tokens) and out_tokens >= 0 and
             is_number(model_weight) and model_weight > 0 do
    %{a: a, b: b} = Keyword.get(opts, :coeffs, @default_coeffs)
    raw = model_weight * (in_tokens * a + out_tokens * b)

    if Keyword.get(opts, :round, true), do: round(raw), else: raw
  end

  @doc """
  Estimate `model_weight` from a model's parameter count in billions, relative to
  a 1B baseline. Dense-model compute per token scales ~linearly with parameters.

      iex> LapsusCore.Credits.model_weight_from_params(8)
      8.0
  """
  @spec model_weight_from_params(number()) :: float()
  def model_weight_from_params(billions) when is_number(billions) and billions > 0 do
    billions * 1.0
  end

  @doc """
  Default per-token coefficients.
  """
  @spec default_coeffs() :: coeffs()
  def default_coeffs, do: @default_coeffs
end
