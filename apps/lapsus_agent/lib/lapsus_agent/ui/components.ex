defmodule LapsusAgent.UI.Components do
  @moduledoc """
  Shared UI building blocks — defined **once**, included everywhere.

  Change the logo or footer here and every page (landing, provider, consumer)
  updates. Handy for campaigns / events / rebrands.
  """
  use Phoenix.Component

  @doc "The single source of truth for the logo image path."
  def logo_src, do: "/static/lapsus.png"

  @doc """
  Set the thousands separator for `num/1` for the rest of this render (call once
  at the top of a LiveView `render/1`). Render runs in the LiveView process, so a
  process-local value keeps the many `num/1` call sites argument-free.
  """
  def put_separator(sep) when sep in [".", ","], do: Process.put(:lapsus_num_sep, sep)

  @doc ~S'Format an integer with thousands separators, e.g. 118394 → "118,394" (or "118.394").'
  def num(n) when is_integer(n) and n < 0, do: "-" <> num(-n)

  def num(n) when is_integer(n) do
    sep = Process.get(:lapsus_num_sep, ",")

    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(sep, &Enum.join/1)
    |> String.reverse()
  end

  def num(n), do: to_string(n)

  attr :size, :integer, default: 26

  @doc "The LAPSUS logo image."
  def logo(assigns) do
    ~H"""
    <img src={logo_src()} alt="LAPSUS" style={"height:#{@size}px;width:#{@size}px"} />
    """
  end

  @doc "Brand (logo + wordmark) linking home — used in every nav."
  def brand(assigns) do
    ~H"""
    <a href="/" class="brand"><.logo size={40} /> LAPSUS</a>
    """
  end

  @doc """
  Nav button that quits the whole app (stops the BEAM). The hosting LiveView must
  handle the `"quit"` event (set `quitting: true`, schedule `:shutdown`) and the
  `:shutdown` info (call `System.stop/1`) — see `shutdown_notice/1`.
  """
  def quit_button(assigns) do
    ~H"""
    <button type="button" phx-click="quit"
            data-confirm="Quit LAPSUS? You'll go offline and the app will close."
            class="lnk" title="Quit LAPSUS" aria-label="Quit LAPSUS"
            style="background:none;border:0;cursor:pointer;font:inherit;color:var(--muted)"
            onmouseover="this.style.color='#c0392b'" onmouseout="this.style.color='var(--muted)'">⏻ Quit</button>
    """
  end

  attr :active, :atom, default: :home
  attr :peer_id, :string, default: nil
  attr :sharing, :boolean, default: false
  slot :inner_block, required: true

  @doc """
  The local app's management shell — a top app bar (brand + "running locally" + a
  global Sharing kill-switch + short peer id + Quit) and a left rail (Dashboard /
  Share AI / Use AI + the network), wrapping the page content. Makes the local
  console clearly distinct from the public homepage. The hosting LiveView must
  handle `"quit"`, `:shutdown` and `"toggle_sharing"`.
  """
  def app_shell(assigns) do
    ~H"""
    <div class="appbar">
      <a href="/" class="brand"><.logo size={28} /> LAPSUS</a>
      <span class="live"><span class="d"></span> Running locally</span>
      <span style="flex:1"></span>
      <span class="killswitch">
        Sharing
        <button class={"sw #{if @sharing, do: "on"}"} phx-click="toggle_sharing" aria-label="toggle sharing">
          <span class="knob"></span>
        </button>
      </span>
      <span :if={@peer_id} class="pid" title={@peer_id}>{short_id(@peer_id)}</span>
      <.quit_button />
    </div>

    <div class="shell">
      <nav class="rail">
        <a href="/" class={if @active == :home, do: "on"}>⌂ &nbsp; Dashboard</a>
        <a href="/provider" class={if @active == :share, do: "on"}>↑ &nbsp; Share AI</a>
        <a href="/ask" class={if @active == :use, do: "on"}>↓ &nbsp; Use AI</a>
        <div class="grp">Network</div>
        <a href="https://lapsus.pyrates.io" target="_blank" rel="noopener">◉ &nbsp; lapsus.pyrates.io</a>
        <div class="railftr">
          <div class="rf-brand">LAPSUS</div>
          <div class="rf-ver">{LapsusAgent.Version.current()}</div>
        </div>
      </nav>

      <main class="main">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  @doc "Shorten a peer id for compact display, keeping head + tail."
  def short_id(id) when is_binary(id) and byte_size(id) > 22,
    do: String.slice(id, 0, 12) <> "…" <> String.slice(id, -7, 7)

  def short_id(id), do: id

  @doc "The \"shutting down\" screen shown after Quit while the BEAM stops."
  def shutdown_notice(assigns) do
    ~H"""
    <nav class="nav"><.brand /></nav>
    <div class="card" style="text-align:center;max-width:34rem;margin:6rem auto;border-color:var(--fg)">
      <h3 style="margin-bottom:.4rem">LAPSUS is shutting down…</h3>
      <p class="muted" style="margin:0">You're now offline. You can close this tab.</p>
    </div>
    """
  end

  @doc """
  Architecture diagram: a thin coordinator that only introduces peers, with the
  actual prompt/answer flowing directly between two peers (P2P).
  """
  def p2p_diagram(assigns) do
    ~H"""
    <svg class="diagram" viewBox="0 0 640 262" role="img" aria-label="LAPSUS peer-to-peer architecture">
      <rect x="200" y="16" width="240" height="56" rx="12" fill="var(--soft)" stroke="var(--line)" />
      <text x="320" y="40" text-anchor="middle" font-size="14" font-weight="600" fill="var(--fg)">Coordinator</text>
      <text x="320" y="58" text-anchor="middle" font-size="11" fill="var(--muted)">introduces peers · keeps credits</text>

      <line x1="260" y1="72" x2="135" y2="184" stroke="var(--muted)" stroke-width="1.4" stroke-dasharray="4 4" opacity=".55" />
      <line x1="380" y1="72" x2="505" y2="184" stroke="var(--muted)" stroke-width="1.4" stroke-dasharray="4 4" opacity=".55" />
      <text x="170" y="125" font-size="10" fill="var(--muted)" transform="rotate(-41 170 125)">signaling</text>
      <text x="470" y="125" font-size="10" fill="var(--muted)" transform="rotate(41 470 125)">signaling</text>

      <rect x="30" y="184" width="200" height="72" rx="12" fill="#fff" stroke="var(--fg)" stroke-width="1.5" />
      <text x="130" y="214" text-anchor="middle" font-size="14" font-weight="600" fill="var(--fg)">You</text>
      <text x="130" y="234" text-anchor="middle" font-size="11" fill="var(--muted)">your local model</text>

      <rect x="410" y="184" width="200" height="72" rx="12" fill="#fff" stroke="var(--fg)" stroke-width="1.5" />
      <text x="510" y="214" text-anchor="middle" font-size="14" font-weight="600" fill="var(--fg)">A peer</text>
      <text x="510" y="234" text-anchor="middle" font-size="11" fill="var(--muted)">their local model</text>

      <line x1="236" y1="220" x2="404" y2="220" stroke="var(--fg)" stroke-width="2.5" />
      <polyline points="245,213 236,220 245,227" fill="none" stroke="var(--fg)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" />
      <polyline points="395,213 404,220 395,227" fill="none" stroke="var(--fg)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" />
      <text x="320" y="206" text-anchor="middle" font-size="12" font-weight="600" fill="var(--fg)">prompt ⇄ answer</text>
    </svg>
    """
  end

  attr :kind, :string, required: true

  @doc "Monochrome security glyph (lock / shield / gauge)."
  def sec_icon(%{kind: "lock"} = assigns) do
    ~H"""
    <svg class="secicon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
      <rect x="5" y="11" width="14" height="9" rx="2" />
      <path d="M8 11V8a4 4 0 0 1 8 0v3" />
    </svg>
    """
  end

  def sec_icon(%{kind: "shield"} = assigns) do
    ~H"""
    <svg class="secicon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 3l7 3v5c0 4.4-3 7.6-7 9-4-1.4-7-4.6-7-9V6z" />
      <path d="M9.2 12l2 2 3.6-4" />
    </svg>
    """
  end

  def sec_icon(%{kind: "gauge"} = assigns) do
    ~H"""
    <svg class="secicon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
      <path d="M4 15a8 8 0 0 1 16 0" />
      <path d="M4 15h2M18 15h2M12 5V4" />
      <path d="M12 15l4-3" />
    </svg>
    """
  end

  @doc "Shared footer — used on every page."
  def footer(assigns) do
    ~H"""
    <footer class="footer">
      <span>LAPSUS — early prototype</span>
      <span class="spacer" style="flex:1"></span>
      <a href="/provider">Share AI</a>
      <a href="/ask">Use AI</a>
      <a href="https://github.com/pythononwheels/lapsus-app/blob/main/LICENSE" target="_blank" rel="noopener">AGPL-3.0</a>
      <span class="muted">Be kind to the people lending you their GPUs.</span>
    </footer>
    """
  end
end
