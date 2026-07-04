defmodule LapsusAgent.Consumer do
  @moduledoc """
  The consumer side: ask the LAPSUS network a prompt and get an answer.

  `ask/3` is the shared core behind both the CLI (`mix lapsus.ask`) and the small
  consumer app. It runs the whole flow synchronously in the calling process:
  discover a provider → open a P2P WebRTC channel → send the request → receive the
  answer → co-sign the provider's receipt and submit it for billing → return.

  Uses the same on-disk identity as the provider (a user is one peer, whether they
  give or take).
  """
  require Logger

  alias LapsusAgent.Coordinator
  alias LapsusAgent.Peer.{Protocol, Session}
  alias LapsusCore.{Identity, Receipt}

  @default_timeout 180_000
  # Per-attempt wall-clock budget for the WebRTC connection to open. A failed
  # connection is only observable as silence, so this caps how long a dead/unreachable
  # provider costs before we fail over. Overridable via `opts[:connect_timeout]`.
  @connect_timeout 20_000

  @doc """
  Ask `model` the `prompt`. Returns `{:ok, result_map}` or `{:error, reason}`.

  `result_map`: `%{response, in_tokens, out_tokens, reasoning_tokens, billed,
  cc, balance}` (cc/balance present when billed).

  ## Options
    * `:url` — coordinator (default `ws://localhost:4000`)
    * `:max_tokens`, `:temperature`
    * `:identity` / `:identity_path`
    * `:timeout` (ms, default 180s)
  """
  @spec ask(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ask(model, prompt, opts \\ []) do
    identity =
      opts[:identity] ||
        Identity.load_or_create!(opts[:identity_path] || default_identity_path())

    timeout = opts[:timeout] || @default_timeout

    {:ok, coord} =
      Coordinator.start_link(
        identity: identity,
        url: opts[:url] || Coordinator.default_url(),
        role: "consumer",
        handler: self()
      )

    # Route to a provider whose context window fits the estimated request size
    # (~4 chars/token input + reserved output + template buffer).
    min_ctx = div(String.length(prompt), 4) + (opts[:max_tokens] || 300) + 256

    result =
      case await_join(timeout) do
        :ok -> discover_and_ask(coord, identity, model, prompt, req_opts(opts), timeout, min_ctx, opts)
        {:error, _} = e -> e
      end

    safe_stop(coord)
    result
  end

  @doc "List all models offered across the network (with provider counts)."
  @spec network_models(keyword()) :: {:ok, [map()]} | {:error, term()}
  def network_models(opts \\ []) do
    identity =
      opts[:identity] ||
        Identity.load_or_create!(opts[:identity_path] || default_identity_path())

    timeout = opts[:timeout] || @default_timeout

    {:ok, coord} =
      Coordinator.start_link(
        identity: identity,
        url: opts[:url] || Coordinator.default_url(),
        role: "consumer",
        handler: self()
      )

    result =
      case await_join(timeout) do
        :ok ->
          case Coordinator.network_models(coord) do
            {:ok, %{"models" => models}} -> {:ok, models}
            other -> other
          end

        e ->
          e
      end

    safe_stop(coord)
    result
  end

  @doc """
  Full network overview — the coordinator's `models` reply as-is:
  `{:ok, %{"models" => [...], "nodes" => <peers online>}}`.
  """
  @spec network(keyword()) :: {:ok, map()} | {:error, term()}
  def network(opts \\ []) do
    identity =
      opts[:identity] ||
        Identity.load_or_create!(opts[:identity_path] || default_identity_path())

    timeout = opts[:timeout] || @default_timeout

    {:ok, coord} =
      Coordinator.start_link(
        identity: identity,
        url: opts[:url] || Coordinator.default_url(),
        role: "consumer",
        handler: self()
      )

    result =
      case await_join(timeout) do
        :ok -> Coordinator.network_models(coord)
        e -> e
      end

    safe_stop(coord)
    result
  end

  @doc "Verified open-source projects that can receive donations (§03)."
  @spec projects(keyword()) :: {:ok, map()} | {:error, term()}
  def projects(opts \\ []) do
    with_coordinator(opts, &Coordinator.list_projects/1)
  end

  @doc "Donate `cc` credits to a registered project. Returns `{:ok, %{balance: …}}`."
  @spec donate(String.t(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def donate(project_id, cc, opts \\ []) do
    with_coordinator(opts, &Coordinator.donate(&1, project_id, cc))
  end

  # Connect to the coordinator, run `fun.(coord)`, then disconnect. Shared by the
  # one-shot channel calls (network, projects, donate).
  defp with_coordinator(opts, fun) do
    identity =
      opts[:identity] ||
        Identity.load_or_create!(opts[:identity_path] || default_identity_path())

    timeout = opts[:timeout] || @default_timeout

    {:ok, coord} =
      Coordinator.start_link(
        identity: identity,
        url: opts[:url] || Coordinator.default_url(),
        role: "consumer",
        handler: self()
      )

    result =
      case await_join(timeout) do
        :ok -> fun.(coord)
        e -> e
      end

    safe_stop(coord)
    result
  end

  @doc "This peer's consumer-side usage (requests sent) over `days`, for the mini-dash."
  @spec usage(pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def usage(days \\ 30, opts \\ []) do
    identity =
      opts[:identity] ||
        Identity.load_or_create!(opts[:identity_path] || default_identity_path())

    timeout = opts[:timeout] || @default_timeout

    {:ok, coord} =
      Coordinator.start_link(
        identity: identity,
        url: opts[:url] || Coordinator.default_url(),
        role: "consumer",
        handler: self()
      )

    result =
      case await_join(timeout) do
        :ok ->
          case Coordinator.usage(coord, days) do
            {:ok, %{"consumer" => consumer} = reply} -> {:ok, Map.put(consumer, "balance", reply["balance"] || 0)}
            other -> other
          end

        e ->
          e
      end

    safe_stop(coord)
    result
  end

  @doc """
  The full usage map for this peer over `days` — both the provider view (jobs
  served) and the consumer view (requests sent) plus the current `balance` —
  fetched directly from the coordinator regardless of whether this peer is
  currently sharing. Powers the always-on Dashboard charts.

  Returns `{:ok, %{"provider" => ..., "consumer" => ..., "balance" => ...}}`.
  """
  @spec full_usage(pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def full_usage(days \\ 7, opts \\ []) do
    identity =
      opts[:identity] ||
        Identity.load_or_create!(opts[:identity_path] || default_identity_path())

    timeout = opts[:timeout] || @default_timeout

    {:ok, coord} =
      Coordinator.start_link(
        identity: identity,
        url: opts[:url] || Coordinator.default_url(),
        role: "consumer",
        handler: self()
      )

    result =
      case await_join(timeout) do
        :ok -> Coordinator.usage(coord, days)
        e -> e
      end

    safe_stop(coord)
    result
  end

  @doc """
  This peer's id — loads (or creates) the on-disk identity, independent of whether
  the provider is currently sharing. For showing the node id in the UI even offline.
  """
  @spec peer_id(keyword()) :: String.t()
  def peer_id(opts \\ []) do
    identity =
      opts[:identity] ||
        Identity.load_or_create!(opts[:identity_path] || default_identity_path())

    identity.peer_id
  end

  # --- internals ---

  # Discover providers for `model` and try them in turn: if one is dead/slow/flapping
  # (a retryable `:timeout`), fail over to the next offering the same model, within an
  # overall `timeout` budget. One `job_id` is minted for the whole logical request and
  # reused across attempts, so the coordinator's per-`request_id`-idempotent `reserve`
  # holds at most one escrow row regardless of how many providers we try.
  defp discover_and_ask(coord, identity, model, prompt, req_opts, timeout, min_ctx, opts) do
    case Coordinator.list_providers(coord, model, min_ctx) do
      {:ok, []} ->
        {:error, :no_provider}

      {:error, reason} ->
        {:error, reason}

      {:ok, providers} ->
        # Globally-unique job id (128 bits of randomness) — shared by every attempt so
        # only one escrow hold exists; the winning receipt clears it (else the reaper).
        job_id = "job-" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
        frame = Protocol.encode_request(job_id, model, prompt, req_opts)
        deadline = now_ms() + timeout
        connect_ms = opts[:connect_timeout] || @connect_timeout
        on_event = opts[:on_event] || fn _event, _meta -> :ok end
        try_fn = fn provider, dl -> try_provider(coord, identity, provider, frame, dl, connect_ms) end

        providers
        |> maybe_shuffle(opts)
        |> failover(deadline, on_event, try_fn)
    end
  end

  # Spread load across providers of the same model (and avoid everyone hammering a
  # flaky providers[0]). Disable via `opts[:shuffle] = false` for deterministic tests.
  defp maybe_shuffle(providers, opts) do
    if Keyword.get(opts, :shuffle, true), do: Enum.shuffle(providers), else: providers
  end

  # Try each provider in turn via `try_fn.(provider_peer_id, deadline)`; return the
  # first `{:ok, _}`, else fail over on a retryable error while budget remains, else the
  # last error. `try_fn` is injected so the failover logic is unit-testable without I/O.
  # Public + `@doc false` for tests only — not part of the intended API.
  @doc false
  def failover([], _deadline, _on_event, _try_fn), do: {:error, :no_provider}

  def failover([p | rest], deadline, on_event, try_fn) do
    provider = p["peer_id"]

    case try_fn.(provider, deadline) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if retryable?(reason) and rest != [] and time_left(deadline) > 0 do
          on_event.(:failover, %{provider: provider, reason: reason})
          failover(rest, deadline, on_event, try_fn)
        else
          err
        end
    end
  end

  # One attempt against a single provider: open a fresh WebRTC session, drive it, and
  # tear it down cleanly (keeping the shared `coord` alive for the next attempt).
  defp try_provider(coord, identity, provider, frame, deadline, connect_ms) do
    {:ok, session} =
      Session.start_link(
        role: :offerer,
        coordinator: coord,
        remote_peer_id: provider,
        handler: self()
      )

    connect_deadline = min(now_ms() + connect_ms, deadline)
    result = drive(coord, session, provider, identity, frame, connect_deadline, deadline, false)
    safe_stop(session)
    drain_session_messages(session)
    result
  end

  # Two-phase wall-clock loop. `deadline` is the connect budget until `{:peer_open}`,
  # then switches to `overall` (the rest of the global budget) for the response. Every
  # non-terminal message shortens the wait toward the true deadline (not a reset).
  defp drive(coord, session, provider, identity, frame, deadline, overall, sent?) do
    receive do
      # Signals are keyed by the sender peer_id: only feed the *current* provider's
      # signals to this session — a late offer/answer/ICE from a previous provider
      # applied here would corrupt this negotiation.
      {:lapsus_signal, %{"from" => ^provider} = payload} ->
        Session.signal(session, payload)
        drive(coord, session, provider, identity, frame, deadline, overall, sent?)

      {:lapsus_signal, _foreign} ->
        drive(coord, session, provider, identity, frame, deadline, overall, sent?)

      {:peer_open, ^session} ->
        unless sent?, do: Session.send_data(session, frame)
        # switch to the response-phase deadline (rest of the overall budget)
        drive(coord, session, provider, identity, frame, overall, overall, true)

      {:peer_open, _stale} ->
        drive(coord, session, provider, identity, frame, deadline, overall, sent?)

      {:peer_data, ^session, data} ->
        case Protocol.decode(data) do
          {:response, resp} -> finalize(coord, identity, resp)
          _ -> drive(coord, session, provider, identity, frame, deadline, overall, sent?)
        end

      {:peer_data, _stale, _} ->
        drive(coord, session, provider, identity, frame, deadline, overall, sent?)
    after
      time_left(deadline) -> {:error, :timeout}
    end
  end

  # Only silence (connect- or response-phase timeout) is retryable — that's the
  # dead/slow/flapping provider. A `{:provider_error, _}` means the provider *answered*
  # (content error / insufficient funds), which won't differ at another provider.
  defp retryable?(:timeout), do: true
  defp retryable?(_), do: false

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp time_left(deadline), do: max(0, deadline - now_ms())

  # Flush any messages that were already queued for a torn-down session so they can't
  # accumulate across a long failover chain (signals are handled by the "from" filter).
  defp drain_session_messages(session) do
    receive do
      {:peer_data, ^session, _} -> drain_session_messages(session)
      {:peer_open, ^session} -> drain_session_messages(session)
    after
      0 -> :ok
    end
  end

  defp finalize(_coord, _identity, %{"ok" => false} = resp),
    do: {:error, {:provider_error, resp["error"]}}

  defp finalize(coord, identity, %{"result" => r} = resp) do
    base = %{
      response: r["response"],
      reasoning: r["reasoning"],
      in_tokens: r["in_tokens"],
      out_tokens: r["out_tokens"],
      reasoning_tokens: r["reasoning_tokens"]
    }

    case resp["receipt"] do
      nil ->
        {:ok, Map.put(base, :billed, false)}

      receipt ->
        consumer_sig = Receipt.sign(identity, receipt)

        case Coordinator.submit_receipt(coord, receipt, resp["provider_sig"], consumer_sig) do
          {:ok, %{"balance" => balance}} ->
            {:ok, Map.merge(base, %{billed: true, cc: receipt["cc"], balance: balance})}

          {:error, reason} ->
            {:ok, Map.merge(base, %{billed: false, cc: receipt["cc"], billing_error: reason})}
        end
    end
  end

  defp await_join(timeout) do
    receive do
      {:lapsus_joined, _topic} -> :ok
    after
      timeout -> {:error, :join_timeout}
    end
  end

  defp req_opts(opts) do
    %{"max_tokens" => opts[:max_tokens] || 300, "temperature" => opts[:temperature] || 0}
    |> maybe_put("format", opts[:format])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
  catch
    :exit, _ -> :ok
  end

  defp default_identity_path do
    base =
      System.get_env("LAPSUS_IDENTITY") ||
        Path.join([System.user_home!() || ".", ".lapsus", "identity.key"])

    # Debug/test only: ask under a separate identity so self-exclusion doesn't hide
    # your own provider — lets ONE running app ask its own models (real P2P, no
    # same-peer signaling cross-talk). Not for normal use.
    if System.get_env("LAPSUS_SELF_ASK") == "1", do: base <> ".self-ask", else: base
  end
end
