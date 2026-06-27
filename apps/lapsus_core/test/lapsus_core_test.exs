defmodule LapsusCoreTest do
  use ExUnit.Case
  doctest LapsusCore

  test "greets the world" do
    assert LapsusCore.hello() == :world
  end
end
