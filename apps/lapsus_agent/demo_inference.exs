# Step C live demo: real inference over a P2P WebRTC DataChannel.
# The consumer sends an inference request; the provider runs it through its local
# engine (LM Studio / gemma) and returns the result directly P2P.
# Needs: coordinator running (mix phx.server) + LM Studio serving on :1234.
# Run from apps/lapsus_agent: mix run demo_inference.exs
alias LapsusAgent.{Coordinator, Engine}
alias LapsusAgent.Peer.{Session, Protocol}
alias LapsusCore.{Identity, Credits}

model = "google/gemma-4-e2b"
prov_id = Identity.generate()
cons_id = Identity.generate()
me = self()

{:ok, prov_coord} = Coordinator.start_link(identity: prov_id, role: "provider", models: [model], handler: me)
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

{:ok, cons_sess} =
  Session.start_link(role: :offerer, coordinator: cons_coord, remote_peer_id: prov_id.peer_id, handler: me)

IO.puts("consumer: opening P2P connection to provider...")

loop = fn loop, state ->
  receive do
    {:lapsus_signal, %{"kind" => "offer", "from" => from} = p} when from == cons_id.peer_id ->
      {:ok, prov_sess} =
        Session.start_link(
          role: :answerer, coordinator: prov_coord,
          remote_peer_id: cons_id.peer_id, handler: me, offer: p["data"]
        )

      loop.(loop, Map.put(state, :prov_sess, prov_sess))

    {:lapsus_signal, %{"from" => from} = p} when from == cons_id.peer_id ->
      if s = state[:prov_sess], do: Session.signal(s, p)
      loop.(loop, state)

    {:lapsus_signal, %{"from" => from} = p} when from == prov_id.peer_id ->
      Session.signal(cons_sess, p)
      loop.(loop, state)

    {:peer_open, ^cons_sess} ->
      IO.puts("✓ P2P channel open — consumer sending inference request")
      req = Protocol.encode_request("job-1", model, "In one sentence: what is peer-to-peer computing?", %{"max_tokens" => 300, "temperature" => 0})
      Session.send_data(cons_sess, req)
      loop.(loop, state)

    {:peer_open, _other} ->
      loop.(loop, state)

    {:peer_data, sess, data} ->
      cond do
        # CONSUMER: the response came back P2P.
        sess == cons_sess ->
          {:response, resp} = Protocol.decode(data)
          r = resp["result"]
          IO.puts("\n✓ consumer received inference result P2P:")
          IO.puts("  response:   #{String.slice(r["response"] || "", 0, 100)}")
          IO.puts("  in_tokens:  #{r["in_tokens"]}")
          IO.puts("  out_tokens: #{r["out_tokens"]} (reasoning: #{r["reasoning_tokens"]})")
          IO.puts("  tok/s:      #{r["tokens_per_sec"]}")
          cc = Credits.cost(r["in_tokens"], r["out_tokens"], Credits.model_weight_from_params(2))
          IO.puts("  → CC for this job (2B weight): #{cc}")
          IO.puts("\nStep C OK: inference ran on the provider's engine and returned over the P2P channel.")
          :done

        # PROVIDER: an inference request arrived over the channel -> run it locally.
        true ->
          {:request, req} = Protocol.decode(data)
          IO.puts("provider: received request for #{req.model} -> running on local engine (LM Studio)")
          result = Engine.generate(:openai, req.model, req.prompt, Protocol.engine_opts(req.options))
          Session.send_data(sess, Protocol.encode_response(req.id, result))
          loop.(loop, state)
      end

  after
    30_000 -> raise "timeout (state: #{inspect(Map.keys(state))})"
  end
end

loop.(loop, %{})
