defmodule LapsusAgent.UI.DashboardLive do
  @moduledoc "The provider app's screen: sharing, contribution, models, status."
  use Phoenix.LiveView
  import LapsusAgent.UI.Components

  alias LapsusAgent.{Consumer, Provider, ProviderControl, Settings}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(1500, :tick)
    {:ok, assign(socket, status: ProviderControl.status(), peer_id: Consumer.peer_id(), error: nil, show_settings: false, quitting: false)}
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, refresh(socket)}

  # Quit the whole app: stop the BEAM after a short beat so the goodbye screen
  # paints in the browser first. Works the same for the .app, Linux and Windows.
  def handle_info(:shutdown, socket) do
    System.stop(0)
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_sharing", _params, socket) do
    if ProviderControl.running?() do
      ProviderControl.stop()
      {:noreply, refresh(socket)}
    else
      case ProviderControl.start() do
        {:ok, _} -> {:noreply, refresh(socket)}
        {:error, {:no_local_engine, _}} -> {:noreply, assign(socket, error: "No local engine found — start Ollama (:11434) or LM Studio (:1234).")}
        {:error, reason} -> {:noreply, assign(socket, error: inspect(reason))}
      end
    end
  end

  def handle_event("toggle_model", %{"model" => model, "on" => on}, socket) do
    Provider.set_model(model, on == "true")
    {:noreply, refresh(socket)}
  end

  def handle_event("toggle_settings", _params, socket) do
    {:noreply, assign(socket, show_settings: !socket.assigns.show_settings)}
  end

  def handle_event("quit", _params, socket) do
    if ProviderControl.running?(), do: ProviderControl.stop()
    Process.send_after(self(), :shutdown, 500)
    {:noreply, assign(socket, quitting: true)}
  end

  def handle_event("update_settings", params, socket) do
    if ProviderControl.running?() do
      Provider.set_settings(Settings.update(socket.assigns.status.settings, params))
    end

    {:noreply, refresh(socket)}
  end

  # Switch the serving engine: persist the choice and restart sharing so the
  # provider re-detects the chosen engine's models.
  def handle_event("set_engine", %{"engine" => e}, socket) when e in ["openai", "ollama"] do
    cond do
      not ProviderControl.running?() ->
        {:noreply, socket}

      socket.assigns.status.engine == String.to_existing_atom(e) ->
        {:noreply, socket}

      true ->
        socket.assigns.status.settings |> Settings.update(%{"engine" => e}) |> Settings.save()
        ProviderControl.stop()
        ProviderControl.start()
        {:noreply, refresh(socket)}
    end
  end

  defp refresh(socket), do: assign(socket, status: ProviderControl.status(), error: nil)

  @impl true
  def render(%{quitting: true} = assigns) do
    ~H"""
    <.shutdown_notice />
    """
  end

  def render(assigns) do
    settings = Map.get(assigns.status, :settings)
    put_separator(if settings, do: Settings.separator(settings), else: ".")

    ~H"""
    <.app_shell active={:share} peer_id={@peer_id} sharing={@status.running}>
    <div :if={@error} class="card" style="border-color:var(--fg)">{@error}</div>

    <h1>Share AI</h1>
    <div class="sub">
      Put your idle GPU to work for the community. Choose your engine and the models you share —
      the global Sharing switch lives in the top bar.
    </div>

    <div :if={!@status.running} class="card sec">
      <div class="body" style="margin-top:0">
        <span class="muted" style="font-size:.92rem">
          Sharing is off — turn it on in the top bar to choose your engine and models.
        </span>
      </div>
    </div>

    <div :if={@status.running} class="card sec">
      <h3>Engine</h3>
      <div class="body">
        <div class="enginerow">
          <button class={"engside #{if @status.engine == :openai, do: "on"}"}
                  phx-click="set_engine" phx-value-engine="openai" disabled={:openai not in @status.available}>
            <.engine_icon engine={:openai} size={14} /> LM Studio
            <span :if={:openai not in @status.available} class="muted" style="font-size:.78rem">(not detected)</span>
            <span class={"hdot #{if :openai in @status.available, do: "up", else: "down"}"}></span>
          </button>
          <button class={"sw #{if @status.engine == :ollama, do: "on"}"}
                  phx-click="set_engine" phx-value-engine={if @status.engine == :openai, do: "ollama", else: "openai"}
                  disabled={engine_target(@status) not in @status.available}
                  aria-label="switch engine">
            <span class="knob"></span>
          </button>
          <button class={"engside #{if @status.engine == :ollama, do: "on"}"}
                  phx-click="set_engine" phx-value-engine="ollama" disabled={:ollama not in @status.available}>
            <span class={"hdot #{if :ollama in @status.available, do: "up", else: "down"}"}></span>
            <.engine_icon engine={:ollama} size={14} /> Ollama
            <span :if={:ollama not in @status.available} class="muted" style="font-size:.78rem">(not detected)</span>
          </button>
        </div>
      </div>
    </div>

    <div :if={@status.running} class="card sec">
      <h3>Shared models <span :if={@status.models == []} class="muted">— none detected</span></h3>
      <div class="body">
        <div :if={@status.models != []} class="mrow mhead">
          <span class="muted">Available models on your machine</span>
          <span class="muted">Share</span>
        </div>
        <div :for={m <- @status.models} class={"mrow #{unless m.enabled, do: "off"}"}>
          <span>
            <span class="name">{m.name}</span>
            <span :if={m.loaded} class="tag">loaded</span>
          </span>
          <button class={"sw #{if m.enabled, do: "on"}"} phx-click="toggle_model"
                  phx-value-model={m.name} phx-value-on={to_string(!m.enabled)}
                  aria-label={"toggle #{m.name}"}>
            <span class="knob"></span>
          </button>
        </div>
      </div>
    </div>

    <div :if={@status.running} class="card sec">
      <div class="row">
        <h3>Contribution</h3>
        <span :if={@status.paused} style="font-weight:600;font-size:.82rem;background:#000;color:#fff;padding:.2rem .6rem;border-radius:999px">
          ⏸ paused — your machine is in use
        </span>
      </div>
      <div class="body">
        <div style="margin-bottom:.2rem">
          Sharing <strong style="font-size:1.05rem">{@status.settings.contribution_pct}%</strong>
          of a full day's capacity
        </div>
        <form phx-change="update_settings">
          <input type="range" name="contribution_pct" min="0" max="100" step="5"
                 value={@status.settings.contribution_pct} style="display:block;max-width:520px;margin:.3rem auto" />
          <div class="ticks" style="max-width:520px;margin:.2rem auto 0">
            <span>0</span><span>25</span><span>50</span><span>75</span><span>100</span>
          </div>
        </form>
        <div style="display:flex;align-items:center;gap:.5rem;justify-content:center;margin-top:.7rem;flex-wrap:wrap">
          <label class="muted" style="font-size:.85rem">A full day means</label>
          <span style="display:inline-flex;gap:.3rem">
            <button :for={h <- [4, 8, 12]} type="button" phx-click="update_settings" phx-value-anchor_hours={h}
              style={"border:1px solid var(--line);border-radius:7px;padding:.28rem .7rem;font:inherit;font-size:.85rem;cursor:pointer;" <> if(@status.settings.anchor_hours == h, do: "background:#000;color:#fff;border-color:#000", else: "background:#fff;color:#000")}>
              {h}h
            </button>
          </span>
          <label class="muted" style="font-size:.85rem">of generation</label>
        </div>
        <div class="muted" style="font-size:.86rem;margin-top:.7rem;line-height:1.55">
          Your model runs at ~<strong>{@status.tps}</strong> tok/s →
          up to <strong>~{fmt(@status.daily_budget, @status.settings)}</strong> output tokens/day
          (≈ {fmt(@status.est_requests, @status.settings)} requests), each request capped at
          {fmt(@status.settings.max_out_per_req, @status.settings)} tokens.
          Sharing pauses automatically when your own use slows the model down.
        </div>

        <div style="margin-top:.9rem">
          <div class="row" style="font-size:.85rem;margin-bottom:.35rem">
            <span>Today's budget used</span>
            <span class="muted" style="font-variant-numeric:tabular-nums">
              {fmt(@status.out_today, @status.settings)} / {fmt(@status.daily_budget, @status.settings)} tok · {budget_pct(@status)}%
            </span>
          </div>
          <div style="height:8px;border-radius:999px;background:var(--line);overflow:hidden">
            <div style={"height:100%;background:#000;transition:width .4s;width:#{budget_pct(@status)}%"}></div>
          </div>
          <div class="muted" style="font-size:.8rem;margin-top:.35rem">
            {fmt(@status.remaining_today, @status.settings)} tokens left today · {@status.served_today} requests served
          </div>
        </div>
      </div>
    </div>

    <div :if={@status.running} class="card sec">
      <div class="row">
        <div>
          <h3 style="margin-bottom:.25rem">Detailed settings</h3>
          <div :if={!@show_settings} class="muted" style="font-size:.88rem">Advanced limits — max concurrent requests, max output tokens per request.</div>
        </div>
        <button class="gearbtn" phx-click="toggle_settings" aria-label="toggle detailed settings">
          <svg :if={!@show_settings} width="27" height="27" viewBox="0 0 24 24" fill="currentColor" style="display:block">
            <path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.488.488 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 0 0-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z" />
          </svg>
          <svg :if={@show_settings} width="27" height="27" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round" style="display:block">
            <path d="M5 15l7-7 7 7" />
          </svg>
        </button>
      </div>
      <div :if={@show_settings} class="body" style="margin-top:.9rem">
          <form phx-change="update_settings" class="frow">
            <div>
              <label>Max concurrent requests</label>
              <input type="number" name="max_concurrency" min="1" max="16" value={@status.settings.max_concurrency} phx-debounce="blur" />
            </div>
            <div>
              <label>Max output tokens / request</label>
              <input type="number" name="max_out_per_req" min="64" max="32768" step="64" value={@status.settings.max_out_per_req} phx-debounce="blur" />
            </div>
            <div>
              <label>Auto-pause when busy</label>
              <select name="pause_when_busy">
                <option value="true" selected={@status.settings.pause_when_busy}>On</option>
                <option value="false" selected={!@status.settings.pause_when_busy}>Off</option>
              </select>
            </div>
            <div>
              <label>Pause cooldown (seconds)</label>
              <input type="number" name="busy_cooldown_s" min="15" max="600" step="15" value={@status.settings.busy_cooldown_s} phx-debounce="blur" />
            </div>
            <div>
              <label>Number format</label>
              <select name="number_format">
                <option value="eu" selected={@status.settings.number_format == "eu"}>1.234 (European)</option>
                <option value="us" selected={@status.settings.number_format == "us"}>1,234 (US)</option>
              </select>
            </div>
          </form>
          <div class="muted" style="font-size:.82rem;margin-top:.6rem">
            Auto-pause watches your model's speed: if a served request runs far below its usual
            throughput, we assume you're using the machine and stop sharing for the cooldown.
            Per-consumer fairness is handled centrally by the coordinator.
          </div>
          <div class="row" style="border-top:1px solid var(--line);margin-top:.9rem;padding-top:.7rem">
            <span class="muted">Your peer ID</span>
            <span>
              <code>{String.slice(@status.peer_id, 0, 22)}…</code>
              <button class="gear" style="margin-left:.4rem" title="copy" onclick={"navigator.clipboard.writeText('#{@status.peer_id}')"}>copy</button>
            </span>
          </div>
      </div>
    </div>

    <div :if={@status.running} class="card sec">
      <h3>Status</h3>
      <div class="body kvs">
        <div class="row">
          <span class="muted">Local engine</span>
          <span style="display:inline-flex;align-items:center;gap:.5rem">
            <.engine_icon engine={@status.engine} /> {engine_label(@status.engine)}
            <span class={"hdot #{if @status.engine in @status.available, do: "up", else: "down"}"}></span>
          </span>
        </div>
        <div class="row">
          <span class="muted">Current model</span>
          <code>{current_model(@status)}</code>
        </div>
        <div class="row"><span class="muted">Error rate</span><span>{error_rate(@status)}</span></div>
      </div>
    </div>

    </.app_shell>
    """
  end

  defp engine_label(:ollama), do: "Ollama"
  defp engine_label(:openai), do: "LM Studio / OpenAI-compatible"
  defp engine_label(other), do: to_string(other)

  # The engine the switch would flip to (opposite of the active one).
  defp engine_target(%{engine: :openai}), do: :ollama
  defp engine_target(_), do: :openai

  defp current_model(%{models: models}) do
    case Enum.filter(models, & &1.loaded) do
      [] -> "none loaded"
      loaded -> Enum.map_join(loaded, ", ", & &1.name)
    end
  end

  defp current_model(_), do: "—"

  defp error_rate(%{serve_ok: ok, serve_err: err}) when ok + err > 0,
    do: "#{num(ok)} ok · #{num(err)} errors (#{round(err / (ok + err) * 100)}%)"

  defp error_rate(_), do: "—"

  # Group thousands using the user's chosen separator (1.234 / 1,234).
  defp fmt(n, settings) when is_integer(n) do
    sep = Settings.separator(settings)

    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1#{sep}")
    |> String.reverse()
  end

  defp fmt(n, _settings), do: to_string(n)

  # Share of today's daily output-token budget already consumed (0–100, capped).
  defp budget_pct(%{daily_budget: b, out_today: o}) when is_integer(b) and b > 0,
    do: min(100, round(o / b * 100))

  defp budget_pct(_), do: 0

  # Stylised per-engine glyphs (hand-drawn stand-ins, not official brand logos).
  attr :engine, :atom, default: nil
  attr :size, :integer, default: 15

  defp engine_icon(%{engine: :ollama} = assigns) do
    ~H"""
    <svg width={@size} height={@size} viewBox="0 0 24 24" fill="currentColor" style="display:block" aria-label="Ollama">
      <%!-- Official Ollama mark (Simple Icons). --%>
      <path d="M16.361 10.26a.894.894 0 0 0-.558.47l-.072.148.001.207c0 .193.004.217.059.353.076.193.152.312.291.448.24.238.51.3.872.205a.86.86 0 0 0 .517-.436.752.752 0 0 0 .08-.498c-.064-.453-.33-.782-.724-.897a1.06 1.06 0 0 0-.466 0zm-9.203.005c-.305.096-.533.32-.65.639a1.187 1.187 0 0 0-.06.52c.057.309.31.59.598.667.362.095.632.033.872-.205.14-.136.215-.255.291-.448.055-.136.059-.16.059-.353l.001-.207-.072-.148a.894.894 0 0 0-.565-.472 1.02 1.02 0 0 0-.474.007Zm4.184 2c-.131.071-.223.25-.195.383.031.143.157.288.353.407.105.063.112.072.117.136.004.038-.01.146-.029.243-.02.094-.036.194-.036.222.002.074.07.195.143.253.064.052.076.054.255.059.164.005.198.001.264-.03.169-.082.212-.234.15-.525-.052-.243-.042-.28.087-.355.137-.08.281-.219.324-.314a.365.365 0 0 0-.175-.48.394.394 0 0 0-.181-.033c-.126 0-.207.03-.355.124l-.085.053-.053-.032c-.219-.13-.259-.145-.391-.143a.396.396 0 0 0-.193.032zm.39-2.195c-.373.036-.475.05-.654.086-.291.06-.68.195-.951.328-.94.46-1.589 1.226-1.787 2.114-.04.176-.045.234-.045.53 0 .294.005.357.043.524.264 1.16 1.332 2.017 2.714 2.173.3.033 1.596.033 1.896 0 1.11-.125 2.064-.727 2.493-1.571.114-.226.169-.372.22-.602.039-.167.044-.23.044-.523 0-.297-.005-.355-.045-.531-.288-1.29-1.539-2.304-3.072-2.497a6.873 6.873 0 0 0-.855-.031zm.645.937a3.283 3.283 0 0 1 1.44.514c.223.148.537.458.671.662.166.251.26.508.303.82.02.143.01.251-.043.482-.08.345-.332.705-.672.957a3.115 3.115 0 0 1-.689.348c-.382.122-.632.144-1.525.138-.582-.006-.686-.01-.853-.042-.57-.107-1.022-.334-1.35-.68-.264-.28-.385-.535-.45-.946-.03-.192.025-.509.137-.776.136-.326.488-.73.836-.963.403-.269.934-.46 1.422-.512.187-.02.586-.02.773-.002zm-5.503-11a1.653 1.653 0 0 0-.683.298C5.617.74 5.173 1.666 4.985 2.819c-.07.436-.119 1.04-.119 1.503 0 .544.064 1.24.155 1.721.02.107.031.202.023.208a8.12 8.12 0 0 1-.187.152 5.324 5.324 0 0 0-.949 1.02 5.49 5.49 0 0 0-.94 2.339 6.625 6.625 0 0 0-.023 1.357c.091.78.325 1.438.727 2.04l.13.195-.037.064c-.269.452-.498 1.105-.605 1.732-.084.496-.095.629-.095 1.294 0 .67.009.803.088 1.266.095.555.288 1.143.503 1.534.071.128.243.393.264.407.007.003-.014.067-.046.141a7.405 7.405 0 0 0-.548 1.873c-.062.417-.071.552-.071.991 0 .56.031.832.148 1.279L3.42 24h1.478l-.05-.091c-.297-.552-.325-1.575-.068-2.597.117-.472.25-.819.498-1.296l.148-.29v-.177c0-.165-.003-.184-.057-.293a.915.915 0 0 0-.194-.25 1.74 1.74 0 0 1-.385-.543c-.424-.92-.506-2.286-.208-3.451.124-.486.329-.918.544-1.154a.787.787 0 0 0 .223-.531c0-.195-.07-.355-.224-.522a3.136 3.136 0 0 1-.817-1.729c-.14-.96.114-2.005.69-2.834.563-.814 1.353-1.336 2.237-1.475.199-.033.57-.028.776.01.226.04.367.028.512-.041.179-.085.268-.19.374-.431.093-.215.165-.333.36-.576.234-.29.46-.489.822-.729.413-.27.884-.467 1.352-.561.17-.035.25-.04.569-.04.319 0 .398.005.569.04a4.07 4.07 0 0 1 1.914.997c.117.109.398.457.488.602.034.057.095.177.132.267.105.241.195.346.374.43.14.068.286.082.503.045.343-.058.607-.053.943.016 1.144.23 2.14 1.173 2.581 2.437.385 1.108.276 2.267-.296 3.153-.097.15-.193.27-.333.419-.301.322-.301.722-.001 1.053.493.539.801 1.866.708 3.036-.062.772-.26 1.463-.533 1.854a2.096 2.096 0 0 1-.224.258.916.916 0 0 0-.194.25c-.054.109-.057.128-.057.293v.178l.148.29c.248.476.38.823.498 1.295.253 1.008.231 2.01-.059 2.581a.845.845 0 0 0-.044.098c0 .006.329.009.732.009h.73l.02-.074.036-.134c.019-.076.057-.3.088-.516.029-.217.029-1.016 0-1.258-.11-.875-.295-1.57-.597-2.226-.032-.074-.053-.138-.046-.141.008-.005.057-.074.108-.152.376-.569.607-1.284.724-2.228.031-.26.031-1.378 0-1.628-.083-.645-.182-1.082-.348-1.525a6.083 6.083 0 0 0-.329-.7l-.038-.064.131-.194c.402-.604.636-1.262.727-2.04a6.625 6.625 0 0 0-.024-1.358 5.512 5.512 0 0 0-.939-2.339 5.325 5.325 0 0 0-.95-1.02 8.097 8.097 0 0 1-.186-.152.692.692 0 0 1 .023-.208c.208-1.087.201-2.443-.017-3.503-.19-.924-.535-1.658-.98-2.082-.354-.338-.716-.482-1.15-.455-.996.059-1.8 1.205-2.116 3.01a6.805 6.805 0 0 0-.097.726c0 .036-.007.066-.015.066a.96.96 0 0 1-.149-.078A4.857 4.857 0 0 0 12 3.03c-.832 0-1.687.243-2.456.698a.958.958 0 0 1-.148.078c-.008 0-.015-.03-.015-.066a6.71 6.71 0 0 0-.097-.725C8.997 1.392 8.337.319 7.46.048a2.096 2.096 0 0 0-.585-.041Zm.293 1.402c.248.197.523.759.682 1.388.03.113.06.244.069.292.007.047.026.152.041.233.067.365.098.76.102 1.24l.002.475-.12.175-.118.178h-.278c-.324 0-.646.041-.954.124l-.238.06c-.033.007-.038-.003-.057-.144a8.438 8.438 0 0 1 .016-2.323c.124-.788.413-1.501.696-1.711.067-.05.079-.049.157.013zm9.825-.012c.17.126.358.46.498.888.28.854.36 2.028.212 3.145-.019.14-.024.151-.057.144l-.238-.06a3.693 3.693 0 0 0-.954-.124h-.278l-.119-.178-.119-.175.002-.474c.004-.669.066-1.19.214-1.772.157-.623.434-1.185.68-1.382.078-.062.09-.063.159-.012z" />
    </svg>
    """
  end

  defp engine_icon(%{engine: :openai} = assigns) do
    ~H"""
    <svg width={@size} height={@size} viewBox="0 0 24 24" fill="currentColor" style="display:block" aria-label="LM Studio">
      <%!-- Official LM Studio mark (Simple Icons). --%>
      <path d="M5.6 0A5.6 5.6 0 0 0 0 5.6v12.8A5.6 5.6 0 0 0 5.6 24h12.8a5.6 5.6 0 0 0 5.6-5.6V5.6A5.6 5.6 0 0 0 18.4 0zm0 2h12.8A3.6 3.6 0 0 1 22 5.6v12.8a3.6 3.6 0 0 1-3.6 3.6H5.6A3.6 3.6 0 0 1 2 18.4V5.6A3.6 3.6 0 0 1 5.6 2m-.4 2.8a1.2 1.2 0 0 0 0 2.4h10.4a1.2 1.2 0 0 0 0-2.4zm3.2 4a1.2 1.2 0 0 0 0 2.4h10.4a1.2 1.2 0 0 0 0-2.4zm-3.2 4a1.2 1.2 0 0 0 0 2.4h10.4a1.2 1.2 0 0 0 0-2.4zm3.2 4a1.2 1.2 0 0 0 0 2.4h10.4a1.2 1.2 0 0 0 0-2.4z" />
    </svg>
    """
  end

  defp engine_icon(assigns) do
    ~H"""
    <svg width={@size} height={@size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
         stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="display:block;opacity:.7">
      <rect x="6" y="6" width="12" height="12" rx="2" />
      <path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3" />
    </svg>
    """
  end

end
