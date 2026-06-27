defmodule LapsusCore.Identity do
  @moduledoc """
  Cryptographic peer identity for LAPSUS — an Ed25519 keypair.

  Every participant *is* their public key. There is no account server: the
  coordinator ties Compute-Credits and reputation to a `peer_id`, and any message
  a peer sends is signed so the receiver can verify it (see `doc/tech/design.md`
  §2.1, §3).

  ## Peer ID

  The `peer_id` is the **public key itself**, Base32-encoded (lowercase, no
  padding) with a `lps_` prefix. Because the key is embedded, anyone can recover
  it from the id and verify signatures without a prior key exchange — same idea as
  libp2p's Ed25519 peer ids.

      lps_<base32(public_key)>

  ## Persistence

  The agent needs a stable identity across restarts. `save!/2` writes the keypair
  to a file with `0600` permissions; `load!/1` reads it back. The file holds
  Base64 of `private_seed <> public_key` (64 bytes) — keep it secret.
  """

  @enforce_keys [:public_key, :private_key, :peer_id]
  defstruct [:public_key, :private_key, :peer_id]

  @type t :: %__MODULE__{
          public_key: binary(),
          private_key: binary(),
          peer_id: String.t()
        }

  @prefix "lps_"
  @pub_size 32
  @priv_size 32

  @doc "Generate a fresh Ed25519 identity."
  @spec generate() :: t()
  def generate do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    %__MODULE__{
      public_key: public_key,
      private_key: private_key,
      peer_id: peer_id_from_public_key(public_key)
    }
  end

  @doc "Derive the `peer_id` string from a raw public key."
  @spec peer_id_from_public_key(binary()) :: String.t()
  def peer_id_from_public_key(public_key) when byte_size(public_key) == @pub_size do
    @prefix <> Base.encode32(public_key, case: :lower, padding: false)
  end

  @doc "Recover the raw public key from a `peer_id`."
  @spec public_key_from_peer_id(String.t()) :: {:ok, binary()} | :error
  def public_key_from_peer_id(@prefix <> encoded) do
    case Base.decode32(encoded, case: :lower, padding: false) do
      {:ok, key} when byte_size(key) == @pub_size -> {:ok, key}
      _ -> :error
    end
  end

  def public_key_from_peer_id(_), do: :error

  @doc "Sign a message with the identity's (or a raw) private key."
  @spec sign(t() | binary(), iodata()) :: binary()
  def sign(%__MODULE__{private_key: private_key}, message), do: sign(private_key, message)

  def sign(private_key, message) when is_binary(private_key) do
    :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
  end

  @doc """
  Verify a signature against a signer, given as an `Identity`, a `peer_id` string,
  or a raw public key. Returns `false` on a malformed `peer_id`.
  """
  @spec verify(t() | String.t() | binary(), iodata(), binary()) :: boolean()
  def verify(%__MODULE__{public_key: public_key}, message, signature),
    do: verify(public_key, message, signature)

  def verify(@prefix <> _ = peer_id, message, signature) do
    case public_key_from_peer_id(peer_id) do
      {:ok, public_key} -> verify(public_key, message, signature)
      :error -> false
    end
  end

  def verify(public_key, message, signature)
      when is_binary(public_key) and byte_size(public_key) == @pub_size do
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  end

  @doc "Persist the identity to `path` (file mode `0600`)."
  @spec save!(t(), Path.t()) :: :ok
  def save!(%__MODULE__{private_key: priv, public_key: pub}, path)
      when byte_size(priv) == @priv_size and byte_size(pub) == @pub_size do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Base.encode64(priv <> pub))
    File.chmod!(path, 0o600)
    :ok
  end

  @doc "Load an identity previously written by `save!/2`."
  @spec load!(Path.t()) :: t()
  def load!(path) do
    <<priv::binary-size(@priv_size), pub::binary-size(@pub_size)>> =
      path |> File.read!() |> String.trim() |> Base.decode64!()

    %__MODULE__{public_key: pub, private_key: priv, peer_id: peer_id_from_public_key(pub)}
  end

  @doc """
  Load the identity from `path`, generating and persisting a fresh one if the file
  does not exist. The agent's startup path to a stable identity.
  """
  @spec load_or_create!(Path.t()) :: t()
  def load_or_create!(path) do
    if File.exists?(path) do
      load!(path)
    else
      identity = generate()
      save!(identity, path)
      identity
    end
  end
end
