# End-to-end demo of the consumer side against a REAL running provider app.
# Prereqs:
#   1) coordinator running (mix phx.server, dev faucet = 100_000)
#   2) provider app running: mix lapsus.provider   (with LM Studio/Ollama up)
# Run from apps/lapsus_agent: mix run demo_consumer.exs
alias LapsusAgent.Coordinator
alias LapsusAgent.Peer.{Session, Protocol}
alias LapsusCore.{Identity, Receipt}

model = System.get_env("MODEL") || "google/gemma-4-e2b"
prompt = "In one sentence: what is peer-to-peer computing?"

consumer = Identity.generate()
me = self()

{:ok, coord} = Coordinator.start_link(identity: consumer, role: "consumer", handler: me)

receive do
  {:lapsus_joined, _} -> :ok
after
  5000 -> raise "join timeout"
end

# Discover a provider for the model.
{:ok, providers} = Coordinator.list_providers(coord, model)

if providers == [] do
  IO.puts("No provider online for #{model}. Start: mix lapsus.provider")
  System.halt(1)
end

provider_peer = hd(providers)["peer_id"]
IO.puts("found provider #{String.slice(provider_peer, 0, 16)}… — opening P2P connection")

{:ok, session} =
  Session.start_link(role: :offerer, coordinator: coord, remote_peer_id: provider_peer, handler: me)

loop = fn loop ->
  receive do
    {:lapsus_signal, p} ->
      Session.signal(session, p)
      loop.(loop)

    {:peer_open, ^session} ->
      IO.puts("✓ P2P channel open — sending request for #{model}")
      Session.send_data(session, Protocol.encode_request("job-#{System.os_time(:second)}", model, prompt, %{"max_tokens" => 300, "temperature" => 0}))
      loop.(loop)

    {:peer_data, ^session, data} ->
      {:response, resp} = Protocol.decode(data)
      r = resp["result"]
      IO.puts("\n✓ inference result (P2P from provider's engine):")
      IO.puts("  #{String.slice(r["response"] || "", 0, 110)}")
      IO.puts("  tokens: #{r["in_tokens"]} in / #{r["out_tokens"]} out")

      # Co-sign the provider's receipt and submit it for billing.
      receipt = resp["receipt"]
      consumer_sig = Receipt.sign(consumer, receipt)

      case Coordinator.submit_receipt(coord, receipt, resp["provider_sig"], consumer_sig) do
        {:ok, %{"balance" => balance}} ->
          IO.puts("\n✓ job booked: #{receipt["cc"]} CC. consumer balance now #{balance}.")
          IO.puts("Full chain OK: discover → P2P → inference → mutually-signed billing.")

        other ->
          IO.inspect(other, label: "submit_receipt")
      end

      :done
  after
    30_000 -> raise "timeout"
  end
end

loop.(loop)
