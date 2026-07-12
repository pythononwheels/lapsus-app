defmodule LapsusAgent.OpenAIRemoteTest do
  use ExUnit.Case, async: true

  alias LapsusAgent.Engine
  alias LapsusAgent.Engine.OpenAIRemote
  alias LapsusAgent.Settings

  test ":other is registered and implements the Engine behaviour" do
    assert Engine.engines()[:other] == OpenAIRemote

    behaviours =
      OpenAIRemote.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    assert Engine in behaviours
  end

  test "config accessors read from a Settings struct" do
    s = %Settings{
      engine: "other",
      api_base_url: "https://integrate.api.nvidia.com/v1",
      api_key: "nvapi-x",
      api_models: ["meta/llama-3.3-70b-instruct", "nvidia/nemotron"]
    }

    assert OpenAIRemote.base_url(s) == "https://integrate.api.nvidia.com/v1"
    assert OpenAIRemote.api_key(s) == "nvapi-x"
    assert OpenAIRemote.models(s) == ["meta/llama-3.3-70b-instruct", "nvidia/nemotron"]
  end

  test "blank config reads as nil (falls back to no base_url/key)" do
    s = %Settings{api_base_url: "", api_key: ""}
    # env may override in some environments; only assert the settings-blank path here
    if System.get_env("LAPSUS_API_BASE_URL") in [nil, ""], do: assert(OpenAIRemote.base_url(s) == nil)
    if System.get_env("LAPSUS_API_KEY") in [nil, ""], do: assert(OpenAIRemote.api_key(s) == nil)
  end

  test "Settings parses engine 'other', api fields and a comma/list model allowlist" do
    from_str =
      Settings.from_map(%{
        "engine" => "other",
        "api_base_url" => "  https://x/v1  ",
        "api_protocol" => "openai",
        "api_models" => "a/one, b/two ,, a/one"
      })

    assert from_str.engine == "other"
    assert from_str.api_base_url == "https://x/v1"
    assert from_str.api_protocol == "openai"
    # trimmed, de-duped, blanks dropped
    assert from_str.api_models == ["a/one", "b/two"]

    from_list = Settings.from_map(%{"api_models" => ["x", " y ", ""]})
    assert from_list.api_models == ["x", "y"]
  end

  test "Settings rejects unknown engine/protocol values (keeps default)" do
    assert Settings.from_map(%{"engine" => "bogus"}).engine == "auto"
    assert Settings.from_map(%{"api_protocol" => "anthropic"}).api_protocol == "openai"
  end
end
