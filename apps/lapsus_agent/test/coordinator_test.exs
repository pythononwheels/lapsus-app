defmodule LapsusAgent.CoordinatorTest do
  use ExUnit.Case, async: true

  alias LapsusAgent.Coordinator
  alias LapsusCore.Identity

  test "auth_uri embeds a signature verifiable against the peer_id" do
    id = Identity.generate()
    uri = Coordinator.auth_uri("ws://localhost:4000", id)

    assert String.starts_with?(uri, "ws://localhost:4000/peer/websocket?")

    params = uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["peer_id"] == id.peer_id

    {:ok, sig} = Base.decode64(params["sig"])
    assert Identity.verify(id.peer_id, "#{id.peer_id}:#{params["ts"]}", sig)
  end

  test "auth_uri rewrites an http base to ws" do
    id = Identity.generate()
    assert Coordinator.auth_uri("http://host:4000", id) =~ ~r"^ws://host:4000/"
  end
end
