defmodule LapsusAgent.UI.GuardrailLive do
  @moduledoc "Shows the actual provider-side guardrail system prompt — fully open."
  use Phoenix.LiveView
  import LapsusAgent.UI.Components

  alias LapsusAgent.Guardrail

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, prompt: Guardrail.base())}

  @impl true
  def render(assigns) do
    ~H"""
    <nav class="nav">
      <.brand />
      <span class="muted" style="font-size:.95rem">Guardrail</span>
      <span class="spacer"></span>
      <a href="/" class="lnk">← Home</a>
    </nav>

    <div style="height:1.5rem"></div>

    <div class="card sec">
      <h3>The guardrail system prompt</h3>
      <div class="body">
        <p class="muted" style="font-size:.92rem">
          This exact text is prepended to <strong>every</strong> request a provider serves — enforced
          by the serving machine, so a consumer can't bypass or replace it. It's deliberately
          permissive: help with almost everything, refuse only what is clearly illegal or seriously
          harmful. Nothing hidden — here it is verbatim.
        </p>
        <pre class="jsonbox" style="white-space:pre-wrap">{@prompt}</pre>
        <p class="muted" style="font-size:.82rem">
          When JSON output is requested, a single line is appended asking for valid JSON only.
          Source: <code>LapsusAgent.Guardrail</code>.
        </p>
      </div>
    </div>

    <.footer />
    """
  end
end
