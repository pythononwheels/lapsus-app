defmodule LapsusAgent.ProviderControl do
  @moduledoc """
  Start/stop the provider under a supervisor so the UI can toggle sharing without
  killing the whole app. (Quitting the app still = offline; this just lets the user
  pause sharing.)
  """

  alias LapsusAgent.Provider

  @sup LapsusAgent.ProviderSup

  @doc "Start sharing (no-op if already running)."
  def start(opts \\ []) do
    case running?() do
      true -> {:ok, Process.whereis(Provider)}
      false -> DynamicSupervisor.start_child(@sup, {Provider, opts})
    end
  end

  @doc "Stop sharing (go offline)."
  def stop do
    case Process.whereis(Provider) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@sup, pid)
    end
  end

  @doc "Is the provider currently sharing?"
  def running?, do: Process.whereis(Provider) != nil

  @doc "Status map for the UI (always includes :running)."
  def status do
    if running?() do
      Provider.status() |> Map.put(:running, true)
    else
      %{running: false}
    end
  end
end
