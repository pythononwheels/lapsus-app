defmodule LapsusAgent.Version do
  @moduledoc """
  The running app's release version and update check.

  CI writes the git tag (e.g. `v0.1.9-beta`) into `priv/VERSION` at build time;
  absent that file (local dev), `current/0` reports `"dev"`. `check_update/0`
  asks GitHub for the latest published release and compares it with the running
  version.
  """

  @repo "pythononwheels/lapsus-app"
  @get_page "https://lapsus.pyrates.io/get.html"

  @doc "The running version string, e.g. \"v0.1.9-beta\" or \"dev\" for local builds."
  def current do
    case File.read(version_file()) do
      {:ok, v} ->
        case String.trim(v) do
          "" -> "dev"
          v -> v
        end

      _ ->
        "dev"
    end
  end

  defp version_file, do: Application.app_dir(:lapsus_agent, "priv/VERSION")

  @doc """
  Compare the running version with the latest GitHub release.

  Returns `{:update, latest_tag, url}` when a newer release exists,
  `:current` when up to date, `:dev` for local builds, `:unknown` on any error
  (offline, rate-limited, unparseable).
  """
  def check_update do
    cur = current()

    case latest_release() do
      {:ok, %{tag: tag}} when cur == "dev" ->
        # Local dev build — surface the latest published tag for info, not as a nag.
        {:dev, tag, @get_page}

      {:ok, %{tag: tag}} ->
        if newer?(tag, cur), do: {:update, tag, @get_page}, else: :current

      :error ->
        if cur == "dev", do: :dev, else: :unknown
    end
  end

  defp latest_release do
    url = "https://api.github.com/repos/#{@repo}/releases/latest"

    headers = [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "lapsus-agent"}
    ]

    case Req.get(url, headers: headers, retry: false, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"tag_name" => tag}}} when is_binary(tag) ->
        {:ok, %{tag: tag}}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  # True when `latest` is a strictly newer version than `current`.
  defp newer?(latest, current) do
    with {:ok, lv} <- Version.parse(strip_v(latest)),
         {:ok, cv} <- Version.parse(strip_v(current)) do
      Version.compare(lv, cv) == :gt
    else
      # If either tag isn't SemVer-parseable, treat any difference as an update.
      _ -> latest != current
    end
  end

  defp strip_v("v" <> rest), do: rest
  defp strip_v(other), do: other
end
