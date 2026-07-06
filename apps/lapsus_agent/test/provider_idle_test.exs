defmodule LapsusAgent.ProviderIdleTest do
  @moduledoc "Deterministic tests for the throughput-baseline / slow-job signal."
  use ExUnit.Case, async: true

  alias LapsusAgent.Provider

  # Fold a sequence of tps samples through update_baseline; return the final map + last slow?.
  defp run(samples) do
    Enum.reduce(samples, {%{}, false}, fn tps, {bl, _} ->
      Provider.update_baseline(bl, "m", tps)
    end)
  end

  test "warms up: no slow signal before min_samples" do
    {_bl, slow?} = run([30.0, 30.0])
    refute slow?
  end

  test "flags a job that runs far below the learned peak" do
    # peak learns ~30 over 3 steady jobs, then a 10 tok/s job (< 40% of 30) → slow
    {_bl, slow?} = run([30.0, 30.0, 30.0, 10.0])
    assert slow?
  end

  test "does not flag a mild dip above the ratio" do
    # 20 tok/s vs ~30 peak = 66% > 40% ratio → not slow
    {_bl, slow?} = run([30.0, 30.0, 30.0, 20.0])
    refute slow?
  end

  test "peak captures the fastest sample (fades on later slower ones)" do
    {bl, _} = run([20.0, 40.0, 25.0])
    {peak, n} = bl["m"]
    # captured the 40 peak (one decay step to 36), not the last 25
    assert peak > 30.0
    assert n == 3
  end

  test "ignores non-positive / nil tps (failed jobs don't move the baseline)" do
    {bl1, _} = Provider.update_baseline(%{}, "m", 30.0)
    {bl2, slow?} = Provider.update_baseline(bl1, "m", nil)
    assert bl2 == bl1
    refute slow?
  end
end
