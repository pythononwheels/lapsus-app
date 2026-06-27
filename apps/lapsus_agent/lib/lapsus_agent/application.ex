defmodule LapsusAgent.Application do
  @moduledoc """
  Agent OTP application.

  When run as the packaged binary (env `LAPSUS_RUN=1`), it boots the full provider
  app — the local UI + sharing — and opens the browser. Otherwise (dev/test, where
  `lapsus_agent` starts as a plain dependency) it starts nothing, so `mix test` and
  library use are unaffected.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    if run_app?(), do: LapsusAgent.UI.Launcher.configure_port!()

    children = if run_app?(), do: LapsusAgent.UI.Launcher.children(), else: []
    result = Supervisor.start_link(children, strategy: :one_for_one, name: LapsusAgent.Supervisor)

    if run_app?(), do: boot_app()
    result
  end

  defp run_app?, do: System.get_env("LAPSUS_RUN") == "1"

  defp boot_app do
    LapsusAgent.ProviderControl.start()
    url = LapsusAgent.UI.Launcher.url(LapsusAgent.UI.Launcher.start_path())
    Logger.info("LAPSUS running → #{url}  (quit to go offline)")
    unless System.get_env("LAPSUS_NO_BROWSER") == "1", do: LapsusAgent.UI.Launcher.open_browser(url)
  end
end
