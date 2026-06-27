# Step A live demo: two agent clients register at the coordinator,
# discover each other, and relay a signaling payload P2P-style.
# Run from apps/lapsus_agent: `mix run demo_coordinator.exs`
alias LapsusAgent.Coordinator
alias LapsusCore.Identity

prov_id = Identity.generate()
cons_id = Identity.generate()
me = self()

{:ok, prov} =
  Coordinator.start_link(identity: prov_id, role: "provider", models: ["gemma-4-e2b"], handler: me)

{:ok, cons} = Coordinator.start_link(identity: cons_id, role: "consumer", handler: me)

# Wait for both to join the lobby.
for _ <- 1..2 do
  receive do
    {:lapsus_joined, topic} -> IO.puts("joined: #{topic}")
  after
    5000 -> raise "join timeout"
  end
end

# Discovery (retry briefly: provider presence is tracked server-side just after join).
providers =
  Enum.reduce_while(1..10, [], fn _, _ ->
    {:ok, p} = Coordinator.list_providers(cons, "gemma-4-e2b")
    if p == [], do: (Process.sleep(100); {:cont, []}), else: {:halt, p}
  end)

IO.inspect(providers, label: "list_providers(gemma-4-e2b)")
true = Enum.any?(providers, &(&1["peer_id"] == prov_id.peer_id))
IO.puts("✓ consumer discovered provider")

# Signaling relay: consumer -> provider.
Coordinator.signal(cons, prov_id.peer_id, "offer", "v=0 (fake SDP)")

receive do
  {:lapsus_signal, payload} ->
    IO.inspect(payload, label: "provider received signal")
    ^prov_id = prov_id
    true = payload["from"] == cons_id.peer_id
    true = payload["kind"] == "offer"
    IO.puts("✓ signal relayed consumer -> provider (from matches, kind matches)")
after
  5000 -> raise "signal relay timeout"
end

IO.puts("\nStep A OK: register + discover + signal relay all work over real WebSocket.")
GenServer.stop(prov)
GenServer.stop(cons)
