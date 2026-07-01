defmodule LapsusAgent.Coordinator do
  @moduledoc """
  Agent-side client to the coordinator's signaling socket (Slipstream).

  Connects to `/peer`, authenticated by an Ed25519 signature over `peer_id:ts`
  (see `LapsusCoordinatorWeb.PeerSocket`), joins `signaling:lobby` with the peer's
  role + offered models, and exposes the coordinator's three services:

    * `list_providers/2` — discover online providers for a model.
    * `signal/4` — relay a WebRTC SDP/ICE payload to a target peer.
    * incoming `"signal"` events are forwarded to the configured `:handler` pid as
      `{:lapsus_signal, payload}` (the WebRTC session manager consumes these).

  This is the control plane only — no inference traffic flows here (that goes P2P).

  ## Start options
    * `:identity` (required) — a `LapsusCore.Identity`.
    * `:url` — coordinator base, default `"ws://localhost:4000"`.
    * `:role` — `"provider"` | `"consumer"` (default `"consumer"`).
    * `:models` — list of offered model ids (providers).
    * `:capacity` — optional capacity hint.
    * `:handler` — pid to receive `{:lapsus_signal, payload}` and `{:lapsus_joined, topic}`.
  """
  use Slipstream

  require Logger

  alias LapsusCore.Identity

  @lobby "signaling:lobby"

  # --- public API ---

  @doc """
  Default coordinator WebSocket base URL. Reads `LAPSUS_COORDINATOR_URL` (e.g.
  `wss://lapsus.pyrates.io` in production), falling back to local dev.
  """
  def default_url, do: System.get_env("LAPSUS_COORDINATOR_URL") || "ws://localhost:4000"

  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    Slipstream.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Find online providers offering `model`. When `min_ctx` is given, only providers
  whose advertised context length is unknown or ≥ `min_ctx` are returned.
  """
  @spec list_providers(GenServer.server(), String.t(), pos_integer() | nil) ::
          {:ok, [map()]} | {:error, term()}
  def list_providers(server \\ __MODULE__, model, min_ctx \\ nil) do
    GenServer.call(server, {:list_providers, model, min_ctx})
  end

  @doc "Fetch this peer's balance + earned-today from the coordinator."
  @spec stats(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @doc "All models currently offered across the network (with provider counts)."
  @spec network_models(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def network_models(server \\ __MODULE__) do
    GenServer.call(server, :network_models)
  end

  @doc "Usage series (provider + consumer view) for this peer over `days`."
  @spec usage(GenServer.server(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def usage(server \\ __MODULE__, days \\ 7) do
    GenServer.call(server, {:usage, days})
  end

  @doc "Verified open-source projects that can receive donations (§03)."
  @spec list_projects(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def list_projects(server \\ __MODULE__), do: GenServer.call(server, :list_projects)

  @doc "Donate `cc` credits to a registered project (authorised by this connection)."
  @spec donate(GenServer.server(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def donate(server \\ __MODULE__, project_id, cc), do: GenServer.call(server, {:donate, project_id, cc})

  @doc "Relay a WebRTC signaling payload to peer `to`."
  @spec signal(GenServer.server(), String.t(), String.t(), term()) :: :ok
  def signal(server \\ __MODULE__, to, kind, data) do
    GenServer.cast(server, {:signal, to, kind, data})
  end

  @doc """
  Update the set of models this peer advertises (re-announce to the coordinator),
  with per-model capabilities `caps` (`name => %{"ctx", "vision"}`).
  """
  @spec update_models(GenServer.server(), [String.t()], map()) :: :ok
  def update_models(server \\ __MODULE__, models, caps \\ %{}) do
    GenServer.cast(server, {:update_models, models, caps})
  end

  @doc """
  Submit a mutually-signed job receipt for booking. Called by the consumer (the
  paying party) once it has co-signed the provider's receipt.
  """
  @spec submit_receipt(GenServer.server(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def submit_receipt(server \\ __MODULE__, receipt, provider_sig, consumer_sig) do
    GenServer.call(server, {:submit_receipt, receipt, provider_sig, consumer_sig})
  end

  @doc """
  Pre-flight funds check: ask the coordinator whether `consumer_id` can afford
  `est_cc`. Called by a provider before it spends compute. Returns
  `{:ok, %{"ok" => boolean, "balance" => integer}}`.
  """
  @spec check_funds(GenServer.server(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def check_funds(server \\ __MODULE__, consumer_id, est_cc) do
    GenServer.call(server, {:check_funds, consumer_id, est_cc})
  end

  @doc """
  Escrow-reserve `est_cc` from `consumer_id` for `request_id` before serving (the
  hard version of `check_funds`). Returns `{:ok, %{"ok" => true}}` on success or
  `{:error, ...}` (e.g. insufficient funds). The hold clears at settlement or via
  the coordinator's reaper.
  """
  @spec reserve(GenServer.server(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def reserve(server \\ __MODULE__, consumer_id, request_id, est_cc) do
    GenServer.call(server, {:reserve, consumer_id, request_id, est_cc})
  end

  @doc "Build the authenticated WebSocket URI (also used in tests)."
  @spec auth_uri(String.t(), Identity.t()) :: String.t()
  def auth_uri(base, %Identity{} = identity) do
    ts = System.os_time(:second)
    sig = identity |> Identity.sign("#{identity.peer_id}:#{ts}") |> Base.encode64()

    query =
      URI.encode_query(%{
        "peer_id" => identity.peer_id,
        "ts" => ts,
        "sig" => sig,
        "vsn" => "2.0.0"
      })

    ws_base = String.replace_prefix(base, "http", "ws")
    "#{ws_base}/peer/websocket?#{query}"
  end

  # --- Slipstream callbacks ---

  @impl Slipstream
  def init(opts) do
    identity = Keyword.fetch!(opts, :identity)
    base = Keyword.get(opts, :url) || default_url()

    join_params = %{
      "role" => Keyword.get(opts, :role, "consumer"),
      "models" => Keyword.get(opts, :models, []),
      "capacity" => Keyword.get(opts, :capacity)
    }

    socket =
      new_socket()
      |> assign(:pending, %{})
      |> assign(:handler, Keyword.get(opts, :handler))
      |> assign(:join_params, join_params)
      |> assign(:peer_id, identity.peer_id)
      |> connect!(uri: auth_uri(base, identity))

    {:ok, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    {:ok, join(socket, @lobby, socket.assigns.join_params)}
  end

  @impl Slipstream
  def handle_join(@lobby, _reply, socket) do
    notify(socket, {:lapsus_joined, @lobby})
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(@lobby, "signal", payload, socket) do
    notify(socket, {:lapsus_signal, payload})
    {:ok, socket}
  end

  def handle_message(_topic, _event, _payload, socket), do: {:ok, socket}

  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    case Map.pop(socket.assigns.pending, ref) do
      {nil, _pending} ->
        {:ok, socket}

      {from, pending} ->
        GenServer.reply(from, normalize_reply(reply))
        {:ok, assign(socket, :pending, pending)}
    end
  end

  @impl Slipstream
  def handle_call({:list_providers, model, min_ctx}, from, socket) do
    {:ok, ref} = push(socket, @lobby, "list_providers", %{"model" => model, "min_ctx" => min_ctx})
    {:noreply, assign(socket, :pending, Map.put(socket.assigns.pending, ref, from))}
  end

  def handle_call(:stats, from, socket) do
    {:ok, ref} = push(socket, @lobby, "stats", %{})
    {:noreply, assign(socket, :pending, Map.put(socket.assigns.pending, ref, from))}
  end

  def handle_call(:network_models, from, socket) do
    {:ok, ref} = push(socket, @lobby, "models", %{})
    {:noreply, assign(socket, :pending, Map.put(socket.assigns.pending, ref, from))}
  end

  def handle_call({:usage, days}, from, socket) do
    {:ok, ref} = push(socket, @lobby, "usage", %{"days" => days})
    {:noreply, assign(socket, :pending, Map.put(socket.assigns.pending, ref, from))}
  end

  def handle_call(:list_projects, from, socket) do
    {:ok, ref} = push(socket, @lobby, "list_projects", %{})
    {:noreply, assign(socket, :pending, Map.put(socket.assigns.pending, ref, from))}
  end

  def handle_call({:donate, project_id, cc}, from, socket) do
    {:ok, ref} = push(socket, @lobby, "donate", %{"project" => project_id, "cc" => cc})
    {:noreply, assign(socket, :pending, Map.put(socket.assigns.pending, ref, from))}
  end

  def handle_call({:submit_receipt, receipt, provider_sig, consumer_sig}, from, socket) do
    {:ok, ref} =
      push(socket, @lobby, "submit_receipt", %{
        "receipt" => receipt,
        "provider_sig" => provider_sig,
        "consumer_sig" => consumer_sig
      })

    {:noreply, assign(socket, :pending, Map.put(socket.assigns.pending, ref, from))}
  end

  def handle_call({:check_funds, consumer_id, est_cc}, from, socket) do
    {:ok, ref} = push(socket, @lobby, "check_funds", %{"consumer_id" => consumer_id, "cc" => est_cc})
    {:noreply, assign(socket, :pending, Map.put(socket.assigns.pending, ref, from))}
  end

  def handle_call({:reserve, consumer_id, request_id, est_cc}, from, socket) do
    {:ok, ref} =
      push(socket, @lobby, "reserve", %{
        "consumer_id" => consumer_id,
        "request_id" => request_id,
        "cc" => est_cc
      })

    {:noreply, assign(socket, :pending, Map.put(socket.assigns.pending, ref, from))}
  end

  @impl Slipstream
  def handle_cast({:signal, to, kind, data}, socket) do
    push!(socket, @lobby, "signal", %{"to" => to, "kind" => kind, "data" => data})
    {:noreply, socket}
  end

  def handle_cast({:update_models, models, caps}, socket) do
    # Tolerate being called before the lobby join completes.
    try do
      push!(socket, @lobby, "update_models", %{"models" => models, "caps" => caps})
    rescue
      _ -> :ok
    end

    {:noreply, socket}
  end

  # --- internals ---

  defp notify(socket, msg) do
    case socket.assigns.handler do
      pid when is_pid(pid) -> send(pid, msg)
      _ -> :ok
    end
  end

  # Channel reply for list_providers is {:ok, %{"providers" => [...]}}.
  defp normalize_reply({:ok, %{"providers" => providers}}), do: {:ok, providers}
  defp normalize_reply({:ok, payload}), do: {:ok, payload}
  defp normalize_reply({:error, reason}), do: {:error, reason}
  defp normalize_reply(other), do: {:error, other}
end
