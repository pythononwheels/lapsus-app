defmodule LapsusAgent.Peer.Session do
  @moduledoc """
  One WebRTC peer connection between two LAPSUS peers, over a DataChannel.

  Wraps `ExWebRTC.PeerConnection`. The two ends exchange SDP + ICE through the
  coordinator's signaling relay (trickle ICE), then talk **directly P2P** over the
  DataChannel — the coordinator never sees the channel traffic (see
  `doc/tech/design.md` §2, `phase-1-p2p-plan.md` Step B).

  Roles:
    * `:offerer` (consumer) — creates the DataChannel + offer on start.
    * `:answerer` (provider) — starts from a received offer, sends an answer.

  Incoming signals (`answer`, `ice`) are fed in via `signal/2`. Lifecycle and data
  are forwarded to the `:handler` pid:
    * `{:peer_open, session}` — DataChannel is open and ready.
    * `{:peer_data, session, data}` — a message arrived from the remote peer.

  ## Start options
    * `:role` — `:offerer` | `:answerer` (required).
    * `:coordinator` — pid of the `LapsusAgent.Coordinator` client (required).
    * `:remote_peer_id` — the other peer's id (required).
    * `:handler` — pid for lifecycle/data messages (default: caller).
    * `:offer` — the remote offer (JSON map), required for `:answerer`.
    * `:ice_servers` — defaults to the configured STUN servers (so NAT hole-punching
      works across the internet, not just on a LAN). Override per call, or globally
      via `config :lapsus_agent, :ice_servers` / the `LAPSUS_STUN_URLS` env var.
    * `:label` — DataChannel label (default `"lapsus"`).
  """
  use GenServer

  require Logger

  alias ExWebRTC.{ICECandidate, PeerConnection, SessionDescription}
  alias LapsusAgent.Coordinator

  # App-level chunking. A DataChannel message has an implementation-defined max size
  # (SCTP/usrsctp fragments up to a ceiling); rather than depend on it, we cap our own
  # frames. Messages up to @chunk go on the wire **raw** — unchanged, so any client
  # (old or new) decodes them as before. Larger payloads are split into @chunk pieces,
  # each carrying a magic header <<0x00, "LPZ", flag>> (flag 1 = more to come, 0 = last).
  # Our JSON payloads are text and never begin with 0x00, so the receiver tells framed
  # chunks from raw messages by that first byte alone. Reassembly relies on the
  # DataChannel being reliable+ordered (SCTP default), so chunks arrive in order.
  @chunk 16_000
  @frame_magic "LPZ"
  # Ceiling on a single reassembled message — far above any real answer, bounds a
  # memory-exhaustion attack from a peer streaming endless non-final chunks.
  @max_reassembly 8_000_000

  # Public STUN fallback (Google + Cloudflare) — only address discovery, no traffic
  # flows through them. Lets ICE gather server-reflexive candidates for NAT hole
  # punching, so two peers behind home routers connect directly. Override globally
  # with `config :lapsus_agent, :ice_servers` or `LAPSUS_STUN_URLS` (e.g. once we run
  # our own coturn). No TURN yet — hard NATs simply won't connect until then.
  @default_stun [
    %{urls: "stun:stun.l.google.com:19302"},
    %{urls: "stun:stun.cloudflare.com:3478"}
  ]

  # --- public API ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Feed an incoming signaling payload (answer/ice) from the coordinator."
  def signal(session, payload), do: GenServer.cast(session, {:signal, payload})

  @doc "Send data to the remote peer over the open DataChannel."
  def send_data(session, data), do: GenServer.cast(session, {:send_data, data})

  # --- GenServer ---

  @impl true
  def init(opts) do
    state = %{
      role: Keyword.fetch!(opts, :role),
      coordinator: Keyword.fetch!(opts, :coordinator),
      remote: Keyword.fetch!(opts, :remote_peer_id),
      handler: Keyword.get(opts, :handler, self()),
      label: Keyword.get(opts, :label, "lapsus"),
      ice_servers: Keyword.get(opts, :ice_servers, default_ice_servers()),
      channel_ref: nil,
      # accumulates chunk payloads (iolist) until a final frame completes the message
      rx_buffer: [],
      rx_size: 0
    }

    {:ok, pc} = PeerConnection.start_link(ice_servers: state.ice_servers)
    state = Map.put(state, :pc, pc)

    {:ok, setup(state, opts), {:continue, :ignore}}
  end

  # offerer: create the data channel + offer up front.
  defp setup(%{role: :offerer} = state, _opts) do
    {:ok, channel} = PeerConnection.create_data_channel(state.pc, state.label)
    {:ok, offer} = PeerConnection.create_offer(state.pc)
    :ok = PeerConnection.set_local_description(state.pc, offer)
    relay(state, "offer", SessionDescription.to_json(offer))
    %{state | channel_ref: channel.ref}
  end

  # answerer: consume the remote offer, reply with an answer.
  defp setup(%{role: :answerer} = state, opts) do
    offer = opts |> Keyword.fetch!(:offer) |> SessionDescription.from_json()
    :ok = PeerConnection.set_remote_description(state.pc, offer)
    {:ok, answer} = PeerConnection.create_answer(state.pc)
    :ok = PeerConnection.set_local_description(state.pc, answer)
    relay(state, "answer", SessionDescription.to_json(answer))
    state
  end

  @impl true
  def handle_continue(:ignore, state), do: {:noreply, state}

  @impl true
  def handle_cast({:signal, %{"kind" => "answer", "data" => data}}, state) do
    :ok = PeerConnection.set_remote_description(state.pc, SessionDescription.from_json(data))
    {:noreply, state}
  end

  def handle_cast({:signal, %{"kind" => "ice", "data" => data}}, state) do
    :ok = PeerConnection.add_ice_candidate(state.pc, ICECandidate.from_json(data))
    {:noreply, state}
  end

  def handle_cast({:signal, _other}, state), do: {:noreply, state}

  def handle_cast({:send_data, data}, %{channel_ref: ref} = state) when not is_nil(ref) do
    send_framed(state, ref, data)
    {:noreply, state}
  end

  # --- ExWebRTC events (we are the PeerConnection's controlling process) ---

  @impl true
  def handle_info({:ex_webrtc, _pc, {:ice_candidate, candidate}}, state) do
    relay(state, "ice", ICECandidate.to_json(candidate))
    {:noreply, state}
  end

  # answerer learns the channel ref when the remote channel arrives.
  def handle_info({:ex_webrtc, _pc, {:data_channel, channel}}, state) do
    {:noreply, %{state | channel_ref: channel.ref}}
  end

  def handle_info({:ex_webrtc, _pc, {:data_channel_state_change, _ref, :open}}, state) do
    notify(state, {:peer_open, self()})
    {:noreply, state}
  end

  # a non-final chunk: buffer its payload, wait for more. Cap total reassembly size so a
  # malicious peer streaming endless non-final chunks can't exhaust memory.
  def handle_info({:ex_webrtc, _pc, {:data, _ref, <<0, @frame_magic, 1, payload::binary>>}}, state) do
    size = state.rx_size + byte_size(payload)

    if size > @max_reassembly do
      Logger.warning("[peer #{state.role}] dropping oversized reassembly (>#{@max_reassembly} bytes)")
      {:noreply, %{state | rx_buffer: [], rx_size: 0}}
    else
      {:noreply, %{state | rx_buffer: [state.rx_buffer, payload], rx_size: size}}
    end
  end

  # a final chunk: reassemble the buffered payloads with this one, deliver, reset.
  def handle_info({:ex_webrtc, _pc, {:data, _ref, <<0, @frame_magic, 0, payload::binary>>}}, state) do
    message = IO.iodata_to_binary([state.rx_buffer, payload])
    notify(state, {:peer_data, self(), message})
    {:noreply, %{state | rx_buffer: [], rx_size: 0}}
  end

  # a raw (unframed) message — the common small-payload path, delivered as-is.
  def handle_info({:ex_webrtc, _pc, {:data, _ref, data}}, state) do
    notify(state, {:peer_data, self(), data})
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, _pc, {:connection_state_change, conn_state}}, state) do
    Logger.debug("[peer #{state.role}] connection #{inspect(conn_state)}")
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, _pc, _event}, state), do: {:noreply, state}

  # --- internals ---

  defp relay(state, kind, data) do
    Coordinator.signal(state.coordinator, state.remote, kind, data)
  end

  defp notify(state, msg), do: send(state.handler, msg)

  # Small payloads go raw (backward compatible); large ones are split into framed
  # chunks. Reliable+ordered SCTP delivers the casts in the order we enqueue them.
  defp send_framed(state, ref, data) when byte_size(data) <= @chunk do
    :ok = PeerConnection.send_data(state.pc, ref, data)
  end

  defp send_framed(state, ref, data) do
    chunks = chunk_binary(data, @chunk)
    last = length(chunks) - 1

    chunks
    |> Enum.with_index()
    |> Enum.each(fn {payload, i} ->
      flag = if i == last, do: 0, else: 1
      :ok = PeerConnection.send_data(state.pc, ref, <<0, @frame_magic, flag, payload::binary>>)
    end)
  end

  defp chunk_binary(bin, size) when byte_size(bin) <= size, do: [bin]

  defp chunk_binary(bin, size) do
    <<head::binary-size(size), rest::binary>> = bin
    [head | chunk_binary(rest, size)]
  end

  defp default_ice_servers, do: Application.get_env(:lapsus_agent, :ice_servers, @default_stun)
end
