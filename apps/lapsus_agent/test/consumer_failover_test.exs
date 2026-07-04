defmodule LapsusAgent.ConsumerFailoverTest do
  @moduledoc "Deterministic tests for the provider failover control flow (no I/O)."
  use ExUnit.Case, async: true

  alias LapsusAgent.Consumer

  defp far_deadline, do: System.monotonic_time(:millisecond) + 60_000
  defp noop(_event, _meta), do: :ok
  defp providers(ids), do: Enum.map(ids, &%{"peer_id" => &1})

  test "first provider succeeds — no failover" do
    try_fn = fn "A", _dl -> {:ok, %{response: "hi"}} end
    assert {:ok, %{response: "hi"}} = Consumer.failover(providers(["A"]), far_deadline(), &noop/2, try_fn)
  end

  test "fails over to the next provider on :timeout, emitting an event" do
    parent = self()

    try_fn = fn
      "A", _dl -> {:error, :timeout}
      "B", _dl -> {:ok, %{response: "from B"}}
    end

    on_event = fn :failover, meta -> send(parent, {:failed_over, meta}) end

    assert {:ok, %{response: "from B"}} =
             Consumer.failover(providers(["A", "B"]), far_deadline(), on_event, try_fn)

    assert_received {:failed_over, %{provider: "A", reason: :timeout}}
  end

  test "all providers time out — returns the last error" do
    try_fn = fn _p, _dl -> {:error, :timeout} end
    assert {:error, :timeout} = Consumer.failover(providers(["A", "B", "C"]), far_deadline(), &noop/2, try_fn)
  end

  test "a provider error is terminal — does not fail over" do
    parent = self()

    try_fn = fn
      "A", _dl -> {:error, {:provider_error, "insufficient_funds"}}
      "B", _dl -> send(parent, :tried_b) && {:ok, %{}}
    end

    assert {:error, {:provider_error, "insufficient_funds"}} =
             Consumer.failover(providers(["A", "B"]), far_deadline(), &noop/2, try_fn)

    refute_received :tried_b
  end

  test "empty provider list → :no_provider" do
    assert {:error, :no_provider} =
             Consumer.failover([], far_deadline(), &noop/2, fn _p, _dl -> flunk("should not run") end)
  end

  test "stops once the overall budget is exhausted (no further attempts)" do
    parent = self()
    past = System.monotonic_time(:millisecond) - 1

    try_fn = fn
      "A", _dl -> {:error, :timeout}
      "B", _dl -> send(parent, :tried_b) && {:ok, %{}}
    end

    # A is attempted and times out, but the budget is spent → B is never tried.
    assert {:error, :timeout} = Consumer.failover(providers(["A", "B"]), past, &noop/2, try_fn)
    refute_received :tried_b
  end
end
