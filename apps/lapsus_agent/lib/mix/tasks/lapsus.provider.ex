defmodule Mix.Tasks.Lapsus.Provider do
  @shortdoc "Run the LAPSUS provider app — share your local AI. Ctrl-C to stop (= offline)."
  @moduledoc """
  Start sharing your local AI (Ollama / LM Studio) with the LAPSUS community.

  This is an **app, not a service**: it runs in the foreground and shares only
  while it's running. Press Ctrl-C twice (or close it) to go offline immediately.

      mix lapsus.provider
      mix lapsus.provider --url ws://coordinator.example:4000
      mix lapsus.provider --identity ~/.lapsus/identity.key

  Options:
    * `--url`      coordinator WebSocket URL (default ws://localhost:4000)
    * `--identity` path to the identity key file (default ~/.lapsus/identity.key)
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [url: :string, identity: :string])

    {:ok, _} = Application.ensure_all_started(:lapsus_agent)

    case LapsusAgent.Provider.start_link(url: opts[:url], identity_path: opts[:identity]) do
      {:ok, _pid} ->
        Mix.shell().info("LAPSUS provider running. Press Ctrl-C twice to stop (= offline).")
        Process.sleep(:infinity)

      {:error, :no_local_engine} ->
        Mix.raise("No local engine found. Start Ollama (:11434) or LM Studio (:1234) first.")
    end
  end
end
