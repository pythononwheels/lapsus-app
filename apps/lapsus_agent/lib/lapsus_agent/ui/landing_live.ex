defmodule LapsusAgent.UI.LandingLive do
  @moduledoc "Home — the node overview / management console for this machine."
  use Phoenix.LiveView
  import LapsusAgent.UI.Components

  alias LapsusAgent.{Consumer, ProviderControl, Settings}

  @impl true
  def mount(_params, _session, socket) do
    if Settings.onboarded?() do
      if connected?(socket) do
        :timer.send_interval(1500, :tick)
        send(self(), :load_overview)
      end

      {:ok,
       assign(socket,
         status: ProviderControl.status(),
         peer_id: Consumer.peer_id(),
         balance: nil,
         net_models: nil,
         error: nil,
         quitting: false
       )}
    else
      {:ok, redirect(socket, to: "/welcome")}
    end
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, assign(socket, status: ProviderControl.status())}

  def handle_info(:shutdown, socket) do
    System.stop(0)
    {:noreply, socket}
  end

  # Balance + network model count come from the coordinator, so they're shown even
  # when sharing is off. Fetched once on connect (the tick keeps local status fresh).
  def handle_info(:load_overview, socket) do
    parent = self()
    Task.start(fn -> send(parent, {:balance, Consumer.usage(1)}) end)
    Task.start(fn -> send(parent, {:net_models, Consumer.network_models()}) end)
    {:noreply, socket}
  end

  def handle_info({:balance, {:ok, %{"balance" => bal}}}, socket), do: {:noreply, assign(socket, balance: bal)}
  def handle_info({:balance, _}, socket), do: {:noreply, socket}
  def handle_info({:net_models, {:ok, models}}, socket), do: {:noreply, assign(socket, net_models: length(models))}
  def handle_info({:net_models, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_sharing", _params, socket) do
    if ProviderControl.running?() do
      ProviderControl.stop()
      {:noreply, assign(socket, status: ProviderControl.status(), error: nil)}
    else
      case ProviderControl.start() do
        {:ok, _} ->
          {:noreply, assign(socket, status: ProviderControl.status(), error: nil)}

        {:error, {:no_local_engine, _}} ->
          {:noreply, assign(socket, error: "No local engine found — start Ollama (:11434) or LM Studio (:1234).")}

        {:error, reason} ->
          {:noreply, assign(socket, error: inspect(reason))}
      end
    end
  end

  def handle_event("quit", _params, socket) do
    if ProviderControl.running?(), do: ProviderControl.stop()
    Process.send_after(self(), :shutdown, 500)
    {:noreply, assign(socket, quitting: true)}
  end

  @impl true
  def render(%{quitting: true} = assigns) do
    ~H"""
    <.shutdown_notice />
    """
  end

  def render(assigns) do
    on = assigns.status[:running] == true
    assigns = assign(assigns, running: on)

    ~H"""
    <.app_shell active={:home} peer_id={@peer_id}>
      <h1>Node overview</h1>
      <div class="sub">
        Your machine on the LAPSUS network — what it shares, uses and earns. Everything here runs locally.
      </div>

      <div :if={@error} class="card" style="border-color:var(--fg);margin-top:0;margin-bottom:1rem">{@error}</div>

      <div class="tiles" style="grid-template-columns:repeat(3,1fr)">
        <div class="tile">
          <strong>
            <span class={"dot #{if @running, do: "on", else: "off"}"}></span>{if @running, do: "Online", else: "Offline"}
          </strong>
          <span class="muted">Status</span>
        </div>
        <div class="tile"><strong>{tile_val(@running && @status[:balance] || @balance)}</strong><span class="muted">CC balance</span></div>
        <div class="tile"><strong style="font-size:.98rem">{if @running, do: engine_label(@status[:engine]), else: "—"}</strong><span class="muted">Local engine</span></div>
        <div class="tile"><strong>{tile_val(@running && @status[:served_today])}</strong><span class="muted">Served today</span></div>
        <div class="tile"><strong>{tile_val(@running && @status[:earned_today])}</strong><span class="muted">CC earned today</span></div>
        <div class="tile"><strong>{tile_val(@net_models)}</strong><span class="muted">Models on the network</span></div>
      </div>

      <div class="card sec">
        <div class="row">
          <div>
            <h3>Sharing</h3>
            <div class="muted" style="font-size:.88rem;margin-top:.2rem">
              {if @running, do: "Online — your machine is part of the commons. Switch off to go offline instantly.", else: "Offline — flip on to put this machine to work for the community."}
            </div>
          </div>
          <button class={"sw #{if @running, do: "on"}"} phx-click="toggle_sharing" aria-label="toggle sharing">
            <span class="knob"></span>
          </button>
        </div>
      </div>

      <div class="row" style="margin:.4rem 0 1rem;gap:.8rem">
        <a href="/provider" class="btn btn-primary">Open Share AI →</a>
        <a href="/ask" class="btn btn-secondary">Open Use AI →</a>
      </div>

      <div class="console">
        <span class="ok">●</span> connected to lapsus.pyrates.io<br />
        peer {@peer_id}<br />
        {console_line(@running, @status)}
      </div>
    </.app_shell>
    """
  end

  defp tile_val(nil), do: "—"
  defp tile_val(false), do: "—"
  defp tile_val(n) when is_integer(n), do: num(n)
  defp tile_val(other), do: to_string(other)

  defp engine_label(:ollama), do: "Ollama"
  defp engine_label(:openai), do: "LM Studio"
  defp engine_label(nil), do: "—"
  defp engine_label(other), do: to_string(other)

  defp console_line(true, status),
    do: "engine=#{status[:engine]} · #{length(status[:models] || [])} model(s) · sharing on"

  defp console_line(false, _status), do: "sharing off — not serving"
end
