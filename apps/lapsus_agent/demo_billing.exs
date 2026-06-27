# Step D live demo: book a job via a mutually-signed receipt over the real wire.
# Provider asserts the token counts and signs; consumer co-signs to authorise the
# debit; coordinator verifies BOTH signatures and books (debit consumer, credit
# provider). Needs the coordinator running (mix phx.server).
# Run from apps/lapsus_agent: mix run demo_billing.exs
#
# NOTE: uses a small representative job (cc=30) so it fits the 100-CC starter
# faucet. The full inference path is proven in demo_inference.exs; signature
# verification is covered rigorously by the coordinator channel tests.
alias LapsusAgent.Coordinator
alias LapsusCore.{Identity, Receipt}

provider = Identity.generate()
consumer = Identity.generate()
me = self()

{:ok, _prov_coord} = Coordinator.start_link(identity: provider, role: "provider", models: ["gemma-4-e2b"], handler: me)
{:ok, cons_coord} = Coordinator.start_link(identity: consumer, role: "consumer", handler: me)

wait_join = fn ->
  receive do
    {:lapsus_joined, _} -> :ok
  after
    5000 -> raise "join timeout"
  end
end

wait_join.()
wait_join.()

# The provider builds the receipt from the (here representative) job facts and
# signs it; the consumer co-signs to authorise payment.
receipt = %{
  "job_id" => "job-#{System.os_time(:second)}",
  "consumer_id" => consumer.peer_id,
  "provider_id" => provider.peer_id,
  "model" => "gemma-4-e2b",
  "in_tokens" => 29,
  "out_tokens" => 11,
  "model_weight" => 2,
  "cc" => 30
}

provider_sig = Receipt.sign(provider, receipt)
consumer_sig = Receipt.sign(consumer, receipt)

IO.puts("consumer submitting mutually-signed receipt (cc=#{receipt["cc"]})...")

case Coordinator.submit_receipt(cons_coord, receipt, provider_sig, consumer_sig) do
  {:ok, %{"balance" => balance}} ->
    IO.puts("✓ booked. consumer balance now: #{balance} CC (started at 100 faucet)")
    IO.puts("\nStep D OK: job booked via two signatures over the real coordinator wire.")

  other ->
    IO.inspect(other, label: "submit_receipt returned")
end

# Re-submitting the same receipt must be rejected (idempotency).
case Coordinator.submit_receipt(cons_coord, receipt, provider_sig, consumer_sig) do
  {:error, %{"reason" => reason}} -> IO.puts("✓ duplicate rejected: #{reason}")
  other -> IO.inspect(other, label: "unexpected duplicate result")
end
