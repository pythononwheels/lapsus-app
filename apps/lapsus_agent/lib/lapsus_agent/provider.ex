defmodule LapsusAgent.Provider do
  @moduledoc """
  The provider "app" core — what a community member runs to share their local AI.

  Design principle (see `doc/tech/design.md` §4.2c): this is an **app, not a
  service**. Start it to share; quit to stop. "Quit = off" is free via presence.

  On start it loads (or creates) a stable identity, auto-detects the local engine
  (Ollama / LM Studio), connects to the coordinator announcing its enabled models,
  and serves incoming P2P requests — each answered with a provider-signed receipt.

  Contribution is bounded by `LapsusAgent.Settings`: a daily output-token budget
  (derived from measured throughput × the contribution %), a per-consumer share
  cap, max concurrency, and a per-request output cap. Requests are served in tasks
  so the GenServer stays responsive and concurrency is real.
  """
  use GenServer

  require Logger

  alias LapsusAgent.{Coordinator, Engine, Guardrail, Settings}
  alias LapsusAgent.Peer.{Protocol, Session}
  alias LapsusCore.{Credits, Identity, Receipt}

  @default_model_weight 1.0
  @default_tps 30.0
  @nominal_out_per_req 300

  # Throughput-based idle detection: learn each model's unloaded peak tps, and if a
  # served job runs below `@busy_ratio` of that peak, assume the owner is using the
  # machine and pause sharing. `@min_samples` warms the baseline up first; the peak
  # decays slowly so it adapts to hardware/model changes.
  @busy_ratio 0.5
  @baseline_decay 0.97
  @min_samples 3

  # --- public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Snapshot of what the provider is doing + its budget (for UI/status)."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Enable/disable sharing of a single model (re-announces to the coordinator)."
  def set_model(server \\ __MODULE__, model, enabled?),
    do: GenServer.call(server, {:set_model, model, enabled?})

  @doc "Replace the contribution settings (persisted)."
  def set_settings(server \\ __MODULE__, %Settings{} = settings),
    do: GenServer.call(server, {:set_settings, settings})

  @doc "Set the usage dashboard window (in days) and refresh it."
  def set_usage_window(server \\ __MODULE__, days),
    do: GenServer.call(server, {:set_usage_window, days})

  # --- GenServer ---

  @impl true
  def init(opts) do
    identity =
      opts[:identity] ||
        Identity.load_or_create!(opts[:identity_path] || default_identity_path())

    with {:ok, engine, all_models} <- resolve_engine(opts) do
      # We do text request→response only — drop embedding/TTS models.
      models = Enum.filter(all_models, &text_model?/1)

      # Announce nothing yet; reconcile/1 advertises the loaded (or opted-in) set.
      {:ok, coord} =
        Coordinator.start_link(
          identity: identity,
          url: opts[:url] || Coordinator.default_url(),
          role: "provider",
          models: [],
          handler: self()
        )

      Logger.info("[provider] #{identity.peer_id}")
      Logger.info("[provider] engine=#{engine}, models: #{Enum.join(models, ", ")}")

      state = %{
        identity: identity,
        engine: engine,
        models: models,
        # %{model => bool} explicit user overrides; default = "enabled iff loaded".
        overrides: %{},
        announced: {MapSet.new(), %{}},
        joined: false,
        loaded: MapSet.new(),
        caps: %{},
        model_weights: opts[:model_weights] || %{},
        settings: opts[:settings] || Settings.load(),
        coordinator: coord,
        sessions: %{},
        downstreams: %{},
        jobs_served: 0,
        serve_ok: 0,
        serve_err: 0,
        available: MapSet.new([engine]),
        in_flight: 0,
        tps: @default_tps,
        # Per-model unloaded-throughput baseline {peak_tps, samples} + pause deadline.
        baseline_tps: %{},
        paused_until: 0,
        balance: 0,
        earned_today: 0,
        served_today: 0,
        served_total: 0,
        stats_usage: nil,
        usage_days: 7,
        usage: %{date: Date.utc_today(), out: 0, requests: 0, per_consumer: %{}}
      }

      # Poll loaded models (≠ available) and earnings. These states change rarely, so
      # poll slowly — each engine probe makes LM Studio/Ollama log a full model-list
      # response, so tight intervals spam the user's engine log for no benefit.
      send(self(), :refresh_loaded)
      send(self(), :refresh_caps)
      # Loaded set is stable while sharing (user rarely swaps the loaded model).
      :timer.send_interval(30_000, :refresh_loaded)
      # Earnings from the coordinator (no engine call) — fine to keep snappy.
      :timer.send_interval(5_000, :refresh_stats)
      # Capabilities (context length, multimodal) essentially never change.
      :timer.send_interval(300_000, :refresh_caps)
      # Probe which local engines are reachable (for the engine switch + health dot).
      send(self(), :probe_engines)
      :timer.send_interval(60_000, :probe_engines)

      {:ok, state}
    else
      :error -> {:stop, :no_local_engine}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    state = roll_day(state)
    budget = daily_budget(state)
    eff = enabled_set(state)

    models =
      Enum.map(state.models, fn m ->
        %{name: m, enabled: MapSet.member?(eff, m), loaded: MapSet.member?(state.loaded, m)}
      end)

    {:reply,
     %{
       running: true,
       peer_id: state.identity.peer_id,
       engine: state.engine,
       models: models,
       active_sessions: map_size(state.sessions),
       in_flight: state.in_flight,
       jobs_served: max(state.served_total, state.jobs_served),
       available: MapSet.to_list(state.available),
       serve_ok: state.serve_ok,
       serve_err: state.serve_err,
       balance: state.balance,
       earned_today: state.earned_today,
       usage_stats: state.stats_usage,
       usage_days: state.usage_days,
       settings: state.settings,
       tps: Float.round(state.tps, 1),
       daily_budget: budget,
       out_today: state.usage.out,
       served_today: state.served_today,
       remaining_today: max(0, budget - state.usage.out),
       est_requests: div(budget, @nominal_out_per_req),
       paused: paused?(state)
     }, state}
  end

  def handle_call({:set_model, model, enabled?}, _from, state) do
    state = reconcile(%{state | overrides: Map.put(state.overrides, model, enabled?)})
    {:reply, :ok, state}
  end

  def handle_call({:set_settings, settings}, _from, state) do
    Settings.save(settings)
    # Turning auto-pause off resumes immediately; reconcile re-advertises accordingly.
    paused_until = if settings.pause_when_busy, do: state.paused_until, else: 0
    state = reconcile(%{state | settings: settings, paused_until: paused_until})
    {:reply, :ok, state}
  end

  def handle_call({:set_usage_window, days}, _from, state) do
    days = days |> max(1) |> min(3660)
    send(self(), :refresh_stats)
    {:reply, :ok, %{state | usage_days: days}}
  end

  @impl true
  def handle_info({:lapsus_joined, _topic}, state) do
    Logger.info("[provider] online — ready to serve.")
    # A (re)join means the coordinator re-created our Presence from the join params
    # (which advertise *no* models). Clear `announced` so reconcile/1 always
    # re-advertises the current set — otherwise, after an automatic reconnect, we'd
    # linger as a model-less node and vanish from discovery until caps next change.
    {:noreply, reconcile(%{state | joined: true, announced: {MapSet.new(), %{}}})}
  end

  def handle_info({:lapsus_signal, %{"kind" => "offer", "from" => consumer} = p}, state) do
    {:ok, session} =
      Session.start_link(
        role: :answerer,
        coordinator: state.coordinator,
        remote_peer_id: consumer,
        handler: self(),
        offer: p["data"]
      )

    ref = Process.monitor(session)

    {:noreply,
     %{
       state
       | sessions: Map.put(state.sessions, consumer, session),
         downstreams: Map.put(state.downstreams, session, {consumer, ref})
     }}
  end

  def handle_info({:lapsus_signal, %{"from" => from} = p}, state) do
    case state.sessions[from] do
      nil -> :ok
      session -> Session.signal(session, p)
    end

    {:noreply, state}
  end

  def handle_info(:refresh_loaded, state) do
    parent = self()
    engine = state.engine

    Task.start(fn ->
      case Engine.loaded_models(engine) do
        {:ok, names} -> send(parent, {:loaded, MapSet.new(names)})
        _ -> :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info({:loaded, set}, state), do: {:noreply, reconcile(%{state | loaded: set})}

  def handle_info(:refresh_caps, state) do
    parent = self()
    engine = state.engine
    models = state.models

    Task.start(fn ->
      case Engine.caps(engine, models) do
        {:ok, caps} when caps != %{} -> send(parent, {:caps, caps})
        _ -> :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info({:caps, caps}, state), do: {:noreply, reconcile(%{state | caps: caps})}

  def handle_info(:probe_engines, state) do
    parent = self()

    Task.start(fn ->
      reachable =
        for eng <- [:openai, :ollama], match?({:ok, [_ | _]}, Engine.list_models(eng)), into: MapSet.new(), do: eng

      send(parent, {:available, reachable})
    end)

    {:noreply, state}
  end

  def handle_info({:available, set}, state) do
    # Always keep the active engine listed (it's serving even if a probe blipped).
    {:noreply, %{state | available: MapSet.put(set, state.engine)}}
  end

  def handle_info(:refresh_stats, state) do
    parent = self()
    coord = state.coordinator

    Task.start(fn ->
      try do
        case Coordinator.stats(coord) do
          {:ok, stats} -> send(parent, {:stats, stats})
          _ -> :ok
        end

        case Coordinator.usage(coord, state.usage_days) do
          {:ok, usage} -> send(parent, {:usage, usage})
          _ -> :ok
        end
      catch
        _, _ -> :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info({:stats, stats}, state) do
    {:noreply,
     %{
       state
       | balance: stats["balance"] || 0,
         earned_today: stats["earned_today"] || 0,
         served_today: stats["served_today"] || 0,
         served_total: stats["served_total"] || 0
     }}
  end

  def handle_info({:usage, usage}, state) do
    {:noreply, %{state | stats_usage: usage["provider"]}}
  end

  def handle_info({:peer_open, _session}, state), do: {:noreply, state}

  # An inference request arrived over the P2P channel.
  def handle_info({:peer_data, session, data}, state) do
    state = roll_day(state)
    {consumer, _ref} = Map.get(state.downstreams, session, {nil, nil})

    with {:request, req} <- Protocol.decode(data),
         true <- is_binary(consumer),
         :ok <- authorize(state, consumer, req.model) do
      dispatch(state, session, consumer, req)
      {:noreply, %{state | in_flight: state.in_flight + 1}}
    else
      {:error, reason} when is_binary(consumer) ->
        # we have a request that failed authorization
        reject(session, data, reason)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # A served job finished (reported by its task). `ok?` distinguishes a real
  # answer from a failed generation (for the error-rate health metric).
  def handle_info({:job_done, consumer, model, out_tokens, tps, ok?}, state) do
    usage = %{
      state.usage
      | out: state.usage.out + out_tokens,
        requests: state.usage.requests + 1,
        per_consumer: Map.update(state.usage.per_consumer, consumer, out_tokens, &(&1 + out_tokens))
    }

    new_tps = if is_number(tps) and tps > 0, do: state.tps * 0.7 + tps * 0.3, else: state.tps
    served = if ok?, do: state.jobs_served + 1, else: state.jobs_served

    state = %{
      state
      | in_flight: max(0, state.in_flight - 1),
        jobs_served: served,
        serve_ok: state.serve_ok + if(ok?, do: 1, else: 0),
        serve_err: state.serve_err + if(ok?, do: 0, else: 1),
        usage: usage,
        tps: new_tps
    }

    {:noreply, maybe_pause(state, model, tps, ok?)}
  end

  # After the cooldown, re-advertise — unless a later slow job extended the pause,
  # in which case that job's own timer will resume us.
  def handle_info(:resume_sharing, state) do
    if now_ms() >= state.paused_until do
      plog("resumed sharing")
      {:noreply, reconcile(%{state | paused_until: 0})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, session, _reason}, state) do
    case Map.pop(state.downstreams, session) do
      {{consumer, _ref}, downstreams} ->
        {:noreply, %{state | sessions: Map.delete(state.sessions, consumer), downstreams: downstreams}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- authorization (budget / fairness / concurrency) ---

  defp authorize(state, consumer, model) do
    budget = daily_budget(state)
    per_consumer = round(state.settings.per_consumer_pct / 100 * budget)
    used_by = Map.get(state.usage.per_consumer, consumer, 0)

    cond do
      not MapSet.member?(enabled_set(state), model) -> {:error, :model_not_shared}
      state.in_flight >= state.settings.max_concurrency -> {:error, :busy}
      state.usage.out >= budget -> {:error, :daily_budget_reached}
      used_by >= per_consumer -> {:error, :consumer_limit_reached}
      true -> :ok
    end
  end

  # --- serving (async task; keeps the GenServer responsive) ---

  defp dispatch(state, session, consumer, req) do
    parent = self()
    %{identity: identity, engine: engine, settings: settings, coordinator: coord} = state
    weight = model_weight(state, req.model)

    # Provider-side guardrail: always prepend our system prompt (can't be bypassed
    # by the consumer); keep any consumer-supplied system prompt after it.
    sys = Guardrail.system_prompt(req.options["format"])

    opts =
      req.options
      |> cap_tokens(settings.max_out_per_req)
      |> Protocol.engine_opts()
      |> Keyword.update(:system, sys, fn user_sys -> sys <> "\n\n---\n\n" <> user_sys end)

    est_cc = estimate_cc(req, settings, weight)

    Task.start(fn ->
      t0 = System.monotonic_time(:millisecond)
      cons = String.slice(consumer, 0, 12)
      plog("serve job=#{req.id} model=#{req.model} consumer=#{cons}")

      try do
        cond do
        not reserve_ok?(coord, consumer, req.id, est_cc) ->
          # Escrow: reserve the estimated cost before spending compute. If the
          # consumer can't afford it, don't serve. The hold clears at submit_receipt
          # (settlement) or via the coordinator's reaper if the job never completes.
          Logger.info("[provider] refused #{req.model} (#{cons}…): insufficient_funds")
          plog("refused job=#{req.id} model=#{req.model} consumer=#{cons} reason=insufficient_funds")
          Session.send_data(session, Protocol.encode_response(req.id, {:error, :insufficient_funds}))
          send(parent, {:job_done, consumer, req.model, 0, nil, false})

        true ->
          case Engine.generate(engine, req.model, req.prompt, opts) do
            {:ok, result} ->
              receipt = build_receipt(identity, consumer, req, result, weight)
              sig = Receipt.sign(identity, receipt)

              Session.send_data(
                session,
                Protocol.encode_response(req.id, {:ok, result}, %{"receipt" => receipt, "provider_sig" => sig})
              )

              plog(
                "done job=#{req.id} model=#{req.model} consumer=#{cons} " <>
                  "in=#{result.in_tokens} out=#{result.out_tokens} " <>
                  "reasoning=#{result.reasoning_tokens || 0} cc=#{receipt["cc"]} " <>
                  "dur=#{System.monotonic_time(:millisecond) - t0}ms"
              )

              send(parent, {:job_done, consumer, req.model, result.out_tokens, result.tokens_per_sec, true})

            {:error, reason} = err ->
              plog("error job=#{req.id} model=#{req.model} consumer=#{cons} reason=#{inspect(reason)} dur=#{System.monotonic_time(:millisecond) - t0}ms")
              Session.send_data(session, Protocol.encode_response(req.id, err))
              send(parent, {:job_done, consumer, req.model, 0, nil, false})
          end
        end
      rescue
        e ->
          plog("crashed job=#{req.id} model=#{req.model} consumer=#{cons} error=#{Exception.message(e)} dur=#{System.monotonic_time(:millisecond) - t0}ms")
          Session.send_data(session, Protocol.encode_response(req.id, {:error, :provider_crashed}))
          send(parent, {:job_done, consumer, req.model, 0, nil, false})
      catch
        kind, reason ->
          plog("crashed job=#{req.id} model=#{req.model} consumer=#{cons} #{kind}=#{inspect(reason)} dur=#{System.monotonic_time(:millisecond) - t0}ms")
          send(parent, {:job_done, consumer, req.model, 0, nil, false})
      end
    end)
  end

  defp reject(session, data, reason) do
    case Protocol.decode(data) do
      {:request, req} ->
        Logger.info("[provider] rejected #{req.model}: #{reason}")
        plog("rejected job=#{req.id} model=#{req.model} reason=#{reason}")
        Session.send_data(session, Protocol.encode_response(req.id, {:error, reason}))

      _ ->
        :ok
    end
  end

  defp build_receipt(identity, consumer, req, result, weight) do
    %{
      "job_id" => req.id,
      "consumer_id" => consumer,
      "provider_id" => identity.peer_id,
      "model" => req.model,
      "in_tokens" => result.in_tokens,
      "out_tokens" => result.out_tokens,
      "model_weight" => weight,
      "cc" => billable_cc(result, weight)
    }
  end

  # Reasoning tokens count toward `out_tokens` but are the model's internal
  # "thinking", not the answer — so bill them at the input rate (×a), not the
  # premium output rate (×b). The consumer pays for the answer, not the monologue.
  defp billable_cc(result, weight) do
    reasoning = result.reasoning_tokens || 0
    answer_out = max(result.out_tokens - reasoning, 0)
    Credits.cost(result.in_tokens + reasoning, answer_out, weight)
  end

  # Append one line to the provider activity log (~/.lapsus/provider.log) so a
  # served/refused/failed job leaves a trace to diagnose later. Best-effort.
  defp plog(msg) do
    path = provider_log_path()
    File.mkdir_p(Path.dirname(path))
    File.write(path, "#{DateTime.utc_now() |> DateTime.to_iso8601()} #{msg}\n", [:append])
  rescue
    _ -> :ok
  end

  defp provider_log_path do
    case System.get_env("LAPSUS_IDENTITY") do
      p when is_binary(p) and p != "" -> Path.join(Path.dirname(p), "provider.log")
      _ -> Path.join([System.user_home!() || ".", ".lapsus", "provider.log"])
    end
  end

  # --- helpers ---

  defp daily_budget(state),
    do: round(state.settings.contribution_pct / 100 * state.tps * state.settings.anchor_hours * 3600)

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp paused?(state), do: now_ms() < state.paused_until

  # Learn the model's unloaded-throughput peak; if this job ran far below it, the
  # owner is likely using the machine → pause sharing (withdraw) for the cooldown.
  defp maybe_pause(state, _model, _tps, false), do: state

  defp maybe_pause(state, model, tps, true) do
    {baseline_tps, pause?} = update_baseline(state.baseline_tps, model, tps, state.settings)
    state = %{state | baseline_tps: baseline_tps}

    if pause? do
      ms = state.settings.busy_cooldown_s * 1000
      Process.send_after(self(), :resume_sharing, ms)
      {peak, _} = Map.get(baseline_tps, model)

      plog(
        "paused: #{model} ran #{Float.round(tps, 1)} tok/s vs baseline #{Float.round(peak, 1)} " <>
          "→ machine busy, pausing sharing #{state.settings.busy_cooldown_s}s"
      )

      reconcile(%{state | paused_until: now_ms() + ms})
    else
      state
    end
  end

  @doc """
  Pure throughput-baseline step: fold a job's `tps` into the per-model baseline
  `{peak, samples}` map and decide whether it signals owner-load (pause). Public +
  `@doc false` for tests. Returns `{updated_baseline_map, pause?}`.
  """
  def update_baseline(baseline_tps, model, tps, settings) when is_number(tps) and tps > 0 do
    {peak, n} = Map.get(baseline_tps, model, {tps, 0})
    new_peak = max(peak * @baseline_decay, tps)
    n2 = n + 1
    pause? = settings.pause_when_busy and n2 >= @min_samples and tps < new_peak * @busy_ratio
    {Map.put(baseline_tps, model, {new_peak, n2}), pause?}
  end

  def update_baseline(baseline_tps, _model, _tps, _settings), do: {baseline_tps, false}

  defp roll_day(state) do
    today = Date.utc_today()
    if state.usage.date == today, do: state, else: %{state | usage: %{date: today, out: 0, requests: 0, per_consumer: %{}}}
  end

  defp cap_tokens(options, cap) when is_map(options) do
    requested = options["max_tokens"] || cap
    Map.put(options, "max_tokens", min(requested, cap))
  end

  # Estimated cost of a request *before* serving: reserve the capped output and
  # estimate input from the prompt (~4 chars/token). Deliberately generous — we'd
  # rather over-reserve in the pre-check than serve a consumer who can't pay.
  defp estimate_cc(req, settings, weight) do
    in_est = div(String.length(req.prompt), 4)
    out_res = min(req.options["max_tokens"] || settings.max_out_per_req, settings.max_out_per_req)
    Credits.cost(in_est, out_res, weight)
  end

  # Escrow-reserve the estimated cost before serving. Fail-open on a coordinator
  # hiccup: settlement at submit_receipt stays the backstop, so we don't punish
  # paying consumers for a transient signaling error.
  defp reserve_ok?(coord, consumer, request_id, est_cc) do
    case Coordinator.reserve(coord, consumer, request_id, est_cc) do
      {:ok, %{"ok" => ok}} ->
        ok

      other ->
        Logger.warning("[provider] reserve failed (#{inspect(other)}); serving anyway")
        true
    end
  end

  defp model_weight(state, model), do: Map.get(state.model_weights, model, @default_model_weight)

  # Effective shared set: a model is on if explicitly overridden, else iff loaded.
  # While paused (owner using the machine), we advertise nothing — the coordinator
  # then stops routing to us, so consumers fail over to other providers.
  defp enabled_set(state) do
    if paused?(state) do
      MapSet.new()
    else
      state.models
      |> Enum.filter(&Map.get(state.overrides, &1, MapSet.member?(state.loaded, &1)))
      |> MapSet.new()
    end
  end

  # Re-announce to the coordinator only when the effective set or its capabilities
  # actually changed.
  defp reconcile(state) do
    eff = enabled_set(state)
    eff_list = MapSet.to_list(eff)
    caps_eff = Map.take(state.caps, eff_list)

    cond do
      not state.joined -> state
      state.announced == {eff, caps_eff} -> state
      true ->
        Coordinator.update_models(state.coordinator, eff_list, caps_eff)
        %{state | announced: {eff, caps_eff}}
    end
  end

  # We only do text request→response — exclude embedding/TTS models.
  defp text_model?(name), do: not (name =~ ~r/embed|tts/i)

  defp resolve_engine(opts) do
    pref = opts[:engine] || settings_engine(opts)

    case {pref, opts[:models]} do
      {nil, _} ->
        Engine.detect()

      {:auto, _} ->
        Engine.detect()

      {engine, models} when is_list(models) and models != [] ->
        {:ok, engine, models}

      {engine, _} ->
        # Honour the chosen engine if it's reachable; otherwise fall back to detect.
        case Engine.list_models(engine) do
          {:ok, [_ | _] = models} -> {:ok, engine, models}
          _ -> Engine.detect()
        end
    end
  end

  # Engine preference persisted in Settings ("openai" | "ollama" | "auto").
  defp settings_engine(opts) do
    settings = opts[:settings] || Settings.load()

    case settings.engine do
      "openai" -> :openai
      "ollama" -> :ollama
      _ -> :auto
    end
  end

  defp default_identity_path do
    System.get_env("LAPSUS_IDENTITY") ||
      Path.join([System.user_home!() || ".", ".lapsus", "identity.key"])
  end
end
