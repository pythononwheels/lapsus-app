defmodule LapsusAgent.Settings do
  @moduledoc """
  Provider contribution settings — how much of your machine you give, persisted as
  JSON next to the identity (`~/.lapsus/settings.json`, or `LAPSUS_SETTINGS`).

  These are global (all models) for now; per-model overrides come later.

    * `contribution_pct` — friendly 0/25/50/75/100 slider. Mapped to a concrete
      daily output-token budget via measured throughput (see `Provider`).
    * `per_consumer_pct` — max share of the daily budget any single consumer may take.
    * `max_concurrency`  — max simultaneous requests served (1 = one GPU, one job).
    * `max_out_per_req`  — hard cap on output tokens per request (protects VRAM/time).
    * `anchor_hours`     — what "100% contribution" means: throughput sustained this
      many hours/day (the reference for the daily-budget math). 4 | 8 | 12.
    * `pause_when_busy`  — auto-pause sharing when your own use slows the engine down
      (throughput-based load detection; see `Provider`).
    * `busy_cooldown_s`  — how long to stay paused after detecting your own load.
  """
  defstruct contribution_pct: 25,
            per_consumer_pct: 25,
            max_concurrency: 1,
            max_out_per_req: 1024,
            anchor_hours: 4,
            pause_when_busy: true,
            busy_cooldown_s: 90,
            # Thousands separator style: "eu" → 1.234, "us" → 1,234.
            number_format: "eu",
            # Which engine to serve from: "auto" | "openai" | "ollama" | "other".
            engine: "auto",
            # "other" = a remote OpenAI-compatible API (NVIDIA etc.). base_url + a
            # model allowlist; the API key is better set via env LAPSUS_API_KEY on
            # servers, but may be stored here for the desktop UI (plaintext, ~/.lapsus).
            api_base_url: "",
            api_key: "",
            api_protocol: "openai",
            api_models: [],
            onboarded: false

  @type t :: %__MODULE__{}

  @doc "Default settings."
  def default, do: %__MODULE__{}

  @doc "Thousands separator for the chosen number format."
  def separator(%__MODULE__{number_format: "us"}), do: ","
  def separator(_), do: "."

  @doc "Intl locale matching the chosen number format (for Chart.js grouping)."
  def chart_locale(%__MODULE__{number_format: "us"}), do: "en-US"
  def chart_locale(_), do: "de-DE"

  @doc "Load settings from disk, or defaults if absent/invalid."
  @spec load(Path.t() | nil) :: t()
  def load(path \\ default_path()) do
    with {:ok, json} <- File.read(path), {:ok, map} <- Jason.decode(json) do
      from_map(map)
    else
      _ -> default()
    end
  end

  @doc "Persist settings to disk."
  @spec save(t(), Path.t() | nil) :: :ok
  def save(%__MODULE__{} = s, path \\ default_path()) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(Map.from_struct(s)))
    :ok
  end

  @doc "Build a sanitised struct from a string-keyed map (form params or JSON)."
  @spec from_map(map()) :: t()
  def from_map(m) do
    %__MODULE__{
      contribution_pct: round5(int(m["contribution_pct"], 25)),
      per_consumer_pct: snap(int(m["per_consumer_pct"], 25), [25, 50, 75, 100]),
      max_concurrency: clamp(int(m["max_concurrency"], 1), 1, 16),
      max_out_per_req: clamp(int(m["max_out_per_req"], 1024), 64, 32_768),
      anchor_hours: snap(int(m["anchor_hours"], 4), [4, 8, 12]),
      pause_when_busy: bool(m["pause_when_busy"], true),
      busy_cooldown_s: clamp(int(m["busy_cooldown_s"], 90), 15, 600),
      number_format: fmt(m["number_format"], "eu"),
      engine: eng(m["engine"], "auto"),
      api_base_url: str(m["api_base_url"], ""),
      api_key: str(m["api_key"], ""),
      api_protocol: proto(m["api_protocol"], "openai"),
      api_models: model_list(m["api_models"], []),
      onboarded: m["onboarded"] == true
    }
  end

  @doc "Has the first-run wizard been completed?"
  def onboarded?(path \\ default_path()), do: load(path).onboarded

  @doc "Mark onboarding complete (persisted)."
  def mark_onboarded(path \\ default_path()) do
    load(path) |> Map.put(:onboarded, true) |> save(path)
  end

  @doc "Merge string-keyed params into existing settings (only provided keys change)."
  @spec update(t(), map()) :: t()
  def update(%__MODULE__{} = s, m) do
    %__MODULE__{
      contribution_pct: maybe(m["contribution_pct"], s.contribution_pct, &round5(int(&1, s.contribution_pct))),
      per_consumer_pct: maybe(m["per_consumer_pct"], s.per_consumer_pct, &snap(int(&1, s.per_consumer_pct), [25, 50, 75, 100])),
      max_concurrency: maybe(m["max_concurrency"], s.max_concurrency, &clamp(int(&1, s.max_concurrency), 1, 16)),
      max_out_per_req: maybe(m["max_out_per_req"], s.max_out_per_req, &clamp(int(&1, s.max_out_per_req), 64, 32_768)),
      anchor_hours: maybe(m["anchor_hours"], s.anchor_hours, &snap(int(&1, s.anchor_hours), [4, 8, 12])),
      pause_when_busy: maybe(m["pause_when_busy"], s.pause_when_busy, &bool(&1, s.pause_when_busy)),
      busy_cooldown_s: maybe(m["busy_cooldown_s"], s.busy_cooldown_s, &clamp(int(&1, s.busy_cooldown_s), 15, 600)),
      number_format: maybe(m["number_format"], s.number_format, &fmt(&1, s.number_format)),
      engine: maybe(m["engine"], s.engine, &eng(&1, s.engine)),
      api_base_url: maybe(m["api_base_url"], s.api_base_url, &str(&1, s.api_base_url)),
      api_key: maybe(m["api_key"], s.api_key, &str(&1, s.api_key)),
      api_protocol: maybe(m["api_protocol"], s.api_protocol, &proto(&1, s.api_protocol)),
      api_models: maybe(m["api_models"], s.api_models, &model_list(&1, s.api_models)),
      onboarded: s.onboarded
    }
  end

  defp maybe(nil, current, _fun), do: current
  defp maybe(val, _current, fun), do: fun.(val)

  defp fmt(v, _d) when v in ["eu", "us"], do: v
  defp fmt(_, d), do: d

  defp eng(v, _d) when v in ["auto", "openai", "ollama", "other"], do: v
  defp eng(_, d), do: d

  defp proto(v, _d) when v in ["openai"], do: v
  defp proto(_, d), do: d

  defp str(v, _d) when is_binary(v), do: String.trim(v)
  defp str(_, d), do: d

  # Accepts a list of strings or a comma/whitespace-separated string → clean list.
  defp model_list(v, _d) when is_list(v), do: v |> Enum.map(&to_string/1) |> clean_models()
  defp model_list(v, _d) when is_binary(v), do: v |> String.split([",", "\n"]) |> clean_models()
  defp model_list(_, d), do: d

  defp clean_models(list), do: list |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  defp bool(v, _d) when v in [true, "true", "on", "1"], do: true
  defp bool(v, _d) when v in [false, "false", "off", "0"], do: false
  defp bool(_, d), do: d

  def default_path do
    System.get_env("LAPSUS_SETTINGS") ||
      Path.join([System.user_home!() || ".", ".lapsus", "settings.json"])
  end

  defp int(nil, d), do: d
  defp int(v, _) when is_integer(v), do: v
  defp int(v, d) when is_binary(v), do: (Integer.parse(v) |> elem_or(d))
  defp int(_, d), do: d

  defp elem_or({n, _}, _), do: n
  defp elem_or(:error, d), do: d

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
  defp snap(v, allowed), do: Enum.min_by(allowed, &abs(&1 - v))
  defp round5(v), do: clamp(round(v / 5) * 5, 0, 100)
end
