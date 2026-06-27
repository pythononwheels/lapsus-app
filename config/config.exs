# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :lapsus_coordinator,
  ecto_repos: [LapsusCoordinator.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :lapsus_coordinator, LapsusCoordinatorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: LapsusCoordinatorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LapsusCoordinator.PubSub,
  live_view: [signing_salt: "d7b2ZrvS"]

# Local provider UI endpoint (served on localhost; started by `mix lapsus.app`).
config :lapsus_agent, LapsusAgent.UI.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  server: true,
  # Local-only tool — no real secrets transit this endpoint.
  secret_key_base: "lapsus_local_ui_secret_key_base_at_least_64_bytes_long_padding_xxxxx",
  live_view: [signing_salt: "lapsusUI"],
  pubsub_server: LapsusAgent.PubSub,
  render_errors: [formats: [html: LapsusAgent.UI.ErrorHTML], layout: false],
  check_origin: false

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Sample configuration:
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#
