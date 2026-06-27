defmodule LapsusAgentTest do
  use ExUnit.Case
  doctest LapsusAgent

  test "greets the world" do
    assert LapsusAgent.hello() == :world
  end
end
