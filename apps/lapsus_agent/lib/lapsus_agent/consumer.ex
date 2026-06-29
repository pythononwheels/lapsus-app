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

  @default_timeout 60_000

  @doc """
  Ask `model` the `prompt`. Returns `{:ok, result_map}` or `{:error, reason}`.

  `result_map`: `%{response, in_tokens, out_tokens, reasoning_tokens, billed,
  cc, balance}` (cc/balance present when billed).

  ## Options
    * `:url` — coordinator (default `ws://localhost:4000`)
    * `:max_tokens`, `:temperature`
    * `:identity` / `:identity_path`
    * `:timeout` (ms, default 60s)
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
        :ok -> discover_and_ask(coord, identity, model, prompt, req_opts(opts), timeout, min_ctx)
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

  defp discover_and_ask(coord, identity, model, prompt, req_opts, timeout, min_ctx) do
    case Coordinator.list_providers(coord, model, min_ctx) do
      {:ok, [%{"peer_id" => provider} | _]} ->
        {:ok, session} =
          Session.start_link(
            role: :offerer,
            coordinator: coord,
            remote_peer_id: provider,
            handler: self()
          )

        job_id = "job-" <> Integer.to_string(System.unique_integer([:positive]))
        frame = Protocol.encode_request(job_id, model, prompt, req_opts)
        result = drive(coord, session, identity, frame, timeout)
        safe_stop(session)
        result

      {:ok, []} ->
        {:error, :no_provider}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp drive(coord, session, identity, req_frame, timeout) do
    receive do
      {:lapsus_signal, payload} ->
        Session.signal(session, payload)
        drive(coord, session, identity, req_frame, timeout)

      {:peer_open, ^session} ->
        Session.send_data(session, req_frame)
        drive(coord, session, identity, req_frame, timeout)

      {:peer_data, ^session, data} ->
        case Protocol.decode(data) do
          {:response, resp} -> finalize(coord, identity, resp)
          _ -> drive(coord, session, identity, req_frame, timeout)
        end
    after
      timeout -> {:error, :timeout}
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
