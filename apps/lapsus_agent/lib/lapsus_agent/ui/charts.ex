defmodule LapsusAgent.UI.Charts do
  @moduledoc """
  Chart payload builders shared by the provider and consumer dashboards. These
  return plain maps that are JSON-encoded into a `data-chart` attribute and
  rendered client-side by the `Chart` LiveView hook (vendored Chart.js).
  """

  @palette ["#16181d", "#3d434c", "#6b7280", "#9aa1ab", "#c2c6cd", "#dfe2e6"]

  @doc "Stacked out/in bar-chart payload over `days` (`[%{\"date\",\"in\",\"out\"}]`)."
  def bar_data(days, locale \\ "en-US") do
    %{
      kind: "bar",
      locale: locale,
      labels: Enum.map(days, &short_date(&1["date"])),
      out: Enum.map(days, &(&1["out"] || 0)),
      in: Enum.map(days, &(&1["in"] || 0))
    }
  end

  @doc """
  Doughnut payload: top 5 models by out-tokens + an "other" slice, with the
  muted-grayscale palette.
  """
  def donut_data(by_model, locale \\ "en-US") do
    sorted = Enum.sort_by(by_model, &(-(&1["out"] || 0)))
    {top, rest} = Enum.split(sorted, 5)

    segments =
      top ++
        if rest == [] do
          []
        else
          [%{"model" => "other", "out" => Enum.reduce(rest, 0, &((&1["out"] || 0) + &2))}]
        end

    %{
      kind: "donut",
      locale: locale,
      labels: Enum.map(segments, &short_model(&1["model"])),
      values: Enum.map(segments, &(&1["out"] || 0)),
      colors: Enum.with_index(segments) |> Enum.map(fn {_m, i} -> Enum.at(@palette, rem(i, length(@palette))) end)
    }
  end

  # "google/gemma-4-e2b" -> "gemma-4-e2b" (drop the org/ prefix to save space)
  defp short_model(name) when is_binary(name), do: name |> String.split("/") |> List.last()
  defp short_model(name), do: name

  @doc "Encode a chart payload for the `data-chart` attribute."
  def json(payload), do: Jason.encode!(payload)

  # "2026-06-26" -> "26.6"
  defp short_date(date) when is_binary(date) do
    case String.split(date, "-") do
      [_y, m, d] -> "#{String.to_integer(d)}.#{String.to_integer(m)}"
      _ -> date
    end
  end

  defp short_date(_), do: ""
end
