defmodule LapsusCore.IdentityTest do
  use ExUnit.Case, async: true

  alias LapsusCore.Identity

  test "generates a keypair with a derivable peer_id" do
    id = Identity.generate()
    assert byte_size(id.public_key) == 32
    assert byte_size(id.private_key) == 32
    assert String.starts_with?(id.peer_id, "lps_")
    assert {:ok, id.public_key} == Identity.public_key_from_peer_id(id.peer_id)
  end

  test "peer_ids are unique per identity" do
    refute Identity.generate().peer_id == Identity.generate().peer_id
  end

  test "signs and verifies a message" do
    id = Identity.generate()
    msg = "join request: #{id.peer_id}"
    sig = Identity.sign(id, msg)

    assert Identity.verify(id, msg, sig)
    # Verifiable from the peer_id alone (public key is embedded).
    assert Identity.verify(id.peer_id, msg, sig)
  end

  test "rejects a tampered message" do
    id = Identity.generate()
    sig = Identity.sign(id, "original")
    refute Identity.verify(id, "tampered", sig)
  end

  test "rejects a signature from another identity" do
    a = Identity.generate()
    b = Identity.generate()
    sig = Identity.sign(a, "hello")
    refute Identity.verify(b, "hello", sig)
  end

  test "verify returns false for a malformed peer_id" do
    id = Identity.generate()
    sig = Identity.sign(id, "hello")
    refute Identity.verify("lps_not-valid-base32", "hello", sig)
  end

  test "save!/load! round-trips an identity", %{test: test} do
    id = Identity.generate()
    path = Path.join(System.tmp_dir!(), "lapsus_id_#{test}.key")
    on_exit(fn -> File.rm(path) end)

    assert :ok == Identity.save!(id, path)
    loaded = Identity.load!(path)

    assert loaded.peer_id == id.peer_id
    assert loaded.public_key == id.public_key
    assert loaded.private_key == id.private_key
  end

  test "load_or_create! creates then loads the same identity", %{test: test} do
    path = Path.join(System.tmp_dir!(), "lapsus_loc_#{test}.key")
    on_exit(fn -> File.rm(path) end)

    created = Identity.load_or_create!(path)
    reloaded = Identity.load_or_create!(path)
    assert created.peer_id == reloaded.peer_id
  end
end
