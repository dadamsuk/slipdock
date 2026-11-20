defmodule Slipdock.Intent do
  @moduledoc """
  A card's text signed by its owner with a passkey (#3532; spike W-2910).

  The root board's owner, and only the owner, signs a card's title,
  description and bar from the card. What is signed is `canonical/1`: a
  versioned, length-prefixed text of the server's origin, the card's id,
  when it was signed, and the three fields byte for byte. Its SHA-256 is the
  WebAuthn challenge, so the browser's assertion signs
  `authenticatorData || SHA-256(clientDataJSON)` with `clientDataJSON`
  carrying that hash. A machine that pins the owner's keys
  (`Passkeys.public_keys/1`) checks the same bytes itself; the runner daemon
  encodes them the same way, and both sides test against one vector
  (`daemon/internal/intent/testdata/canonical-v1.json`).

  The card keeps the assertion, when it was signed and the SHA-256 of the
  canonical text. `state/1` compares that hash with the card's text now, so
  an edit by any path reads as unsigned; `Boards.Cards` also drops the
  assertion when the title, description or bar changes (`unsign/1`).

  The job's runner, and only it, fetches the signed fields and the
  assertion uncut (`for_job/2`): the prompt cuts long text, so the daemon
  can't take the text from it.

  A signature makes the top trust tier need the owner's tap. It doesn't
  protect against a compromised server, which serves the page that asks for
  the tap (W-2910, *The answer*).
  """

  import Ecto.Query

  alias Slipdock.Accounts.{Passkey, Passkeys, User}
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Runners.{Job, Runner}
  alias Slipdock.{Boards, Policy, Repo}

  require Logger

  @version "slipdock-intent-v1"
  # As long as a sign-in's: long enough to find a phone and unlock it.
  @timeout_seconds 300

  @doc "The first line of the canonical text; a new encoding is a new version."
  def version, do: @version

  @doc """
  The exact bytes whose SHA-256 is the challenge. `fields` has `:origin`
  (`https://slipdock.example.com`), `:card_id`, `:signed_at` (a UTC
  `DateTime`, written to the second), `:title`, `:description` and `:bar`
  (nil is empty). Each field is its name, a space, its length in bytes, a
  newline, its bytes and a newline; nothing is normalised.
  """
  @spec canonical(map()) :: binary()
  def canonical(fields) do
    [
      @version,
      "\n",
      field("origin", fields.origin),
      field("card", Integer.to_string(fields.card_id)),
      field("signed-at", timestamp(fields.signed_at)),
      field("title", fields.title),
      field("description", fields.description),
      field("bar", fields.bar)
    ]
    |> IO.iodata_to_binary()
  end

  defp field(name, value) do
    value = value || ""
    [name, " ", Integer.to_string(byte_size(value)), "\n", value, "\n"]
  end

  defp timestamp(%DateTime{} = at),
    do:
      at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc "The WebAuthn challenge for `fields`: SHA-256 of `canonical/1`."
  @spec challenge(map()) :: binary()
  def challenge(fields), do: :crypto.hash(:sha256, canonical(fields))

  @doc "A card's signed fields as `canonical/1` takes them, at `origin` and `signed_at`."
  @spec fields(Card.t(), String.t(), DateTime.t()) :: map()
  def fields(%Card{} = card, origin, %DateTime{} = signed_at) do
    %{
      origin: origin,
      card_id: card.id,
      signed_at: DateTime.truncate(signed_at, :second),
      title: card.title,
      description: card.description,
      bar: card.bar
    }
  end

  @doc """
  Where a card's signature stands: `:unsigned` (never signed),
  `{:signed, signed_at}`, or `:edited` (signed once, and the title,
  description or bar has changed since, by whatever path).
  """
  @spec state(Card.t()) :: :unsigned | :edited | {:signed, DateTime.t()}
  def state(%Card{signature: %{"origin" => origin}, signed_at: %DateTime{} = at} = card)
      when is_binary(origin) do
    if current?(card, origin, at), do: {:signed, at}, else: :edited
  end

  # An edit through `Boards.Cards` drops the assertion and keeps when it was
  # signed, so the card can say it was edited since.
  def state(%Card{signed_at: %DateTime{}}), do: :edited
  def state(%Card{}), do: :unsigned

  defp current?(card, origin, at),
    do: is_binary(card.signed_hash) and card.signed_hash == challenge(fields(card, origin, at))

  @doc """
  Drops the signature on a card changeset that changes its title,
  description or bar (`Boards.Cards`, beside `TrustTier.track/4`). When it
  was signed is kept, so the card reads `:edited` until it is signed again.
  """
  @spec unsign(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def unsign(%Ecto.Changeset{data: %Card{}} = changeset) do
    if Enum.any?([:title, :description, :bar], &Map.has_key?(changeset.changes, &1)),
      do: Ecto.Changeset.change(changeset, signature: nil, signed_hash: nil),
      else: changeset
  end

  @doc "Whether `user` is the owner of the root of `card`'s board tree: who may sign it."
  @spec signer?(User.t() | nil, Card.t()) :: boolean()
  def signer?(%User{id: id, disabled_at: nil}, %Card{board_id: board_id}) do
    case Repo.get(Board, board_id) do
      nil -> false
      board -> Board.root_owner_id(board) == id
    end
  end

  def signer?(_user, _card), do: false

  @doc """
  Starts signing `card` as `user` on `origin`: the Wax challenge to keep
  (its bytes are the card's challenge now), when it is signed, and the
  `publicKey` options for `navigator.credentials.get()`, which offer only
  the owner's own passkeys.
  """
  @spec signing_challenge(User.t(), Card.t(), String.t()) ::
          {:ok, Wax.Challenge.t(), DateTime.t(), map()}
          | {:error, :not_owner | :no_passkey | Policy.Refused.t()}
  def signing_challenge(%User{} = user, %Card{} = card, origin) do
    with :ok <- may_sign(user, card),
         [_ | _] = passkeys <- Passkeys.list(user) do
      signed_at = DateTime.utc_now(:second)
      hash = challenge(fields(card, origin, signed_at))

      wax =
        Wax.new_authentication_challenge(
          bytes: hash,
          origin: origin,
          rp_id: URI.parse(origin).host,
          user_verification: "required",
          timeout: @timeout_seconds
        )

      options = %{
        challenge: Passkeys.encode(hash),
        rpId: wax.rp_id,
        userVerification: "required",
        timeout: @timeout_seconds * 1000,
        allowCredentials:
          Enum.map(passkeys, &%{type: "public-key", id: Passkeys.encode(&1.credential_id)})
      }

      {:ok, wax, signed_at, options}
    else
      [] -> {:error, :no_passkey}
      {:error, _} = error -> error
    end
  end

  @doc """
  Finishes signing: checks that `card`'s text is still what the challenge
  was made from, then the browser's assertion against the owner's own
  passkeys, and keeps it on the card.

  `response` holds `id`, `authenticatorData`, `signature` and
  `clientDataJSON` (base64url), as `navigator.credentials.get()` gave them.
  A card edited since the challenge is `:changed`; an assertion over
  anything else, or by a passkey that isn't the owner's, is `:invalid`.
  """
  @spec sign(User.t(), Card.t(), Wax.Challenge.t() | nil, DateTime.t() | nil, map()) ::
          {:ok, Card.t()}
          | {:error, :no_challenge | :not_owner | :changed | :invalid | Policy.Refused.t()}
  def sign(user, card, challenge, signed_at, response)

  def sign(_user, _card, nil, _signed_at, _response), do: {:error, :no_challenge}
  def sign(_user, _card, _challenge, nil, _response), do: {:error, :no_challenge}

  def sign(
        %User{} = user,
        %Card{} = card,
        %Wax.Challenge{type: :authentication} = wax,
        %DateTime{} = signed_at,
        response
      ) do
    card = Repo.get(Card, card.id) || card

    with :ok <- may_sign(user, card),
         :ok <- same_text(card, wax, signed_at),
         {:ok, assertion} <- check(user, wax, response) do
      keep(card, user, wax, signed_at, assertion)
    end
  end

  def sign(_user, _card, _challenge, _signed_at, _response), do: {:error, :invalid}

  defp may_sign(user, card) do
    with :ok <- Policy.authorize(:sign_card, card) do
      if signer?(user, card), do: :ok, else: {:error, :not_owner}
    end
  end

  # The challenge was the card's text when it was asked for. Text changed
  # since (by anyone) is not what the owner was shown, so it is refused.
  defp same_text(card, wax, signed_at) do
    if challenge(fields(card, wax.origin, signed_at)) == wax.bytes,
      do: :ok,
      else: {:error, :changed}
  end

  defp check(user, wax, response) do
    with {:ok, credential_id} <- decode(response, "id"),
         {:ok, auth_data} <- decode(response, "authenticatorData"),
         {:ok, signature} <- decode(response, "signature"),
         {:ok, client_data} <- decode(response, "clientDataJSON"),
         %Passkey{} = passkey <- own_passkey(user, credential_id),
         {:ok, _auth_data} <-
           Wax.authenticate(credential_id, auth_data, signature, client_data, wax, [
             {credential_id, Passkey.cose_key(passkey)}
           ]) do
      {:ok,
       %{
         "credential_id" => Passkeys.encode(credential_id),
         "authenticator_data" => Passkeys.encode(auth_data),
         "client_data_json" => Passkeys.encode(client_data),
         "signature" => Passkeys.encode(signature),
         "passkey_id" => passkey.id
       }}
    else
      {:error, %{__exception__: true} = reason} ->
        Logger.info("card signature check failed: #{Exception.message(reason)}")
        {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  end

  defp own_passkey(%User{id: user_id}, credential_id) do
    Repo.one(
      from(p in Passkey, where: p.credential_id == ^credential_id and p.user_id == ^user_id)
    )
  end

  defp decode(response, key) do
    case Passkeys.decode(response[key]) do
      {:ok, bytes} when bytes != "" -> {:ok, bytes}
      _ -> {:error, :invalid}
    end
  end

  defp keep(card, user, wax, signed_at, assertion) do
    signature =
      Map.merge(assertion, %{
        "origin" => wax.origin,
        "rp_id" => wax.rp_id,
        "signed_by_id" => user.id
      })

    card
    |> Ecto.Changeset.change(signature: signature, signed_at: signed_at, signed_hash: wax.bytes)
    |> Repo.update()
    |> Boards.Shared.tap_ok(fn updated ->
      Boards.ActivityLog.log(
        Repo,
        updated.board_id,
        updated.id,
        "card",
        "signed the card's title, description and bar with a passkey"
      )

      Boards.PubSub.broadcast(updated.board_id)
    end)
  end

  @doc """
  The signed intent of a job, for the job's own runner while it holds the
  job (claimed or running): `{:ok, map}` with `signed: true`, the version,
  origin, card id, signed-at and the three fields uncut, and the assertion
  (base64url); or `signed: false` and the card's `state` (`unsigned` or
  `edited`). Any other runner's job, a finished one or none is
  `{:error, :not_found}`.
  """
  @spec for_job(Runner.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def for_job(%Runner{id: runner_id}, job_id) do
    with {id, ""} <- Integer.parse(to_string(job_id)),
         %Job{runner_id: ^runner_id, status: status} = job when status in ~w(claimed running) <-
           Repo.get(Job, id) do
      {:ok, intent(job.card_id && Repo.get(Card, job.card_id))}
    else
      _ -> {:error, :not_found}
    end
  end

  defp intent(nil), do: %{signed: false, state: "unsigned"}

  defp intent(%Card{} = card) do
    case state(card) do
      {:signed, at} ->
        f = fields(card, card.signature["origin"], at)
        sig = card.signature

        %{
          signed: true,
          version: @version,
          origin: f.origin,
          rp_id: sig["rp_id"],
          card_id: card.id,
          signed_at: timestamp(at),
          title: f.title || "",
          description: f.description || "",
          bar: f.bar || "",
          challenge: Passkeys.encode(card.signed_hash),
          assertion: %{
            credential_id: sig["credential_id"],
            authenticator_data: sig["authenticator_data"],
            client_data_json: sig["client_data_json"],
            signature: sig["signature"]
          }
        }

      other ->
        %{signed: false, state: Atom.to_string(other)}
    end
  end

  @doc """
  The owner of `runner`'s board tree's passkeys as public keys to pin
  (`Passkeys.public_keys/1`), with the origin and rp id they sign for: what
  `slipdock-runner trust-owner` shows the person at the machine.
  """
  @spec owner_keys(Runner.t(), String.t()) :: map()
  def owner_keys(%Runner{board_id: board_id}, origin) do
    owner =
      with %Board{} = board <- board_id && Repo.get(Board, board_id),
           id when is_integer(id) <- Board.root_owner_id(board),
           do: Repo.get(User, id)

    keys = if match?(%User{disabled_at: nil}, owner), do: Passkeys.public_keys(owner), else: []

    %{
      origin: origin,
      rp_id: URI.parse(origin).host,
      owner_id: owner && owner.id,
      keys: Enum.map(keys, &Map.drop(&1, [:id]))
    }
  end
end
