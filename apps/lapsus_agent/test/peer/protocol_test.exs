defmodule LapsusAgent.Peer.ProtocolTest do
  use ExUnit.Case, async: true

  alias LapsusAgent.Engine.Result
  alias LapsusAgent.Peer.Protocol

  test "request round-trips through encode/decode" do
    frame = Protocol.encode_request("r1", "gemma", "hi", %{"max_tokens" => 32})
    assert {:request, req} = Protocol.decode(IO.iodata_to_binary(frame))
    assert req.id == "r1"
    assert req.model == "gemma"
    assert req.prompt == "hi"
    assert req.options == %{"max_tokens" => 32}
  end

  test "ok response carries the result and token counts" do
    result = %Result{
      engine: :openai,
      model: "gemma",
      response: "hello",
      in_tokens: 5,
      out_tokens: 12,
      reasoning_tokens: 0,
      tokens_per_sec: 30.0
    }

    frame = Protocol.encode_response("r1", {:ok, result})
    assert {:response, resp} = Protocol.decode(IO.iodata_to_binary(frame))
    assert resp["ok"] == true
    assert resp["result"]["out_tokens"] == 12
    assert resp["result"]["response"] == "hello"
  end

  test "error response is encoded" do
    frame = Protocol.encode_response("r1", {:error, :boom})
    assert {:response, resp} = Protocol.decode(IO.iodata_to_binary(frame))
    assert resp["ok"] == false
    assert resp["error"] =~ "boom"
  end

  test "engine_opts drops nils and maps known keys" do
    opts = Protocol.engine_opts(%{"max_tokens" => 64, "temperature" => 0})
    assert opts[:max_tokens] == 64
    assert opts[:temperature] == 0
    refute Keyword.has_key?(opts, :system)
  end

  test "engine_opts allow-lists keys — tool/function fields are never forwarded" do
    opts =
      Protocol.engine_opts(%{
        "max_tokens" => 64,
        "tools" => [%{"type" => "function", "function" => %{"name" => "read_file"}}],
        "functions" => [%{"name" => "exec"}],
        "tool_choice" => "auto",
        "evil" => "rm -rf /"
      })

    assert opts[:max_tokens] == 64
    refute Keyword.has_key?(opts, :tools)
    refute Keyword.has_key?(opts, :functions)
    refute Keyword.has_key?(opts, :tool_choice)
    refute Keyword.has_key?(opts, :evil)
    # only the documented allow-list keys survive
    assert Enum.all?(Keyword.keys(opts), &(&1 in [:max_tokens, :temperature, :system, :options, :format]))
  end

  test "decode rejects garbage" do
    assert {:error, _} = Protocol.decode("not json")
  end
end
