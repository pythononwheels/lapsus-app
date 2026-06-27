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
    * `:ice_servers` — defaults to `[]` (host candidates; fine on localhost/LAN).
    * `:label` — DataChannel label (default `"lapsus"`).
  """
  use GenServer

  require Logger

  alias ExWebRTC.{ICECandidate, PeerConnection, SessionDescription}
  alias LapsusAgent.Coordinator

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
      ice_servers: Keyword.get(opts, :ice_servers, []),
      channel_ref: nil
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
    :ok = PeerConnection.send_data(state.pc, ref, data)
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
end
