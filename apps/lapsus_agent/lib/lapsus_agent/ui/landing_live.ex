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
        send(self(), :check_update)
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
         prov_page: 0,
         cons_page: 0,
         log_size: 10,
         error: nil,
         quitting: false,
         update: nil
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

  # Update check runs once on connect; network call lives in a task so it never
  # blocks the dashboard from rendering.
  def handle_info(:check_update, socket) do
    parent = self()
    Task.start(fn -> send(parent, {:update_result, LapsusAgent.Version.check_update()}) end)
    {:noreply, socket}
  end

  def handle_info({:update_result, result}, socket), do: {:noreply, assign(socket, update: result)}

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

  def handle_event("check_update", _params, socket) do
    parent = self()
    Task.start(fn -> send(parent, {:update_result, LapsusAgent.Version.check_update()}) end)
    {:noreply, assign(socket, update: :checking)}
  end

  def handle_event("set_range", %{"range" => range}, socket) do
    parent = self()
    days = range_days(range)
    Task.start(fn -> send(parent, {:usage, Consumer.full_usage(days)}) end)
    {:noreply, assign(socket, range: range, loading_usage: true)}
  end

  def handle_event("log_size", %{"size" => s}, socket) do
    size = if s == "25", do: 25, else: 10
    {:noreply, assign(socket, log_size: size, prov_page: 0, cons_page: 0)}
  end

  def handle_event("log_page", %{"role" => role, "dir" => dir}, socket) do
    key = if role == "provider", do: :prov_page, else: :cons_page
    rows = log_rows(socket.assigns.usage, role)
    last = max(0, ceil(length(rows) / socket.assigns.log_size) - 1)
    step = if dir == "next", do: 1, else: -1
    page = (socket.assigns[key] + step) |> max(0) |> min(last)
    {:noreply, assign(socket, [{key, page}])}
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

      <div :if={@error} class="dcard" style="border-color:var(--bad)">{@error}</div>

      <div :if={match?({:update, _, _}, @update)} class="dcard update">
        <div class="u-txt">
          <strong>Update available — {update_tag(@update)}</strong><br />
          <span class="muted">You're running {LapsusAgent.Version.current()}. Get the latest in one command.</span>
        </div>
        <a class="btn btn-primary" href={update_url(@update)} target="_blank" rel="noopener">Get the update</a>
      </div>

      <section class="dcard">
        <h3>Overview</h3>
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
      </section>

      <section class="dcard">
        <div class="row">
          <h3>Activity <span class="muted">· {range_label(@range)}</span></h3>
          <div class="pills">
            <button :for={{label, _d} <- ranges()} class={"pill #{if @range == label, do: "on"}"}
                    phx-click="set_range" phx-value-range={label}>{label}</button>
          </div>
        </div>
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

        <.log_panel title="Requests served" note="you as provider" rows={log_rows(@usage, "provider")}
                    page={@prov_page} size={@log_size} role="provider" />

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

        <.log_panel title="Requests made" note="you as consumer" rows={log_rows(@usage, "consumer")}
                    page={@cons_page} size={@log_size} role="consumer" />
      </section>

      <section class="dcard">
        <h3>Status</h3>
        <dl class="kv">
          <dt>Connected to</dt>
          <dd><span class="ok">●</span> lapsus.pyrates.io</dd>

          <dt>Peer ID</dt>
          <dd class="mono">{@peer_id}</dd>

          <dt>Engine</dt>
          <dd>{engine_summary(@running, @status)}</dd>

          <dt>Sharing</dt>
          <dd>{if @running, do: "On", else: "Off"}</dd>

          <dt>Version</dt>
          <dd>{LapsusAgent.Version.current()}</dd>

          <dt>Updates</dt>
          <dd>
            <button class="updbtn" phx-click="check_update" disabled={@update == :checking}>
              <span aria-hidden="true">↻</span> Check for updates
            </button>
            <span :if={update_status_text(@update) != ""} class="upd-note">{update_status_text(@update)}</span>
          </dd>
        </dl>
      </section>
    </.app_shell>
    """
  end

  defp update_tag({:update, tag, _url}), do: tag
  defp update_url({:update, _tag, url}), do: url

  defp update_status_text(:checking), do: "checking…"
  defp update_status_text(:current), do: "you're up to date ✓"
  defp update_status_text({:update, tag, _url}), do: "update available — #{tag}"
  defp update_status_text({:dev, _tag, _url}), do: "development build"
  defp update_status_text(:dev), do: "development build"
  defp update_status_text(:unknown), do: "couldn't reach github"
  defp update_status_text(_), do: ""

  defp tile_val(nil), do: "—"
  defp tile_val(false), do: "—"
  defp tile_val(n) when is_integer(n), do: num(n)
  defp tile_val(other), do: to_string(other)

  defp engine_label(:ollama), do: "Ollama"
  defp engine_label(:openai), do: "LM Studio"
  defp engine_label(nil), do: "—"
  defp engine_label(other), do: to_string(other)

  defp engine_summary(true, status),
    do: "#{engine_label(status[:engine])} · #{length(status[:models] || [])} model(s)"

  defp engine_summary(false, _status), do: "—"

  # --- usage / charts helpers ---

  # Selectable windows for the dashboard charts. {label, days}.
  defp ranges,
    do: [{"today", 1}, {"week", 7}, {"month", 30}, {"3 months", 90}, {"6 months", 180}, {"year", 365}, {"all", 3660}]

  defp range_days(range), do: Enum.find_value(ranges(), 7, fn {l, d} -> if l == range, do: d end)

  defp range_label("today"), do: "today"
  defp range_label("week"), do: "last 7 days"
  defp range_label("month"), do: "last 30 days"
  defp range_label("all"), do: "all time"
  defp range_label(other), do: "last #{other}"

  # The recent-job list for a role from the usage payload (string-keyed, from the wire).
  defp log_rows(%{} = usage, key), do: Map.get(usage, "#{key}_recent") || []
  defp log_rows(_usage, _key), do: []

  # A paginated, non-identifying request log (time · model · in/out · CC · ok · #peer).
  attr :title, :string, required: true
  attr :note, :string, required: true
  attr :rows, :list, required: true
  attr :page, :integer, required: true
  attr :size, :integer, required: true
  attr :role, :string, required: true

  defp log_panel(assigns) do
    total = length(assigns.rows)
    pages = max(1, ceil(total / assigns.size))
    page = min(assigns.page, pages - 1)

    assigns =
      assign(assigns, total: total, pages: pages, page: page, slice: Enum.slice(assigns.rows, page * assigns.size, assigns.size))

    ~H"""
    <section class="panel logpanel">
      <div class="row">
        <h4>{@title} <span class="muted">· {@note}{if @total > 0, do: " · #{@total}", else: ""}</span></h4>
        <div class="pills">
          <button class={"pill #{if @size == 10, do: "on"}"} phx-click="log_size" phx-value-size="10">10</button>
          <button class={"pill #{if @size == 25, do: "on"}"} phx-click="log_size" phx-value-size="25">25</button>
        </div>
      </div>

      <p :if={@total == 0} class="muted" style="padding:.5rem 0 0">No requests yet.</p>

      <table :if={@total > 0} class="logtbl">
        <thead>
          <tr><th>Time</th><th>Model</th><th class="r">in/out</th><th class="r">CC</th><th></th><th class="r">peer</th></tr>
        </thead>
        <tbody>
          <tr :for={r <- @slice}>
            <td class="mono muted">{fmt_ts(r["ts"])}</td>
            <td class="mono">{r["model"]}</td>
            <td class="mono r">{num(r["in"] || 0)}/{num(r["out"] || 0)}</td>
            <td class="mono r">{num(r["cc"] || 0)}</td>
            <td class={"c #{if r["ok"], do: "ok", else: "bad"}"}>{if r["ok"], do: "✓", else: "✗"}</td>
            <td class="mono muted r">{r["party"]}</td>
          </tr>
        </tbody>
      </table>

      <div :if={@pages > 1} class="logpg">
        <button class="pill" phx-click="log_page" phx-value-role={@role} phx-value-dir="prev" disabled={@page == 0}>‹ prev</button>
        <span class="muted">{@page + 1} / {@pages}</span>
        <button class="pill" phx-click="log_page" phx-value-role={@role} phx-value-dir="next" disabled={@page + 1 >= @pages}>next ›</button>
      </div>
    </section>
    """
  end

  # "2026-07-03T14:32:…Z" -> "07-03 14:32"
  defp fmt_ts(ts) when is_binary(ts), do: ts |> String.slice(5, 11) |> String.replace("T", " ")
  defp fmt_ts(_), do: ""

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
