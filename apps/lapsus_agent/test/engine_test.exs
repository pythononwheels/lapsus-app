defmodule LapsusAgent.EngineTest do
  use ExUnit.Case, async: true

  alias LapsusAgent.Engine

  test "built-in engines resolve to adapter modules" do
    assert Engine.engines()[:ollama] == LapsusAgent.Engine.Ollama
    assert Engine.engines()[:openai] == LapsusAgent.Engine.OpenAICompat
  end

  test "adapters implement the Engine behaviour" do
    for mod <- [LapsusAgent.Engine.Ollama, LapsusAgent.Engine.OpenAICompat] do
      behaviours =
        mod.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert LapsusAgent.Engine in behaviours
    end
  end
end
