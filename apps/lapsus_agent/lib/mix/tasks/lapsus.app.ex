defmodule Mix.Tasks.Lapsus.App do
  @shortdoc "Run the LAPSUS provider app with its local web UI. Close to go offline."
  @moduledoc """
  Launch the provider app: starts the local web UI (http://localhost:4040), begins
  sharing your local AI, and opens the dashboard in your browser.

      mix lapsus.app

  This is an app, not a service — quit it (Ctrl-C twice) to go offline.
  Later this same UI is wrapped in a native window (elixir-desktop).
  """
  use Mix.Task

  alias LapsusAgent.UI.Launcher

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:lapsus_agent)
    {:ok, _} = Launcher.start!()

    # Begin sharing right away (the UI can pause/resume it).
    LapsusAgent.ProviderControl.start()

    url = Launcher.url(Launcher.start_path())
    Mix.shell().info("LAPSUS → #{url}  (Ctrl-C twice to quit = offline)")
    Launcher.open_browser(url)

    Process.sleep(:infinity)
  end
end
