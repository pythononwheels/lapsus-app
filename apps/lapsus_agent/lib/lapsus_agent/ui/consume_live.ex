defmodule LapsusAgent.UI.ConsumeLive do
  @moduledoc "Consumer app: pick a community model from a searchable dropdown, ask it."
  use Phoenix.LiveView
  import LapsusAgent.UI.Components

  alias LapsusAgent.{Consumer, Settings}
  alias LapsusAgent.UI.Charts

  @usage_days 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :load_models)
      send(self(), :load_usage)
    end

    {:ok,
     socket
     |> assign(
       tab: :ask,
       settings: Settings.load(),
       models: [],
       loading_models: connected?(socket),
       open: false,
       filter: "",
       prompt: "",
       selected: nil,
       format: "markdown",
       result_format: "markdown",
       est_in: 0,
       status: :idle,
       result: nil,
       error: nil,
       usage: nil,
       loading_usage: connected?(socket),
       quitting: false,
       peer_id: Consumer.peer_id()
     )
     |> allow_upload(:doc, accept: :any, max_entries: 1, max_file_size: 4_000_000)}
  end

  @impl true
  def handle_info(:shutdown, socket) do
    System.stop(0)
    {:noreply, socket}
  end

  def handle_info(:load_models, socket) do
    parent = self()
    Task.start(fn -> send(parent, {:models, Consumer.network_models()}) end)
    {:noreply, socket}
  end

  def handle_info(:load_usage, socket) do
    parent = self()
    Task.start(fn -> send(parent, {:usage, Consumer.usage(@usage_days)}) end)
    {:noreply, assign(socket, loading_usage: true)}
  end

  def handle_info({:usage, {:ok, usage}}, socket),
    do: {:noreply, assign(socket, usage: usage, loading_usage: false)}

  def handle_info({:usage, _error}, socket),
    do: {:noreply, assign(socket, loading_usage: false)}

  def handle_info({:models, {:ok, models}}, socket) do
    selected = socket.assigns.selected || (List.first(models) || %{})["model"]
    {:noreply, assign(socket, models: models, loading_models: false, selected: selected)}
  end

  def handle_info({:models, _error}, socket) do
    {:noreply, assign(socket, models: [], loading_models: false)}
  end

  def handle_info({:ask_result, {:ok, res}}, socket) do
    # a fresh billed request → refresh the activity mini-dash
    if res[:billed], do: send(self(), :load_usage)
    {:noreply, assign(socket, status: :idle, result: res, error: nil)}
  end

  def handle_info({:ask_result, {:error, reason}}, socket) do
    {:noreply, assign(socket, status: :idle, error: format_error(reason))}
  end

  @impl true
  def handle_event("tab", %{"tab" => "activity"}, socket) do
    if socket.assigns.usage == nil and not socket.assigns.loading_usage, do: send(self(), :load_usage)
    {:noreply, assign(socket, tab: :activity)}
  end

  def handle_event("tab", _params, socket), do: {:noreply, assign(socket, tab: :ask)}

  def handle_event("quit", _params, socket) do
    Process.send_after(self(), :shutdown, 500)
    {:noreply, assign(socket, quitting: true)}
  end

  def handle_event("refresh_usage", _params, socket) do
    send(self(), :load_usage)
    {:noreply, socket}
  end

  def handle_event("toggle_dropdown", _params, socket), do: {:noreply, assign(socket, open: !socket.assigns.open)}
  def handle_event("close_dropdown", _params, socket), do: {:noreply, assign(socket, open: false)}
  def handle_event("filter", %{"q" => q}, socket), do: {:noreply, assign(socket, filter: q)}

  def handle_event("pick", %{"model" => model}, socket) do
    {:noreply, assign(socket, selected: model, open: false, filter: "")}
  end

  def handle_event("set_format", %{"format" => f}, socket) when f in ["markdown", "json"],
    do: {:noreply, assign(socket, format: f)}

  def handle_event("refresh", _params, socket) do
    send(self(), :load_models)
    {:noreply, assign(socket, loading_models: true)}
  end

  # Form change: live input-token estimate (prompt + any attached file).
  def handle_event("validate", %{"prompt" => prompt}, socket) do
    upload_chars = Enum.reduce(socket.assigns.uploads.doc.entries, 0, &(&1.client_size + &2))
    est_in = estimate_tokens(String.length(prompt) + upload_chars)
    {:noreply, assign(socket, prompt: prompt, est_in: est_in)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :doc, ref)}

  def handle_event("ask", %{"prompt" => prompt}, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      model ->
        # Read any attached text file and prepend it as context.
        file =
          consume_uploaded_entries(socket, :doc, fn %{path: path}, entry ->
            {:ok, {entry.client_name, File.read!(path)}}
          end)

        full_prompt =
          case file do
            [{name, content}] -> "Attached file (#{name}):\n\n#{content}\n\n---\n\n#{prompt}"
            _ -> prompt
          end

        fmt = socket.assigns.format
        parent = self()
        Task.start(fn -> send(parent, {:ask_result, Consumer.ask(model, full_prompt, max_tokens: 1024, format: fmt)}) end)
        {:noreply, assign(socket, status: :asking, result: nil, error: nil, prompt: prompt, est_in: 0, result_format: fmt)}
    end
  end

  # ~4 chars per token (rough heuristic; good enough for a pre-send estimate).
  defp estimate_tokens(chars), do: max(0, div(chars, 4))

  defp upload_error(:too_large), do: "File is too large (max 4 MB)."
  defp upload_error(:not_accepted), do: "That file type isn't supported."
  defp upload_error(:too_many_files), do: "Only one file at a time."
  defp upload_error(other), do: to_string(other)

  defp filtered(models, ""), do: models

  defp filtered(models, q) do
    q = String.downcase(q)
    Enum.filter(models, &String.contains?(String.downcase(&1["model"]), q))
  end

  defp format_error(:no_provider), do: "No provider online for that model right now."

  defp format_error({:provider_error, reason}) when is_binary(reason) do
    if reason =~ "insufficient_funds" do
      "Not enough Compute-Credits for this request. Share your AI to earn some — offer some, get some."
    else
      "The provider couldn't serve this: #{reason}"
    end
  end

  defp format_error(other), do: inspect(other)

  @impl true
  def render(%{quitting: true} = assigns) do
    ~H"""
    <.shutdown_notice />
    """
  end

  def render(assigns) do
    put_separator(Settings.separator(assigns.settings))

    assigns =
      assigns
      |> assign(:ctx_warn, ctx_warning(assigns.est_in, assigns.selected, assigns.models))
      |> assign(:locale, Settings.chart_locale(assigns.settings))

    ~H"""
    <.app_shell active={:use} peer_id={@peer_id}>
    <div class="tabs">
      <button class={"tab #{if @tab == :ask, do: "on"}"} phx-click="tab" phx-value-tab="ask">Ask</button>
      <button class={"tab #{if @tab == :activity, do: "on"}"} phx-click="tab" phx-value-tab="activity">Activity</button>
    </div>

    <div :if={@tab == :ask} id="ask-pane">
      <div class="card sec">
        <div class="row">
          <h3>Use the network</h3>
          <span style="display:flex;align-items:center;gap:.85rem">
            <span :if={@usage} class="muted" style="font-size:.85rem">Balance <strong>{num(@usage["balance"])} CC</strong></span>
            <button class="gear" phx-click="refresh" title="refresh models">↻</button>
          </span>
        </div>
        <div class="body">
          <label>Model</label>
          <div class="combo" phx-click-away="close_dropdown">
            <button type="button" class="combo-field" phx-click="toggle_dropdown">
              <span :if={@selected}><code>{@selected}</code></span>
              <span :if={!@selected} class="ph">{if @loading_models, do: "Loading models…", else: "Select a model"}</span>
              <span class="combo-caret">▾</span>
            </button>

            <div :if={@open} class="combo-panel">
              <input type="text" name="q" placeholder="Search models…" value={@filter}
                     phx-keyup="filter" phx-debounce="100" autofocus autocomplete="off" />
              <div :if={@models == []} class="muted" style="padding:.4rem .55rem">No models shared right now.</div>
              <div :for={m <- filtered(@models, @filter)} class="combo-opt"
                   phx-click="pick" phx-value-model={m["model"]}>
                <span class="name">
                  {m["model"]}
                  <span :if={m["multimodal"]} class="tag">vision</span>
                </span>
                <span class="muted" style="font-size:.78rem">
                  <span :if={m["ctx"]}>{fmt_ctx(m["ctx"])} ctx · </span>{m["providers"]} {if m["providers"] == 1, do: "provider", else: "providers"}
                </span>
              </div>
            </div>
          </div>

          <form phx-submit="ask" phx-change="validate" style="margin-top:1rem">
            <label>Prompt</label>
            <textarea id="prompt-input" name="prompt" rows="4" placeholder="Your prompt…"
                      phx-hook="SubmitOnCmdEnter" phx-debounce="250">{@prompt}</textarea>

            <div class="uploadrow">
              <label class="filebtn">
                <span>📎 Attach file</span>
                <.live_file_input upload={@uploads.doc} style="display:none" />
              </label>
              <span :for={entry <- @uploads.doc.entries} class="chip">
                {entry.client_name}
                <button type="button" class="x" phx-click="cancel_upload" phx-value-ref={entry.ref} aria-label="remove file">×</button>
              </span>
              <span style="flex:1"></span>
              <span class="muted" style="font-size:.78rem">Format</span>
              <div class="pills">
                <button type="button" class={"pill #{if @format == "markdown", do: "on"}"} phx-click="set_format" phx-value-format="markdown">Markdown</button>
                <button type="button" class={"pill #{if @format == "json", do: "on"}"} phx-click="set_format" phx-value-format="json">JSON</button>
              </div>
              <span class="muted est">≈ {num(@est_in)} in</span>
            </div>
            <div :for={err <- upload_errors(@uploads.doc)} class="uperr">{upload_error(err)}</div>
            <div :if={@ctx_warn} class="uperr">{@ctx_warn}</div>

            <div style="margin-top:.9rem;display:flex;align-items:center;gap:.85rem">
              <button class="btn-go" type="submit" disabled={@status == :asking or is_nil(@selected)}>
                {if @status == :asking, do: "Asking…", else: "Ask"}
              </button>
              <span class="muted" style="font-size:.78rem">⌘ / Ctrl + Enter to send</span>
            </div>
          </form>
        </div>
      </div>

      <div :if={@error} class="card" style="border-color:var(--fg)">{@error}</div>

      <div :if={@result} class="card">
        <div :if={has_text?(@result.response) and @result_format == "json"}>
          <pre class="jsonbox"><code>{pretty_json(@result.response)}</code></pre>
        </div>
        <div :if={has_text?(@result.response) and @result_format != "json"} class="md">{render_md(@result.response)}</div>

        <details :if={!has_text?(@result.response) and has_text?(@result[:reasoning])}>
          <summary class="muted" style="cursor:pointer">
            The model spent its budget reasoning and gave no final answer — show its reasoning
          </summary>
          <p class="muted" style="white-space:pre-wrap;margin-top:.5rem">{@result[:reasoning]}</p>
        </details>

        <p :if={!has_text?(@result.response) and !has_text?(@result[:reasoning])} class="muted">
          (no visible content)
        </p>

        <div class="row" style="border-top:1px solid var(--line);margin-top:.6rem;padding-top:.6rem">
          <span class="muted">{num(@result.in_tokens)} in / {num(@result.out_tokens)} out tokens</span>
          <span>{billing(@result)}</span>
        </div>
      </div>
    </div>

    <div :if={@tab == :activity} class="card sec">
      <div class="row">
        <h3>Your activity <span class="muted">· last 30 days</span></h3>
        <button class="gear" phx-click="refresh_usage" title="refresh">↻</button>
      </div>
      <div class="body">
        <div :if={@loading_usage and !@usage} class="muted" style="font-size:.9rem">Loading…</div>
        <div :if={!@loading_usage and !cusage?(@usage)} class="muted" style="font-size:.9rem">
          You haven't sent any requests in this window yet.
        </div>

        <div :if={cusage?(@usage)}>
          <div class="tiles">
            <div class="tile"><strong>{num(@usage["totals"]["jobs"])}</strong><span class="muted">requests</span></div>
            <div class="tile"><strong>{num(@usage["totals"]["in"])}</strong><span class="muted">in tokens</span></div>
            <div class="tile"><strong>{num(@usage["totals"]["out"])}</strong><span class="muted">out tokens</span></div>
            <div class="tile"><strong>{num(@usage["totals"]["cc"])}</strong><span class="muted">CC spent</span></div>
          </div>

          <div class="usage-grid">
            <section class="panel">
              <h4>Requests over time</h4>
              <div class="chartbox" id="cons-bar" phx-hook="Chart" data-chart={Charts.json(Charts.bar_data(@usage["days"], @locale))}>
                <canvas></canvas>
              </div>
            </section>

            <section :if={@usage["by_model"] != []} class="panel">
              <h4>By model <span class="muted">· out tokens</span></h4>
              <div class="chartbox donut" id="cons-donut" phx-hook="Chart" data-chart={Charts.json(Charts.donut_data(@usage["by_model"], @locale))}>
                <canvas></canvas>
              </div>
            </section>
          </div>
        </div>
      </div>
    </div>

    </.app_shell>
    """
  end

  defp cusage?(u) when is_map(u), do: (u["totals"]["jobs"] || 0) > 0
  defp cusage?(_), do: false

  defp has_text?(s), do: is_binary(s) and String.trim(s) != ""

  # Compact context length, e.g. 131072 -> "128k".
  defp fmt_ctx(n) when is_integer(n) and n >= 1000, do: "#{Float.round(n / 1024, 0) |> trunc()}k"
  defp fmt_ctx(n) when is_integer(n), do: "#{n}"
  defp fmt_ctx(_), do: ""

  defp selected_ctx(models, selected),
    do: Enum.find_value(models, fn m -> if m["model"] == selected, do: m["ctx"] end)

  # Pre-send warning if the estimate (input + reserved output) may exceed the
  # selected model's advertised context window.
  defp ctx_warning(est_in, selected, models) do
    ctx = selected_ctx(models, selected)
    needed = est_in + 1024

    if is_integer(ctx) and needed > ctx do
      "This request (~#{needed} tokens) may exceed #{selected}'s #{fmt_ctx(ctx)} context window — it could be truncated or routed elsewhere."
    end
  end

  # Render a model's markdown answer to sanitized HTML (untrusted output — MDEx
  # strips scripts and neutralizes dangerous links).
  defp render_md(text) do
    case MDEx.to_html(text, sanitize: true) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      _ -> text
    end
  end

  # Pretty-print a JSON answer; fall back to the raw string if it isn't valid JSON.
  defp pretty_json(text) do
    case Jason.decode(text) do
      {:ok, data} -> Jason.encode!(data, pretty: true)
      _ -> text
    end
  end

  defp billing(%{billed: true, cc: cc, balance: balance}), do: "#{num(cc)} CC · balance #{num(balance)}"
  defp billing(%{billed: false}), do: "not billed"
  defp billing(_), do: ""
end
