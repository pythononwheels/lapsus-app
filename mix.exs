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

  # The client (provider/consumer) app release — bundles ERTS so it runs with no
  # Elixir on the user's machine. `LAPSUS_RUN=1 bin/lapsus start`.
  defp releases do
    [
      lapsus: [
        applications: [lapsus_agent: :permanent],
        include_executables_for: [:unix]
      ]
    ]
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
