defmodule LapsusCore.ReceiptTest do
  use ExUnit.Case, async: true

  alias LapsusCore.{Identity, Receipt}

  defp receipt(consumer, provider) do
    %{
      "job_id" => "job-1",
      "consumer_id" => consumer.peer_id,
      "provider_id" => provider.peer_id,
      "model" => "gemma-4-e2b",
      "in_tokens" => 29,
      "out_tokens" => 287,
      "model_weight" => 2,
      "cc" => 2354
    }
  end

  test "canonical form is deterministic and key-order independent" do
    consumer = Identity.generate()
    provider = Identity.generate()
    r = receipt(consumer, provider)
    assert Receipt.canonical(r) == Receipt.canonical(Map.new(Enum.reverse(Map.to_list(r))))
  end

  test "both parties' signatures verify" do
    consumer = Identity.generate()
    provider = Identity.generate()
    r = receipt(consumer, provider)

    psig = Receipt.sign(provider, r)
    csig = Receipt.sign(consumer, r)

    assert Receipt.verify(provider.peer_id, r, psig)
    assert Receipt.verify(consumer.peer_id, r, csig)
  end

  test "a tampered receipt fails verification" do
    consumer = Identity.generate()
    provider = Identity.generate()
    r = receipt(consumer, provider)
    psig = Receipt.sign(provider, r)

    tampered = %{r | "cc" => 999_999}
    refute Receipt.verify(provider.peer_id, tampered, psig)
  end

  test "a signature from the wrong identity is rejected" do
    consumer = Identity.generate()
    provider = Identity.generate()
    other = Identity.generate()
    r = receipt(consumer, provider)
    sig = Receipt.sign(other, r)

    refute Receipt.verify(provider.peer_id, r, sig)
  end

  test "malformed signature is rejected" do
    consumer = Identity.generate()
    provider = Identity.generate()
    refute Receipt.verify(provider.peer_id, receipt(consumer, provider), "not-base64!!")
  end
end
