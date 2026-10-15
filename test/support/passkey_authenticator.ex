defmodule Slipdock.PasskeyAuthenticator do
  @moduledoc """
  A software authenticator for the passkey tests (#828): a real P-256 key
  pair, and the WebAuthn responses a browser would hand back for it —
  `navigator.credentials.create()` and `.get()` — base64url-encoded the way
  the passkey hooks send them. Everything it makes goes through Wax's real
  checks, so a test that signs in with it has signed something.
  """

  import Bitwise

  alias Slipdock.Accounts.Passkeys

  # User present, user verified, attested credential data included.
  @up 0x01
  @uv 0x04
  @at 0x40

  defstruct [:key, :x, :y, :credential_id, sign_count: 0]

  def new(opts \\ []) do
    {:ECPrivateKey, _, _, _, <<4, x::binary-32, y::binary-32>>, _} =
      key = :public_key.generate_key({:namedCurve, :secp256r1})

    %__MODULE__{
      key: key,
      x: x,
      y: y,
      credential_id:
        Keyword.get_lazy(opts, :credential_id, fn -> :crypto.strong_rand_bytes(16) end),
      sign_count: Keyword.get(opts, :sign_count, 0)
    }
  end

  @doc """
  The answer to a registration challenge. `opts`: `:origin` and `:rp_id`
  (default the challenge's), `:type` (default `webauthn.create`), `:flags`.
  """
  def attest(%__MODULE__{} = a, %Wax.Challenge{} = challenge, opts \\ []) do
    rp_id = Keyword.get(opts, :rp_id, challenge.rp_id)
    flags = Keyword.get(opts, :flags, @up ||| @uv ||| @at)

    cose =
      CBOR.encode(%{1 => 2, 3 => -7, -1 => 1, -2 => bytes(a.x), -3 => bytes(a.y)})

    attested =
      <<0::128, byte_size(a.credential_id)::16>> <> a.credential_id <> cose

    auth_data = auth_data(rp_id, flags, a.sign_count) <> attested

    attestation =
      CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => bytes(auth_data)})

    %{
      "id" => Passkeys.encode(a.credential_id),
      "attestationObject" => Passkeys.encode(attestation),
      "clientDataJSON" =>
        Passkeys.encode(client_data(Keyword.get(opts, :type, "webauthn.create"), challenge, opts))
    }
  end

  @doc """
  The answer to a sign-in challenge, signed. `opts` as for `attest/3`, plus
  `:sign_count` and `:user_handle` (binary, or `nil` to leave it out).
  """
  def assert(%__MODULE__{} = a, %Wax.Challenge{} = challenge, opts \\ []) do
    rp_id = Keyword.get(opts, :rp_id, challenge.rp_id)
    flags = Keyword.get(opts, :flags, @up ||| @uv)
    auth_data = auth_data(rp_id, flags, Keyword.get(opts, :sign_count, a.sign_count))
    client_data = client_data(Keyword.get(opts, :type, "webauthn.get"), challenge, opts)

    signature =
      :public_key.sign(auth_data <> :crypto.hash(:sha256, client_data), :sha256, a.key)

    response = %{
      "id" => Passkeys.encode(a.credential_id),
      "authenticatorData" => Passkeys.encode(auth_data),
      "signature" => Passkeys.encode(signature),
      "clientDataJSON" => Passkeys.encode(client_data)
    }

    case Keyword.fetch(opts, :user_handle) do
      {:ok, nil} -> response
      {:ok, handle} -> Map.put(response, "userHandle", Passkeys.encode(handle))
      :error -> response
    end
  end

  @doc "Flags for a response whose user was present but not verified."
  def present_only, do: @up
  def present_only_attested, do: @up ||| @at

  defp auth_data(rp_id, flags, sign_count),
    do: :crypto.hash(:sha256, rp_id) <> <<flags, sign_count::32>>

  defp client_data(type, challenge, opts) do
    Jason.encode!(%{
      type: type,
      challenge: Keyword.get(opts, :challenge_bytes, challenge.bytes) |> Passkeys.encode(),
      origin: Keyword.get(opts, :origin, challenge.origin),
      crossOrigin: false
    })
  end

  defp bytes(value), do: %CBOR.Tag{tag: :bytes, value: value}
end
