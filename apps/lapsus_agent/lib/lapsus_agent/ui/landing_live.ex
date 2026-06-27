defmodule LapsusAgent.UI.LandingLive do
  @moduledoc "Home / front door. First run → onboarding; otherwise the Share/Ask hub."
  use Phoenix.LiveView
  import LapsusAgent.UI.Components

  alias LapsusAgent.Settings

  @impl true
  def mount(_params, _session, socket) do
    if Settings.onboarded?() do
      {:ok, assign(socket, demo: "app")}
    else
      {:ok, redirect(socket, to: "/welcome")}
    end
  end

  @impl true
  def handle_event("demo", %{"demo" => d}, socket) when d in ["app", "cli"],
    do: {:noreply, assign(socket, demo: d)}

  @impl true
  def render(assigns) do
    ~H"""
    <nav class="nav">
      <.brand />
      <a href="/how" class="lnk">How it works</a>
      <span class="spacer"></span>
      <a href="/ask" class="btn btn-secondary">Use AI</a>
      <a href="/provider" class="btn btn-primary">Share AI</a>
    </nav>

    <section class="hero">
      <div style="text-align:center;margin-bottom:1.2rem"><.logo size={96} /></div>
      <div class="eyebrow">Community-powered local AI p2p network</div>
      <h1 class="motto">Let's run AI.<br />On our own machines.<br />Not Big Tech's cloud.</h1>
      <p class="lede">Let's build our own decentralized AI p2p network.</p>
      <div class="cta">
        <a href="/provider" class="btn btn-primary">Share your AI →</a>
        <a href="/ask" class="btn btn-secondary">Use the network →</a>
      </div>
      <p style="margin-top:1rem"><a href="/how" class="lnk">How it works →</a></p>
    </section>

    <div class="intro-lede">
      <p>
        Share your idle GPU and offer tokens to the network; use the community's when you need
        more — prompts go straight, peer to peer. Hard rate limits are built in, so you can offer
        a text model and tap someone else's image model. Every share earns credits; using the
        network spends them. <strong>Offer some, get some.</strong>
      </p>
    </div>

    <div class="howhead" id="how">
      <span class="eyebrow" style="margin:0">See it in action</span>
      <div class="pills">
        <button class={"pill #{if @demo == "app", do: "on"}"} phx-click="demo" phx-value-demo="app">App</button>
        <button class={"pill #{if @demo == "cli", do: "on"}"} phx-click="demo" phx-value-demo="cli">CLI</button>
      </div>
    </div>

    <section class="section">
      <div>
        <h2>Share your AI</h2>
        <p>
          Already running Ollama or LM Studio? Open the app and your idle GPU joins the commons.
          You set what to share; close the app and you're instantly out.
        </p>
        <p class="muted">Earn credits for every request you serve.</p>
      </div>
      <div :if={@demo == "app"} class="term shotframe">
        <div class="bar"><i style="background:#d7dade"></i><i style="background:#d7dade"></i><i style="background:#d7dade"></i></div>
        <img src="/static/shot-share.png" class="shot" alt="LAPSUS — Share AI screen" />
      </div>
      <div :if={@demo == "cli"} class="term">
        <div class="bar"><i style="background:#d7dade"></i><i style="background:#d7dade"></i><i style="background:#d7dade"></i></div>
        <div class="body"><span class="you">$ lapsus</span>
    <span class="dim">[provider]</span> engine=lmstudio · sharing gemma-4-e2b
    <span class="dim">[provider]</span> online — ready to serve
    <span class="ok">✓ served gemma-4-e2b · +1177 CC</span></div>
      </div>
    </section>

    <section class="section">
      <div :if={@demo == "app"} class="term shotframe">
        <div class="bar"><i style="background:#d7dade"></i><i style="background:#d7dade"></i><i style="background:#d7dade"></i></div>
        <img src="/static/shot-use.png" class="shot" alt="LAPSUS — Use AI screen" />
      </div>
      <div :if={@demo == "cli"} class="term">
        <div class="bar"><i style="background:#d7dade"></i><i style="background:#d7dade"></i><i style="background:#d7dade"></i></div>
        <div class="body"><span class="you">$ lapsus ask gemma "what is p2p?"</span>
    <span class="dim">asking the network…</span>
    Peer-to-peer is a decentralized network where
    machines share resources directly, no central server.
    <span class="dim">― 29 in / 287 out · 1177 CC</span></div>
      </div>
      <div>
        <h2>Use the network</h2>
        <p>
          Pick a community model, send a prompt, and get the answer back from someone else's machine
          over a direct encrypted channel. Spend the credits you earned by sharing.
        </p>
        <p class="muted">Markdown or JSON output, attach a file, ⌘/Ctrl+Enter to send.</p>
        <p style="margin-top:.6rem"><strong>Remember: offer some then get some.</strong></p>
      </div>
    </section>

    <.footer />
    """
  end
end
