defmodule LapsusAgent.UI.OnboardingLive do
  @moduledoc "First-run wizard — shown once, shared by provider and consumer (one app, one identity)."
  use Phoenix.LiveView
  import LapsusAgent.UI.Components

  alias LapsusAgent.{ProviderControl, Settings}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, peer_id: peer_id())}
  end

  @impl true
  def handle_event("finish", _params, socket) do
    Settings.mark_onboarded()
    {:noreply, push_navigate(socket, to: "/")}
  end

  defp peer_id do
    case ProviderControl.status() do
      %{running: true, peer_id: id} -> id
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="hero" style="padding:3rem 0 1.5rem">
      <div style="text-align:center;margin-bottom:1rem"><.logo size={88} /></div>
      <div class="eyebrow">Join the commons</div>
      <h1 style="font-size:clamp(1.8rem,4vw,2.6rem)">Welcome to LAPSUS</h1>
      <p class="lede">Community-powered local AI p2p network</p>
    </div>

    <div style="max-width:640px;margin:0 auto">
      <div class="card sec">
        <h3>A few things to know</h3>
        <div class="body">
          <ul class="clean">
            <li><strong>You get a key, not an account.</strong> An identity was just created on this machine — no email, no signup.</li>
            <li><strong>Give to get.</strong> Serve AI tokens to earn credits; spend them to send AI requests to the network.</li>
            <li><strong>No central servers.</strong> The coordinator only introduces peers — after that, data flows directly peer to peer.</li>
            <li><strong>A community network.</strong> A commons, not a marketplace.</li>
            <li><strong>App off = out.</strong> Close it and you instantly leave the network.</li>
          </ul>
          <p :if={@peer_id} class="muted" style="font-size:.82rem;margin-top:.6rem">
            Your peer ID: <code>{String.slice(@peer_id, 0, 28)}…</code>
          </p>
        </div>
      </div>

      <div style="margin-top:1.5rem;text-align:center">
        <button class="btn btn-primary" phx-click="finish">Get started →</button>
        <div class="muted" style="font-size:.9rem;margin-top:.7rem">You can share, ask, or both — from one app.</div>
      </div>
    </div>

    <.footer />
    """
  end
end
