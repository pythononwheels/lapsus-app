defmodule Mix.Tasks.Lapsus.Consume do
  @shortdoc "Open the LAPSUS consumer app (local website) to ask the network."
  @moduledoc """
  Launch the consumer app: starts a tiny embedded web server and opens the "ask the
  network" page in your browser. Does **not** share your machine — it only consumes.

      mix lapsus.consume

  This is the same local-website model as the provider app (`mix lapsus.app`), just
  opened to the consumer view and without starting a provider. Quit (Ctrl-C twice)
  to close.
  """
  use Mix.Task

  alias LapsusAgent.UI.Launcher

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:lapsus_agent)
    {:ok, _} = Launcher.start!()

    url = Launcher.url("/ask")
    Mix.shell().info("LAPSUS consumer → #{url}  (Ctrl-C twice to quit)")
    Launcher.open_browser(url)

    Process.sleep(:infinity)
  end
end
