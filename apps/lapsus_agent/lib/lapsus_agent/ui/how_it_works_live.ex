defmodule LapsusAgent.UI.HowItWorksLive do
  @moduledoc "The full 'How it works' explainer — kept off the short landing page."
  use Phoenix.LiveView
  import LapsusAgent.UI.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <nav class="nav">
      <.brand />
      <span class="muted" style="font-size:.95rem">How it works</span>
      <span class="spacer"></span>
      <a href="/ask" class="btn btn-secondary">Use AI</a>
      <a href="/provider" class="btn btn-primary">Share AI</a>
    </nav>

    <section class="section" style="border-top:0">
      <div>
        <div class="eyebrow">How it works</div>
        <h1 style="font-size:2rem;line-height:1.1;margin:.4rem 0 .8rem">A commons for local AI — no Big Tech in the middle</h1>
        <p>
          LAPSUS is a peer-to-peer network of personal machines running local models. When your
          GPU sits idle you share it; when you need more, you borrow someone else's — and the
          prompt travels <strong>directly from your machine to theirs</strong>. A thin coordinator
          only introduces the two peers and keeps the credit score. It never sees your prompts.
        </p>
      </div>
      <div>
        <.p2p_diagram />
        <p class="muted" style="text-align:center;font-size:.85rem;margin-top:.6rem">
          Prompts and answers go direct &amp; encrypted — they never touch a server.
        </p>
      </div>
    </section>

    <div class="block trio">
      <div class="tcard">
        <h3>No Big Tech</h3>
        <p>Community-shared resources instead of a handful of cloud giants. Voluntary, non-commercial — a commons, not a marketplace.</p>
      </div>
      <div class="tcard">
        <h3>True peer-to-peer</h3>
        <p>You share resources and you can use others'. Requests go <strong>straight from client to client</strong> over a direct encrypted channel — no server in the path.</p>
      </div>
      <div class="tcard">
        <h3>Give some, get some</h3>
        <p>Share a text model; tap someone's image generation or text-to-speech in return. Together we stay independent and build a decentralized local-AI network.</p>
      </div>
    </div>

    <div class="block">
      <div class="eyebrow" style="text-align:center">Security</div>
      <h2 class="block-title">Built in from the ground up</h2>
      <div class="secgrid">
        <div class="seccard core">
          <.sec_icon kind="lock" />
          <h3>No tools on providers</h3>
          <p>
            An AI model is just a text generator — <strong>text in, text out</strong>. There's no
            tool executor, no file access and no shell wiring it to your machine, so a remote prompt
            simply <strong>can't</strong> read files, fetch URLs or run code — the capability isn't
            there. Tool-calling fields are stripped from every request, by design.
          </p>
          <a href="/no-tools" class="lnk2">Read more →</a>
        </div>
        <div class="seccard">
          <.sec_icon kind="shield" />
          <h3>An additional guardrail prompt</h3>
          <p>
            On top of that, every served request is prefixed with a light safety prompt, enforced by
            the serving machine so the asker can't bypass it. Permissive by default — and fully open.
          </p>
          <a href="/guardrail" class="lnk2">Read the prompt →</a>
        </div>
        <div class="seccard">
          <.sec_icon kind="gauge" />
          <h3>Hard limits</h3>
          <p>
            You set how much you give (idle-time %, max output, concurrency). When your quota is hit
            the network simply stops routing to you until it resets — requests don't even arrive.
          </p>
        </div>
      </div>
    </div>

    <div class="block">
      <div class="share-head">
        <div>
          <h2>Share your AI</h2>
          <p>
            Already running Ollama or LM Studio? Open the app and your idle GPU joins the commons.
            You set what to share; close the app and you're instantly out.
          </p>
          <p class="muted">Earn credits for every request you serve.</p>
        </div>
        <div>
          <h4 class="howto">How to share</h4>
          <ol class="steps">
            <li>Start <strong>LM Studio</strong> or <strong>Ollama</strong> and load a model.</li>
            <li>Open the LAPSUS app.</li>
            <li>Flip the <strong>Share</strong> switch on.</li>
            <li>That's it — you're part of the LAPSUS AI p2p network.</li>
            <li>Switch it off and you're disconnected instantly.</li>
          </ol>
          <p class="muted">
            Optional: cap how much you give (e.g. 25% of idle time), and set rate limits / max
            context per request.
          </p>
        </div>
      </div>
      <div class="term shotframe" style="margin-top:1.6rem">
        <div class="bar"><i style="background:#d7dade"></i><i style="background:#d7dade"></i><i style="background:#d7dade"></i></div>
        <img src="/static/shot-share.png" class="shot" alt="LAPSUS — Share AI screen" />
      </div>
    </div>

    <section class="section">
      <div class="term shotframe">
        <div class="bar"><i style="background:#d7dade"></i><i style="background:#d7dade"></i><i style="background:#d7dade"></i></div>
        <img src="/static/shot-use.png" class="shot" alt="LAPSUS — Use AI screen" />
      </div>
      <div>
        <h2>Use the network</h2>
        <p>
          Pick a community model, send a prompt, and get the answer back from someone else's machine
          over a direct encrypted channel. Spend the credits you earned by sharing.
        </p>
        <p class="muted">Markdown or JSON output, attach a file, ⌘/Ctrl+Enter to send.</p>
        <div style="margin-top:1.2rem">
          <a href="/provider" class="btn btn-primary">Share your AI →</a>
          <a href="/ask" class="btn btn-secondary">Use the network →</a>
        </div>
      </div>
    </section>

    <.footer />
    """
  end
end
