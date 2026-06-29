defmodule LapsusAgent.UI.LandingLive do
  @moduledoc "Dashboard — the node overview / management console for this machine."
  use Phoenix.LiveView
  import LapsusAgent.UI.Components

  alias LapsusAgent.{Consumer, ProviderControl, Settings}
  alias LapsusAgent.UI.Charts

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
         range: "week",
         usage: nil,
         loading_usage: true,
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

  # Balance, network model count and the usage charts all come from the
  # coordinator, so they're shown even when sharing is off. Fetched once on
  # connect (the tick keeps local status fresh); the charts refetch on range change.
  def handle_info(:load_overview, socket) do
    parent = self()
    days = range_days(socket.assigns.range)
    Task.start(fn -> send(parent, {:net_models, Consumer.network_models()}) end)
    Task.start(fn -> send(parent, {:usage, Consumer.full_usage(days)}) end)
    {:noreply, socket}
  end

  def handle_info({:net_models, {:ok, models}}, socket), do: {:noreply, assign(socket, net_models: length(models))}
  def handle_info({:net_models, _}, socket), do: {:noreply, socket}

  def handle_info({:usage, {:ok, %{"balance" => bal} = usage}}, socket),
    do: {:noreply, assign(socket, usage: usage, balance: bal, loading_usage: false)}

  def handle_info({:usage, {:ok, usage}}, socket),
    do: {:noreply, assign(socket, usage: usage, loading_usage: false)}

  def handle_info({:usage, _}, socket), do: {:noreply, assign(socket, loading_usage: false)}

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

  def handle_event("set_range", %{"range" => range}, socket) do
    parent = self()
    days = range_days(range)
    Task.start(fn -> send(parent, {:usage, Consumer.full_usage(days)}) end)
    {:noreply, assign(socket, range: range, loading_usage: true)}
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
    settings = Map.get(assigns.status, :settings)
    put_separator(if settings, do: Settings.separator(settings), else: ".")

    assigns =
      assigns
      |> assign(running: on)
      |> assign(locale: if(settings, do: Settings.chart_locale(settings), else: "de-DE"))

    ~H"""
    <.app_shell active={:home} peer_id={@peer_id} sharing={@running}>
      <h1>Dashboard</h1>
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
          <h3>Activity <span class="muted">· {range_label(@range)}</span></h3>
          <div class="pills">
            <button :for={{label, _d} <- ranges()} class={"pill #{if @range == label, do: "on"}"}
                    phx-click="set_range" phx-value-range={label}>{label}</button>
          </div>
        </div>
        <div class="body">
          <div class="usage-grid">
            <section class="panel">
              <h4>Tokens served over time <span class="muted">· as provider</span></h4>
              <div class="chartbox" id="dash-prov-bar" phx-hook="Chart"
                   data-chart={Charts.json(Charts.bar_data(series_days(@usage, "provider"), @locale))}>
                <canvas></canvas>
                <span :if={!has_data?(@usage, "provider")} class="nodata">{nodata_label(@loading_usage)}</span>
              </div>
            </section>
            <section class="panel">
              <h4>Model share <span class="muted">· out tokens</span></h4>
              <div class="chartbox donut" id="dash-prov-donut" phx-hook="Chart"
                   data-chart={Charts.json(Charts.donut_data(series_by_model(@usage, "provider"), @locale))}>
                <canvas></canvas>
                <span :if={!has_data?(@usage, "provider")} class="nodata">{nodata_label(@loading_usage)}</span>
              </div>
            </section>
          </div>

          <div class="usage-grid">
            <section class="panel">
              <h4>Requests over time <span class="muted">· as consumer</span></h4>
              <div class="chartbox" id="dash-cons-bar" phx-hook="Chart"
                   data-chart={Charts.json(Charts.bar_data(series_days(@usage, "consumer"), @locale))}>
                <canvas></canvas>
                <span :if={!has_data?(@usage, "consumer")} class="nodata">{nodata_label(@loading_usage)}</span>
              </div>
            </section>
            <section class="panel">
              <h4>By model <span class="muted">· out tokens</span></h4>
              <div class="chartbox donut" id="dash-cons-donut" phx-hook="Chart"
                   data-chart={Charts.json(Charts.donut_data(series_by_model(@usage, "consumer"), @locale))}>
                <canvas></canvas>
                <span :if={!has_data?(@usage, "consumer")} class="nodata">{nodata_label(@loading_usage)}</span>
              </div>
            </section>
          </div>
        </div>
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

  # --- usage / charts helpers ---

  # Selectable windows for the dashboard charts. {label, days}.
  defp ranges,
    do: [{"week", 7}, {"month", 30}, {"3 months", 90}, {"6 months", 180}, {"year", 365}, {"all", 3660}]

  defp range_days(range), do: Enum.find_value(ranges(), 7, fn {l, d} -> if l == range, do: d end)

  defp range_label("week"), do: "last 7 days"
  defp range_label("month"), do: "last 30 days"
  defp range_label("all"), do: "all time"
  defp range_label(other), do: "last #{other}"

  # Pull one side ("provider" / "consumer") out of the full-usage map; nil-safe so
  # the charts render an empty (but framed) shape before the fetch returns.
  defp side(usage, key) when is_map(usage), do: usage[key]
  defp side(_usage, _key), do: nil

  defp series_days(usage, key) do
    case side(usage, key) do
      %{"days" => days} when is_list(days) -> days
      _ -> []
    end
  end

  defp series_by_model(usage, key) do
    case side(usage, key) do
      %{"by_model" => by_model} when is_list(by_model) -> by_model
      _ -> []
    end
  end

  defp has_data?(usage, key) do
    case side(usage, key) do
      %{"totals" => %{"jobs" => jobs}} when is_integer(jobs) -> jobs > 0
      _ -> false
    end
  end

  defp nodata_label(true), do: "Loading…"
  defp nodata_label(_), do: "No data yet"
end
