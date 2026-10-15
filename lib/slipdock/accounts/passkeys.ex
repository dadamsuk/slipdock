defmodule Slipdock.Accounts.Passkeys do
  @moduledoc """
  Passkeys (#828): signing in with a WebAuthn credential instead of an emailed
  link. The link and the code still work; a passkey is a faster door to the
  same account, added from the account page by somebody already signed in.

  Each ceremony is two halves with the browser in between. The first half
  makes a `Wax.Challenge` and the options `navigator.credentials` needs; the
  caller keeps the challenge (the web layer puts it in the session, so it is
  used once and only by the browser that asked) and hands it back with the
  browser's answer to the second half, which checks it.

  What is accepted:

  - **No attestation.** The server does not care which make of authenticator
    it is, only that the same one comes back; asking would turn away most
    synced passkeys for no gain.
  - **User verification required.** A passkey replaces the email *and* the
    code, so whatever unlocks it (a fingerprint, a PIN) has to have been used.
  - **Discoverable credentials.** Signing in starts with no email typed: the
    authenticator offers the accounts it holds for this site, and the
    credential id it answers with says whose passkey it is.

  Binaries cross to the browser as unpadded base64url, the encoding WebAuthn's
  own JSON forms use.
  """
  import Ecto.Query
  require Logger

  alias Slipdock.Accounts.{Passkey, User}
  alias Slipdock.Repo

  # A challenge is good for this long. Long enough to find a phone and unlock
  # it, short enough that a stale page is not a standing invitation.
  @timeout_seconds 300
  # Enough for every device anybody owns, with room to spare; a cap stops one
  # account filling a table.
  @max_per_user 20
  # ES256, EdDSA, RS256: what every current authenticator can do, in the
  # order the browser should prefer them.
  @algorithms [-7, -8, -257]

  @doc "How many passkeys one account may have."
  def max_per_user, do: @max_per_user

  @doc "The account's passkeys, oldest first."
  @spec list(User.t()) :: [Passkey.t()]
  def list(%User{id: user_id}) do
    Repo.all(from(p in Passkey, where: p.user_id == ^user_id, order_by: [asc: p.id]))
  end

  @doc "Removes one of the account's passkeys. Another person's id is `:not_found`."
  @spec delete(User.t(), integer()) :: :ok | {:error, :not_found}
  def delete(%User{id: user_id}, id) do
    case Repo.delete_all(from(p in Passkey, where: p.id == ^id and p.user_id == ^user_id)) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  @doc """
  Starts adding a passkey to `user`'s account. `origin` is the address the
  browser is on (`https://slipdock.example.com`); the passkey belongs to that
  host and works nowhere else.

  Returns the challenge to keep and the `publicKey` options for
  `navigator.credentials.create()`.
  """
  @spec registration_challenge(User.t(), String.t()) :: {Wax.Challenge.t(), map()}
  def registration_challenge(%User{} = user, origin) do
    challenge =
      Wax.new_registration_challenge(
        origin: origin,
        rp_id: host(origin),
        attestation: "none",
        user_verification: "required",
        timeout: @timeout_seconds
      )

    options = %{
      challenge: encode(challenge.bytes),
      rp: %{id: challenge.rp_id, name: "Slipdock"},
      user: %{
        id: encode(user_handle(user)),
        name: user.email,
        displayName: User.display_name(user)
      },
      pubKeyCredParams: Enum.map(@algorithms, &%{type: "public-key", alg: &1}),
      authenticatorSelection: %{
        residentKey: "required",
        requireResidentKey: true,
        userVerification: "required"
      },
      attestation: "none",
      timeout: @timeout_seconds * 1000,
      # The authenticators already added: the browser says "already
      # registered" instead of making a second credential on the same one.
      excludeCredentials:
        Enum.map(list(user), &%{type: "public-key", id: encode(&1.credential_id)})
    }

    {challenge, options}
  end

  @doc """
  Finishes adding a passkey: checks the browser's answer against the
  challenge from `registration_challenge/2` and stores the credential.

  `response` holds `attestationObject` and `clientDataJSON` (base64url), as
  the browser returned them; `name` is what the person called it.
  """
  @spec register(User.t(), Wax.Challenge.t() | nil, map(), String.t() | nil) ::
          {:ok, Passkey.t()}
          | {:error, :no_challenge | :invalid | :too_many | :already_added}
          | {:error, Ecto.Changeset.t()}
  def register(user, challenge, response, name)

  def register(_user, nil, _response, _name), do: {:error, :no_challenge}

  def register(%User{} = user, %Wax.Challenge{type: :attestation} = challenge, response, name) do
    with {:ok, attestation} <- decode_field(response, "attestationObject"),
         {:ok, client_data} <- decode_field(response, "clientDataJSON"),
         :ok <- room_for_another(user),
         {:ok, {auth_data, _attestation}} <-
           verify(Wax.register(attestation, client_data, challenge)),
         :ok <- spend(challenge) do
      credential = auth_data.attested_credential_data

      %Passkey{}
      |> Passkey.create_changeset(%{
        user_id: user.id,
        credential_id: credential.credential_id,
        public_key: :erlang.term_to_binary(credential.credential_public_key),
        sign_count: auth_data.sign_count,
        aaguid: credential.aaguid,
        name: default_name(name, user)
      })
      |> Repo.insert()
      |> case do
        {:ok, passkey} ->
          {:ok, passkey}

        {:error, %Ecto.Changeset{errors: errors} = changeset} ->
          if Keyword.has_key?(errors, :credential_id),
            do: {:error, :already_added},
            else: {:error, changeset}
      end
    end
  end

  def register(_user, _wrong_kind_of_challenge, _response, _name), do: {:error, :invalid}

  @doc """
  Starts a passkey sign-in. Nobody is named: the authenticator offers the
  accounts it has for this host. Returns the challenge to keep and the
  `publicKey` options for `navigator.credentials.get()`.
  """
  @spec authentication_challenge(String.t()) :: {Wax.Challenge.t(), map()}
  def authentication_challenge(origin) do
    challenge =
      Wax.new_authentication_challenge(
        origin: origin,
        rp_id: host(origin),
        user_verification: "required",
        timeout: @timeout_seconds
      )

    options = %{
      challenge: encode(challenge.bytes),
      rpId: challenge.rp_id,
      userVerification: "required",
      timeout: @timeout_seconds * 1000
    }

    {challenge, options}
  end

  @doc """
  Finishes a passkey sign-in: finds the passkey the browser answered with,
  checks its signature over the challenge, and hands back whose it is.

  `response` holds `id` (the credential id), `authenticatorData`,
  `signature`, `clientDataJSON` and, from a discoverable credential,
  `userHandle` — all base64url.

  A disabled account is `:invalid`, like a passkey that does not exist: the
  sign-in page says the same thing for both. A signature count that went
  backwards means the authenticator has been copied, and is refused too.
  """
  @spec authenticate(Wax.Challenge.t() | nil, map()) ::
          {:ok, User.t()} | {:error, :no_challenge | :invalid | :cloned}
  def authenticate(nil, _response), do: {:error, :no_challenge}

  def authenticate(%Wax.Challenge{type: :authentication} = challenge, response) do
    with {:ok, credential_id} <- decode_field(response, "id"),
         {:ok, auth_data} <- decode_field(response, "authenticatorData"),
         {:ok, signature} <- decode_field(response, "signature"),
         {:ok, client_data} <- decode_field(response, "clientDataJSON"),
         %Passkey{user: %User{disabled_at: nil} = user} = passkey <- find(credential_id),
         :ok <- same_user(response, user),
         {:ok, checked} <-
           verify(
             Wax.authenticate(credential_id, auth_data, signature, client_data, challenge, [
               {credential_id, Passkey.cose_key(passkey)}
             ])
           ),
         :ok <- spend(challenge),
         :ok <- counter_moved_on(passkey, checked.sign_count) do
      passkey
      |> Ecto.Changeset.change(
        sign_count: checked.sign_count,
        last_used_at: DateTime.utc_now(:second)
      )
      |> Repo.update!()

      {:ok, user}
    else
      {:error, :cloned} = error -> error
      _ -> {:error, :invalid}
    end
  end

  def authenticate(_wrong_kind_of_challenge, _response), do: {:error, :invalid}

  # Each challenge answers once. Only a verified answer spends one, so a
  # garbled try does not stop the real one; a second verified answer to the
  # same challenge is a replay, and is refused.
  defp spend(%Wax.Challenge{bytes: bytes, issued_at: issued_at, timeout: timeout}) do
    now = DateTime.utc_now(:second)
    Repo.delete_all(from(s in "passkey_spent_challenges", where: s.expires_at < ^now))

    expires_at = DateTime.from_unix!(issued_at + timeout) |> DateTime.truncate(:second)

    case Repo.insert_all(
           "passkey_spent_challenges",
           [%{digest: :crypto.hash(:sha256, bytes), expires_at: expires_at}],
           on_conflict: :nothing
         ) do
      {1, _} ->
        :ok

      {0, _} ->
        Logger.warning("passkey challenge answered twice; refusing the replay")
        {:error, :invalid}
    end
  end

  defp find(credential_id),
    do: Repo.one(from(p in Passkey, where: p.credential_id == ^credential_id, preload: :user))

  # A discoverable credential says whose it is. That has to be the account
  # the credential id belongs to; an authenticator that disagrees is lying.
  defp same_user(%{"userHandle" => handle}, user) when is_binary(handle) and handle != "" do
    case decode(handle) do
      {:ok, bytes} -> if bytes == user_handle(user), do: :ok, else: :error
      :error -> :error
    end
  end

  defp same_user(_response, _user), do: :ok

  # Synced passkeys always say 0, and that is fine. A counter that has
  # counted must keep going up: a lower one is a copy of the authenticator.
  defp counter_moved_on(%Passkey{sign_count: 0}, _new), do: :ok
  defp counter_moved_on(%Passkey{sign_count: old}, new) when new > old, do: :ok

  defp counter_moved_on(passkey, new) do
    Logger.warning(
      "passkey #{passkey.id} of user #{passkey.user_id}: sign count #{new} " <>
        "is not above #{passkey.sign_count}; refusing it as a possible clone"
    )

    {:error, :cloned}
  end

  defp room_for_another(%User{id: user_id}) do
    count = Repo.aggregate(from(p in Passkey, where: p.user_id == ^user_id), :count)
    if count < @max_per_user, do: :ok, else: {:error, :too_many}
  end

  defp verify({:ok, _} = ok), do: ok

  defp verify({:error, reason}) do
    Logger.info("passkey check failed: #{Exception.message(reason)}")
    {:error, :invalid}
  end

  defp default_name(name, user) do
    case name |> to_string() |> String.trim() do
      "" -> "Passkey #{length(list(user)) + 1}"
      name -> String.slice(name, 0, Passkey.name_max())
    end
  end

  @doc """
  The WebAuthn user handle for an account: opaque bytes the authenticator
  stores with the credential and hands back at sign-in. The account id, not
  the email, so the handle says nothing about the person.
  """
  @spec user_handle(User.t()) :: binary()
  def user_handle(%User{id: id}), do: <<id::unsigned-big-64>>

  @doc "Unpadded base64url, as WebAuthn's JSON uses."
  def encode(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "Reads base64url, padded or not."
  def decode(string) when is_binary(string), do: Base.url_decode64(string, padding: false)
  def decode(_), do: :error

  defp decode_field(response, key) do
    case decode(response[key]) do
      {:ok, bytes} when bytes != "" -> {:ok, bytes}
      _ -> {:error, :invalid}
    end
  end

  defp host(origin), do: URI.parse(origin).host
end
