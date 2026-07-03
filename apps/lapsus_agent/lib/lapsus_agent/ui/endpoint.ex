defmodule LapsusAgent.UI.Endpoint do
  @moduledoc """
  Local Phoenix endpoint for the provider app's UI (served on 127.0.0.1).

  No asset build step: the LiveView JS is served straight from the deps' `priv`
  via `Plug.Static`, and the LiveSocket is wired with a small inline script in the
  root layout. This same LiveView is what a native window (elixir-desktop) will
  later render — no rework.
  """
  use Phoenix.Endpoint, otp_app: :lapsus_agent

  @session_options [
    store: :cookie,
    key: "_lapsus_ui",
    signing_salt: "lapsusUIs",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  # Serve the prebuilt JS shipped inside the deps (no bundler needed).
  plug Plug.Static, at: "/vendor/phoenix", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/vendor/lv",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  plug Plug.Static, at: "/static", from: {:lapsus_agent, "priv/static"}, only: ~w(lapsus.png shot-use.png shot-share.png)

  # Vendored Chart.js (no bundler) for the dashboards.
  plug Plug.Static, at: "/vendor/chartjs", from: {:lapsus_agent, "priv/static/vendor"}, only: ~w(chart.umd.min.js)

  # JSON bodies for the /v1 gateway (the LiveView UI didn't need a body parser before).
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason

  plug Plug.Session, @session_options
  plug LapsusAgent.UI.Router
end
