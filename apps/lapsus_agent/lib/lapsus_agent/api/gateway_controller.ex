defmodule LapsusAgent.API.GatewayController do
  @moduledoc """
  A local, OpenAI-compatible HTTP gateway (`/v1`) in front of the P2P network. Point any
  OpenAI SDK at `http://localhost:<LAPSUS_UI_PORT>/v1` — the request runs the normal
  consumer flow (discover → P2P → answer) and comes back as an OpenAI-shaped response. The
  prompt still travels peer-to-peer; nothing central sees it. Bound to 127.0.0.1 only (it
  spends your credits). See `doc/tech/protocol.md` §7.
  """
  use Phoenix.Controller
  import Plug.Conn

  alias LapsusAgent.Consumer

  # POST /v1/chat/completions
  def chat_completions(conn, params) do
    model = params["model"] |> to_string() |> String.trim()
    messages = List.wrap(params["messages"])

    cond do
      model == "" ->
        conn |> put_status(400) |> json(error_json("`model` is required"))

      messages == [] ->
        conn |> put_status(400) |> json(error_json("`messages` is required"))

      true ->
        {prompt, system} = flatten_messages(messages)

        # Pass the caller's max_tokens straight through (like real OpenAI). When it's
        # omitted we send nothing — the serving provider's own max_out_per_req is then
        # the only cap; the gateway never imposes an arbitrary limit of its own.
        opts =
          [temperature: num(params["temperature"], 0)]
          |> maybe_put(:system, system)
          |> maybe_put(:max_tokens, int(params["max_tokens"], nil))

        case Consumer.ask(model, prompt, opts) do
          {:ok, res} -> respond(conn, model, res, params["stream"] == true)
          {:error, reason} -> conn |> put_status(status_for(reason)) |> json(error_json(reason_message(reason)))
        end
    end
  end

  # GET /v1/models
  def models(conn, _params) do
    data =
      case Consumer.network() do
        {:ok, %{"models" => models}} when is_list(models) ->
          Enum.map(models, fn m -> %{id: m["model"], object: "model", owned_by: "lapsus"} end)

        _ ->
          []
      end

    json(conn, %{object: "list", data: data})
  end

  # --- response shaping ---

  defp respond(conn, model, res, false), do: json(conn, completion(model, res))

  # `stream: true` — minimal SSE (one delta with the full answer, then [DONE]). Real
  # token-by-token streaming needs a DataChannel protocol addition (doc/tech/protocol.md).
  defp respond(conn, model, res, true) do
    id = "chatcmpl-" <> rand_id()
    created = System.system_time(:second)
    content = answer_text(res)

    delta = %{
      id: id,
      object: "chat.completion.chunk",
      created: created,
      model: model,
      choices: [%{index: 0, delta: %{role: "assistant", content: content}, finish_reason: "stop"}]
    }

    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
    |> sse("data: " <> Jason.encode!(delta) <> "\n\n")
    |> sse("data: [DONE]\n\n")
  end

  defp sse(conn, data) do
    {:ok, conn} = chunk(conn, data)
    conn
  end

  defp completion(model, res) do
    in_t = res[:in_tokens] || 0
    out_t = res[:out_tokens] || 0

    %{
      id: "chatcmpl-" <> rand_id(),
      object: "chat.completion",
      created: System.system_time(:second),
      model: model,
      choices: [
        %{index: 0, message: %{role: "assistant", content: answer_text(res)}, finish_reason: "stop"}
      ],
      usage: %{prompt_tokens: in_t, completion_tokens: out_t, total_tokens: in_t + out_t}
    }
  end

  defp answer_text(res), do: res[:response] || res[:reasoning] || ""

  # --- OpenAI messages → LAPSUS prompt/system ---

  defp flatten_messages(messages) do
    {sys, convo} = Enum.split_with(messages, &(&1["role"] == "system"))
    system = sys |> Enum.map_join("\n", &to_string(&1["content"])) |> nil_if_blank()

    prompt =
      case convo do
        [only] -> to_string(only["content"])
        _ -> Enum.map_join(convo, "\n", fn m -> "#{role_label(m["role"])}: #{m["content"]}" end)
      end

    {prompt, system}
  end

  defp role_label("assistant"), do: "Assistant"
  defp role_label("tool"), do: "Tool"
  defp role_label(_), do: "User"

  # --- errors ---

  defp error_json(msg), do: %{error: %{message: to_string(msg), type: "lapsus_error"}}

  defp status_for(:no_provider), do: 503
  defp status_for(:insufficient_funds), do: 402
  defp status_for(:timeout), do: 504
  defp status_for(_), do: 502

  defp reason_message(:no_provider), do: "no provider online for that model"
  defp reason_message(:insufficient_funds), do: "not enough Compute-Credits — share your AI to earn some"
  defp reason_message(:timeout), do: "the provider didn't answer in time"
  defp reason_message({:provider_error, r}), do: "provider error: #{r}"
  defp reason_message(other), do: "request failed: #{inspect(other)}"

  # --- helpers ---

  defp maybe_put(opts, _k, nil), do: opts
  defp maybe_put(opts, k, v), do: Keyword.put(opts, k, v)

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s

  defp int(v, _default) when is_integer(v) and v > 0, do: v
  defp int(_, default), do: default

  defp num(v, _default) when is_number(v), do: v
  defp num(_, default), do: default

  defp rand_id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
end
