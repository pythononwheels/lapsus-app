defmodule LapsusCore.Receipt do
  @moduledoc """
  A mutually-signed job receipt — the trust anchor for Compute-Credit accounting
  (see `doc/tech/design.md` §4, `phase-1-p2p-plan.md` Step D).

  After a P2P job, the **provider** asserts the token counts (it ran the model) and
  signs the receipt; the **consumer** co-signs to authorise the debit. The
  coordinator books the credits only when *both* signatures verify. Neither side
  can move credits alone: the consumer won't co-sign inflated counts (it pays), and
  the provider can't bill without the consumer's authorisation. Provider over-
  reporting is caught later by reputation/challenges (Phase 3).

  ## Fields (a plain string-keyed map, JSON-friendly)
    * `"job_id"`, `"consumer_id"`, `"provider_id"`, `"model"`
    * `"in_tokens"`, `"out_tokens"`, `"model_weight"`, `"cc"`

  Both parties sign the **canonical form** (a deterministic string) so the bytes
  signed are identical on both ends.
  """

  alias LapsusCore.Identity

  @fields ~w(job_id consumer_id provider_id model in_tokens out_tokens model_weight cc)

  @doc "Deterministic byte representation that both parties sign."
  @spec canonical(map()) :: binary()
  def canonical(receipt) when is_map(receipt) do
    @fields
    |> Enum.map(fn key -> to_string(Map.get(receipt, key, "")) end)
    |> Enum.join("|")
  end

  @doc "Sign a receipt with an identity; returns a Base64 signature."
  @spec sign(Identity.t(), map()) :: String.t()
  def sign(%Identity{} = identity, receipt) do
    identity |> Identity.sign(canonical(receipt)) |> Base.encode64()
  end

  @doc "Verify a Base64 signature over a receipt against a signer's `peer_id`."
  @spec verify(String.t(), map(), String.t()) :: boolean()
  def verify(peer_id, receipt, sig_b64) when is_binary(sig_b64) do
    case Base.decode64(sig_b64) do
      {:ok, sig} -> Identity.verify(peer_id, canonical(receipt), sig)
      :error -> false
    end
  end

  def verify(_peer_id, _receipt, _sig), do: false
end
