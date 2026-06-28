<div align="center">

<img src="apps/lapsus_agent/priv/static/lapsus.png" alt="LAPSUS" width="120" />

**Community-powered local AI p2p network**

<h1>Let's run AI.<br/>On our own machines.<br/>Not Big Tech's cloud.</h1>

<em>Let's build our own decentralized AI p2p network.</em>

<a href="https://lapsus.pyrates.io">lapsus.pyrates.io</a> &nbsp;·&nbsp; <a href="https://lapsus.pyrates.io/how">How it works</a> &nbsp;·&nbsp; <a href="LICENSE">AGPL-3.0</a>

</div>

---

This is the **LAPSUS client** — the small local app you run on your own machine.
It sits in front of the model you already run (Ollama, LM Studio, …) and joins you
to the community network: **share** your idle GPU to earn Compute-Credits, **use**
the community's compute when you need it. Prompts travel **directly, peer to peer** —
a thin coordinator only introduces peers and never sees your data.

- **Share** — flip a switch; your idle GPU joins the commons. Close the app, you're out.
- **Use** — pick a community model, send a prompt, get the answer back P2P.
- **Give-to-get** — sharing earns credits; using the network spends them. Offer some, get some.

## Download

macOS & Linux — one line, no Gatekeeper prompt:

```bash
curl -fsSL https://lapsus.pyrates.io/install.sh | bash
```

Fetched via curl, so macOS adds no quarantine — it installs into Applications and
just opens (no xattr, no “Open Anyway”). On macOS this is the way; a downloaded
`.zip` would be blocked by Gatekeeper.

On Linux you can also grab the tarball directly:
**[Linux (x64)](https://github.com/pythononwheels/lapsus-app/releases/latest/download/LAPSUS-linux-x64.tar.gz)** — unpack and run `./lapsus/run-lapsus.sh`.

Both bundle their own runtime and default to the live network. Intel Macs & Windows
are on the way — see all [releases](https://github.com/pythononwheels/lapsus-app/releases).

## Run it from source

The app bundles a small web UI it opens in your browser.

```bash
# needs Elixir + Rust (for the WebRTC NIF).
mix deps.get
LAPSUS_COORDINATOR_URL=wss://lapsus.pyrates.io mix lapsus.app

# Or a self-contained binary (bundles the runtime; defaults to the live
# network, so no Elixir is needed to run it):
MIX_ENV=prod mix release lapsus
LAPSUS_RUN=1 _build/prod/rel/lapsus/bin/lapsus start

# macOS: build a double-clickable .app
scripts/build_macos_app.sh        # → dist/LAPSUS.app
```

`LAPSUS_COORDINATOR_URL` points the app at a coordinator (default for the packaged
binary: `wss://lapsus.pyrates.io`; for `mix lapsus.app` dev: `ws://localhost:4000`).

## Security, in short

A provider only ever **generates text** — there is no tool executor, file access or
shell wired to the model, so a remote prompt can't touch your machine. A light,
open guardrail prompt is applied to every request, and you set hard rate limits.
See [the full explanation](https://lapsus.pyrates.io/no-tools).

## Layout

- `apps/lapsus_agent` — the client: provider, consumer, the local web UI.
- `apps/lapsus_core` — shared identity (Ed25519), Compute-Credits, signed receipts.

The coordinator (the thin server that introduces peers) is a separate component.

## License

[AGPL-3.0](LICENSE). Network copyleft — run a modified version as a service, share
your source. A commons, not a land-grab.
