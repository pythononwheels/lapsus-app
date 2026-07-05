defmodule LapsusAgent.ProviderIdleTest do
  @moduledoc "Deterministic tests for the throughput-based idle-detection decision."
  use ExUnit.Case, async: true

  alias LapsusAgent.Provider
  alias LapsusAgent.Settings

  @on Settings.from_map(%{"pause_when_busy" => true})
  @off Settings.from_map(%{"pause_when_busy" => false})

  # Fold a sequence of tps samples through update_baseline; return the final map + last pause?.
  defp run(samples, settings) do
    Enum.reduce(samples, {%{}, false}, fn tps, {bl, _} ->
      Provider.update_baseline(bl, "m", tps, settings)
    end)
  end

  test "warms up: no pause before min_samples, even on a slow job" do
    # first two samples establish the baseline; a slow 3rd would pause, but here all are steady
    {_bl, pause?} = run([30.0, 30.0], @on)
    refute pause?
  end

  test "pauses when a job runs far below the learned peak" do
    # peak learns ~30 over 3 fast jobs, then a 10 tok/s job (<50% of 30) → pause
    {_bl, pause?} = run([30.0, 30.0, 30.0, 10.0], @on)
    assert pause?
  end

  test "does not pause for a mild dip above the ratio" do
    # 20 tok/s vs ~30 peak = 66% > 50% ratio → not busy
    {_bl, pause?} = run([30.0, 30.0, 30.0, 20.0], @on)
    refute pause?
  end

  test "respects the pause_when_busy toggle" do
    {_bl, pause?} = run([30.0, 30.0, 30.0, 5.0], @off)
    refute pause?
  end

  test "peak rises to the fastest sample (so later contention is measured against it)" do
    {bl, _} = run([20.0, 40.0, 25.0], @on)
    {peak, n} = bl["m"]
    # captured the 40 peak (minus one slow-decay step to 38.8), not the last 25
    assert peak >= 38.0
    assert n == 3
  end

  test "ignores non-positive / nil tps (failed jobs don't move the baseline)" do
    {bl1, _} = Provider.update_baseline(%{}, "m", 30.0, @on)
    {bl2, pause?} = Provider.update_baseline(bl1, "m", nil, @on)
    assert bl2 == bl1
    refute pause?
  end
end
