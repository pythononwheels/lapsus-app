defmodule LapsusAgent.UI.NetworkLive do
  @moduledoc """
  Community network stats — fetched from the coordinator's public `GET /api/stats`
  (aggregate-only) and rendered locally. Nothing per-peer, nothing private.
  """
  use Phoenix.LiveView
  import LapsusAgent.UI.Components

  alias LapsusAgent.{Consumer, ProviderControl}

  @refresh_ms 20_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :load_stats)
      :timer.send_interval(@refresh_ms, :load_stats)
    end

    {:ok,
     assign(socket,
       stats: nil,
       error: nil,
       loading: connected?(socket),
       quitting: false,
       sharing: ProviderControl.running?(),
       peer_id: Consumer.peer_id()
     )}
  end

  @impl true
  def handle_info(:load_stats, socket) do
    parent = self()
    Task.start(fn -> send(parent, {:stats, fetch_stats()}) end)
    {:noreply, socket}
  end

  def handle_info({:stats, {:ok, s}}, socket), do: {:noreply, assign(socket, stats: s, error: nil, loading: false)}

  def handle_info({:stats, _err}, socket),
    do: {:noreply, assign(socket, error: "couldn't reach the coordinator", loading: false)}

  def handle_info(:shutdown, socket) do
    System.stop(0)
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_sharing", _params, socket) do
    if ProviderControl.running?(), do: ProviderControl.stop(), else: ProviderControl.start()
    {:noreply, assign(socket, sharing: ProviderControl.running?())}
  end

  def handle_event("quit", _params, socket) do
    Process.send_after(self(), :shutdown, 500)
    {:noreply, assign(socket, quitting: true)}
  end

  @impl true
  def render(%{quitting: true} = assigns), do: ~H"<.shutdown_notice />"

  def render(assigns) do
    ~H"""
    <.app_shell active={:network} peer_id={@peer_id} sharing={@sharing}>
      <div class="eyebrow">Community network</div>
      <h1 style="font-size:1.8rem;line-height:1.1;margin:.3rem 0 .3rem">The commons, in numbers</h1>
      <p class="muted" style="margin-bottom:1.4rem">
        Aggregate stats from the whole network — the coordinator never sees your prompts, only these totals.
      </p>

      <div :if={@error} class="card" style="border-color:var(--fg)">{@error}</div>
      <div :if={@loading && !@stats} class="muted">loading…</div>

      <div :if={@stats}>
        <.lbl t="All time" />
        <div class="trio">
          <.stat n={fmt(@stats["lifetime"]["tokens"])} label="tokens processed" />
          <.stat n={fmt(@stats["lifetime"]["jobs"])} label="jobs served" />
          <.stat n={fmt(@stats["lifetime"]["cc"]) <> " CC"} label="credits settled" />
        </div>

        <.lbl t="Last 7 days" top />
        <div class="trio">
          <.stat n={fmt(@stats["window7"]["tokens"])} label="tokens" />
          <.stat n={fmt(@stats["window7"]["jobs"])} label="jobs" />
          <.stat n={fmt(@stats["window7"]["active_consumers"])} label="active users" />
        </div>

        <.lbl t="Right now" top />
        <div class="trio">
          <.stat n={fmt(@stats["current"]["nodes_online"])} label="nodes online" />
          <.stat n={fmt(@stats["current"]["providers_online"])} label="providers sharing" />
          <.stat n={fmt(@stats["current"]["models"])} label="models offered" />
        </div>

        <p class="muted" style="margin-top:1.6rem;font-size:.85rem">
          Live from <a href="https://lapsus.pyrates.io/api/stats" target="_blank" rel="noopener">lapsus.pyrates.io/api/stats</a>
          · refreshes every 20s.
        </p>
      </div>
    </.app_shell>
    """
  end

  attr :t, :string, required: true
  attr :top, :boolean, default: false

  defp lbl(assigns) do
    ~H"""
    <div style={"font-size:.72rem;font-weight:800;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);margin:#{if @top, do: "1.6rem", else: "0"} 0 .6rem"}>
      {@t}
    </div>
    """
  end

  attr :n, :string, required: true
  attr :label, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div class="tcard">
      <div style="font-size:1.9rem;font-weight:800;letter-spacing:-.02em;font-variant-numeric:tabular-nums">{@n}</div>
      <p style="margin:.2rem 0 0">{@label}</p>
    </div>
    """
  end

  defp fetch_stats do
    url = base() <> "/api/stats"

    case Req.get(url, connect_options: [timeout: 5_000], receive_timeout: 5_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: s}} when is_map(s) -> {:ok, s}
      other -> {:error, other}
    end
  end

  defp base do
    LapsusAgent.Coordinator.default_url()
    |> String.replace_prefix("wss://", "https://")
    |> String.replace_prefix("ws://", "http://")
    |> String.split("/")
    |> Enum.take(3)
    |> Enum.join("/")
  end

  defp fmt(n) when is_integer(n),
    do: n |> Integer.to_string() |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()

  defp fmt(n), do: to_string(n || 0)
end
