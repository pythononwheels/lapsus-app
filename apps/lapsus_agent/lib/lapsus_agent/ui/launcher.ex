defmodule LapsusAgent.UI.Launcher do
  @moduledoc """
  Shared startup for the local UI apps (`mix lapsus.app` / `mix lapsus.consume`).

  The UI port is configurable via `LAPSUS_UI_PORT` (default 4040) so it never
  collides with whatever else a developer is running.
  """

  @default_port 4040

  @doc "Configured UI port (`LAPSUS_UI_PORT`, default #{@default_port})."
  def port do
    case System.get_env("LAPSUS_UI_PORT") do
      nil -> @default_port
      val -> String.to_integer(val)
    end
  end

  @doc "Local URL for a path on the UI."
  def url(path \\ "/"), do: "http://localhost:#{port()}#{path}"

  @doc "Always open the home; it self-gates to onboarding or the Share/Ask hub."
  def start_path, do: "/"

  @doc "Apply the configured `LAPSUS_UI_PORT` to the endpoint config."
  def configure_port! do
    cfg = Application.get_env(:lapsus_agent, LapsusAgent.UI.Endpoint, [])
    http = cfg |> Keyword.get(:http, []) |> Keyword.put(:port, port())
    Application.put_env(:lapsus_agent, LapsusAgent.UI.Endpoint, Keyword.put(cfg, :http, http))
  end

  @doc "UI children for a supervision tree (PubSub, provider supervisor, endpoint)."
  def children do
    [
      {Phoenix.PubSub, name: LapsusAgent.PubSub},
      {DynamicSupervisor, name: LapsusAgent.ProviderSup, strategy: :one_for_one},
      LapsusAgent.UI.Endpoint
    ]
  end

  @doc "Apply the configured port to the endpoint and start the UI supervision tree."
  def start! do
    configure_port!()

    Supervisor.start_link(children(), strategy: :one_for_one)
  end

  @doc "Open the given URL in the default browser (best effort)."
  def open_browser(url) do
    cmd =
      case :os.type() do
        {:unix, :darwin} -> "open"
        {:win32, _} -> "explorer"
        _ -> "xdg-open"
      end

    _ = System.cmd(cmd, [url], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end
end
