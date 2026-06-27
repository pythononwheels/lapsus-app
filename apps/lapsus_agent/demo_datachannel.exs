# Step B live demo: two peers establish a real WebRTC DataChannel via the
# coordinator's signaling relay, then exchange ping/pong directly P2P.
# Coordinator must be running (mix phx.server). Run from apps/lapsus_agent:
#   mix run demo_datachannel.exs
alias LapsusAgent.Coordinator
alias LapsusAgent.Peer.Session
alias LapsusCore.Identity

prov_id = Identity.generate()
cons_id = Identity.generate()
me = self()

{:ok, prov_coord} = Coordinator.start_link(identity: prov_id, role: "provider", models: ["echo"], handler: me)
{:ok, cons_coord} = Coordinator.start_link(identity: cons_id, role: "consumer", handler: me)

wait_join = fn ->
  receive do
    {:lapsus_joined, _} -> :ok
  after
    5000 -> raise "join timeout"
  end
end

wait_join.()
wait_join.()

# Consumer opens the connection (offerer) toward the provider.
{:ok, cons_sess} =
  Session.start_link(role: :offerer, coordinator: cons_coord, remote_peer_id: prov_id.peer_id, handler: me)

IO.puts("consumer: created offerer session, offer sent")

# Event loop: route signals to the right session, drive ping/pong.
loop = fn loop, state ->
  receive do
    # Provider receives the consumer's offer -> become answerer.
    {:lapsus_signal, %{"kind" => "offer", "from" => from} = p} when from == cons_id.peer_id ->
      {:ok, prov_sess} =
        Session.start_link(
          role: :answerer,
          coordinator: prov_coord,
          remote_peer_id: cons_id.peer_id,
          handler: me,
          offer: p["data"]
        )

      IO.puts("provider: received offer, created answerer session")
      loop.(loop, Map.put(state, :prov_sess, prov_sess))

    # Signals FROM the consumer are destined for the provider session.
    {:lapsus_signal, %{"from" => from} = p} when from == cons_id.peer_id ->
      if s = state[:prov_sess], do: Session.signal(s, p)
      loop.(loop, state)

    # Signals FROM the provider are destined for the consumer session.
    {:lapsus_signal, %{"from" => from} = p} when from == prov_id.peer_id ->
      Session.signal(cons_sess, p)
      loop.(loop, state)

    {:peer_open, ^cons_sess} ->
      IO.puts("✓ DataChannel OPEN (consumer side) — sending ping")
      Session.send_data(cons_sess, "ping")
      loop.(loop, state)

    {:peer_open, _other} ->
      IO.puts("✓ DataChannel OPEN (provider side)")
      loop.(loop, state)

    {:peer_data, sess, "ping"} ->
      IO.puts("provider received: ping — echoing pong")
      Session.send_data(sess, "pong")
      loop.(loop, state)

    {:peer_data, ^cons_sess, "pong"} ->
      IO.puts("✓ consumer received: pong")
      IO.puts("\nStep B OK: real WebRTC DataChannel established P2P; ping/pong round-trip works.")
      :done
  after
    20_000 -> raise "timeout waiting for ping/pong (state: #{inspect(Map.keys(state))})"
  end
end

loop.(loop, %{})
