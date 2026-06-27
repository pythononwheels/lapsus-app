defmodule LapsusCore.CreditsTest do
  use ExUnit.Case, async: true
  doctest LapsusCore.Credits

  alias LapsusCore.Credits

  test "output tokens cost more than input tokens" do
    in_only = Credits.cost(100, 0, 1.0)
    out_only = Credits.cost(0, 100, 1.0)
    assert out_only > in_only
  end

  test "cost scales linearly with model_weight" do
    base = Credits.cost(50, 50, 1.0)
    big = Credits.cost(50, 50, 8.0)
    assert big == base * 8
  end

  test "respects custom coefficients" do
    cost = Credits.cost(10, 10, 1.0, coeffs: %{a: 2.0, b: 2.0})
    assert cost == 40
  end

  test "can return unrounded cost" do
    cost = Credits.cost(1, 0, 0.5, round: false)
    assert cost == 0.5
  end

  test "rejects non-positive model_weight" do
    assert_raise FunctionClauseError, fn -> Credits.cost(1, 1, 0) end
  end
end
