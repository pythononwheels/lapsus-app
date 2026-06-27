defmodule Mix.Tasks.Lapsus.Ask do
  @shortdoc "Ask the LAPSUS network a prompt: mix lapsus.ask <model> \"<prompt>\""
  @moduledoc """
  Ask a prompt to a model served by a provider on the LAPSUS network.

      mix lapsus.ask google/gemma-4-e2b "In one sentence: what is peer-to-peer?"
      mix lapsus.ask llama3 "hello" --url ws://coordinator.example:4000 --max-tokens 200

  Options:
    * `--url`        coordinator URL (default ws://localhost:4000)
    * `--max-tokens` generation cap (default 300)
    * `--identity`   identity key file (default ~/.lapsus/identity.key)
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args, strict: [url: :string, max_tokens: :integer, identity: :string])

    case rest do
      [model | prompt_parts] when prompt_parts != [] ->
        {:ok, _} = Application.ensure_all_started(:lapsus_agent)
        ask(model, Enum.join(prompt_parts, " "), opts)

      _ ->
        Mix.raise(~s|Usage: mix lapsus.ask <model> "<prompt>"|)
    end
  end

  defp ask(model, prompt, opts) do
    Mix.shell().info("asking #{model} via the network…")

    case LapsusAgent.Consumer.ask(model, prompt,
           url: opts[:url],
           max_tokens: opts[:max_tokens],
           identity_path: opts[:identity]
         ) do
      {:ok, res} ->
        Mix.shell().info("\n" <> (res.response || "(no visible content)"))
        Mix.shell().info("\n― #{res.in_tokens} in / #{res.out_tokens} out tokens" <> billing(res))

      {:error, :no_provider} ->
        Mix.raise("No provider online for #{model}. Is someone running `mix lapsus.app`/`mix lapsus.provider`?")

      {:error, reason} ->
        Mix.raise("Failed: #{inspect(reason)}")
    end
  end

  defp billing(%{billed: true, cc: cc, balance: balance}),
    do: " · #{cc} CC charged · balance #{balance}"

  defp billing(%{billed: false, cc: cc, billing_error: err}),
    do: " · NOT billed (#{cc} CC, #{inspect(err)})"

  defp billing(_), do: " · not billed"
end
