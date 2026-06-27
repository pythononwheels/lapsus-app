defmodule LapsusAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :lapsus_agent,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {LapsusAgent.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:lapsus_core, in_umbrella: true},
      {:req, "~> 0.5"},
      {:slipstream, "~> 1.2"},
      {:ex_webrtc, "~> 0.17"},
      # DataChannel/SCTP support for ex_webrtc (Rust NIF).
      {:ex_sctp, "~> 0.1.3"},
      # Local provider UI (LiveView served on localhost; later wrapped natively).
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.5"},
      # Render model markdown answers to sanitized HTML for the Use-AI page.
      {:mdex, "~> 0.13"},
      {:nimble_parsec, "~> 1.4"}
    ]
  end
end
