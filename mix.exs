defmodule Lapsus.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  # Each release is defined only when its app is present in the umbrella, so the
  # same mix.exs works in every context: the full monorepo (both), the coordinator
  # Docker build (only core+coordinator copied in), and the public client export
  # (only core+agent). Referencing an absent app would corrupt the release.
  defp releases do
    coordinator =
      if File.dir?("apps/lapsus_coordinator") do
        # Server (no Rust/WebRTC).
        [lapsus_coordinator: [applications: [lapsus_coordinator: :permanent], include_executables_for: [:unix]]]
      else
        []
      end

    agent =
      if File.dir?("apps/lapsus_agent") do
        # Client app — bundles ERTS so it runs without Elixir on the user's machine.
        # Build both launchers so the same release config works on macOS/Linux (bin/lapsus)
        # and Windows (bin/lapsus.bat); the platform packaging is per-OS in CI.
        [lapsus: [applications: [lapsus_agent: :permanent], include_executables_for: [:unix, :windows]]]
      else
        []
      end

    coordinator ++ agent
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    []
  end
end
