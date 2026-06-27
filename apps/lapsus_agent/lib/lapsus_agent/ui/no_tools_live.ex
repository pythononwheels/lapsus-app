defmodule LapsusAgent.UI.NoToolsLive do
  @moduledoc "Explainer: why a model structurally can't touch the provider's machine."
  use Phoenix.LiveView
  import LapsusAgent.UI.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <nav class="nav">
      <.brand />
      <span class="muted" style="font-size:.95rem">Security</span>
      <span class="spacer"></span>
      <a href="/how" class="lnk">← How it works</a>
    </nav>

    <div style="height:1.5rem"></div>

    <div class="card">
      <div class="eyebrow">Security · No tools on providers</div>
      <h1 style="font-size:1.8rem;line-height:1.15;margin:.4rem 0 .8rem">Why a model can't touch your machine</h1>
      <p class="muted" style="font-size:1.02rem">
        The strongest guarantee in LAPSUS isn't a rule we enforce — it's that the ability to do harm
        doesn't exist in the path. Here's exactly why, including why a model badged as
        “trained for tool use” changes nothing.
      </p>

      <h3 style="margin-top:1.4rem">A model is just text in, text out</h3>
      <p class="muted">
        An AI model is a function that predicts the next token. By itself it can't <em>do</em>
        anything — it can't read a file, run a command, or open a network connection. It only
        produces text.
      </p>

      <h3 style="margin-top:1.2rem">What “tool use” actually means</h3>
      <p class="muted">
        You may see a model badged as “trained for tool use” (e.g. in LM Studio). That's a property
        of the <strong>model</strong>: given a list of tools, it can produce a structured
        <em>“call tool X with arguments Y”</em> — but that output is still just text, a request. It
        executes nothing.
      </p>
      <p class="muted">
        Executing a tool always takes a host program <em>around</em> the model that (1) offers the
        model a set of tools, (2) parses its output for tool calls, and (3) actually runs them —
        reads the file, runs the shell, fetches the URL. <strong>The danger lives entirely in that
        executor, not in the model.</strong> Even LM Studio's server only <em>returns</em>
        <code>tool_calls</code>; running them is the calling app's job.
      </p>

      <h3 style="margin-top:1.2rem">In LAPSUS, that executor doesn't exist</h3>
      <ul class="clean">
        <li><strong>We never offer tools.</strong> The serving call carries no tools schema, so the model has nothing to call — and won't even try.</li>
        <li><strong>We strip tool fields.</strong> <code>tools</code>, <code>functions</code> and <code>tool_choice</code> are dropped from every incoming request — you can't switch tool use on from the outside.</li>
        <li><strong>Nothing parses or runs the output.</strong> The model's text is returned to the asker as-is. No agent loop, no MCP, no file or shell access wired to the model.</li>
      </ul>

      <h3 style="margin-top:1.2rem">So both are true at once</h3>
      <p class="muted">
        “Tool-trained model” and “no tools on providers” don't contradict each other. The badge says
        the model <em>could</em> format a tool call; LAPSUS says there's nothing on the provider to
        <em>execute</em> one — and it's never handed any. A prompt that asks to read your files gets,
        at most, a sentence of text back saying it can't. The capability simply isn't in the path.
      </p>
    </div>

    <.footer />
    """
  end
end
