defmodule Slipdock.IntentTest do
  @moduledoc """
  A card's text signed by its owner with a passkey (#3532): the canonical
  text against the vectors the daemon tests too, who may sign, what an edit
  does, what the job's runner may fetch, and the owner's keys as SPKI.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Intent, Repo, Runners}
  alias Slipdock.Accounts.Passkeys
  alias Slipdock.Boards.Card
  alias Slipdock.PasskeyAuthenticator, as: Authenticator

  @origin "https://slipdock.example.com"
  @vectors Path.expand("../../daemon/internal/intent/testdata/canonical-v1.json", __DIR__)

  setup do
    owner = user_fixture("intent-owner@example.com")
    board = board_fixture(%{"name" => "Signed"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Add a CSV export"})

    {:ok, card} =
      Boards.Cards.update_card(card, %{"description" => "Export it.", "bar" => "1. CSV"},
        by: owner
      )

    %{owner: owner, board: board, card: card, key: passkey_for(owner)}
  end

  defp passkey_for(user) do
    a = Authenticator.new()
    {challenge, _} = Passkeys.registration_challenge(user, @origin)
    {:ok, _} = Passkeys.register(user, challenge, Authenticator.attest(a, challenge), "Phone")
    a
  end

  defp sign(ctx, card \\ nil) do
    card = card || ctx.card
    {:ok, wax, at, _options} = Intent.signing_challenge(ctx.owner, card, @origin)
    Intent.sign(ctx.owner, card, wax, at, Authenticator.assert(ctx.key, wax))
  end

  describe "the canonical text" do
    test "matches the vectors the daemon's encoder is tested against, byte for byte" do
      %{"version" => version, "cases" => [_ | _] = cases} =
        @vectors |> File.read!() |> Jason.decode!()

      assert version == Intent.version()

      for v <- cases do
        {:ok, at, 0} = DateTime.from_iso8601(v["signed_at"])

        fields = %{
          origin: v["origin"],
          card_id: v["card_id"],
          signed_at: at,
          title: v["title"],
          description: v["description"],
          bar: v["bar"]
        }

        assert Base.encode64(Intent.canonical(fields)) == v["canonical_base64"], v["name"]
        assert Base.encode16(Intent.challenge(fields), case: :lower) == v["challenge_hex"]
      end
    end

    test "an empty field and a missing one are the same, and fields can't run together" do
      at = ~U[2026-11-20 05:00:00Z]
      base = %{origin: @origin, card_id: 1, signed_at: at, title: "a"}

      assert Intent.canonical(Map.merge(base, %{description: nil, bar: nil})) ==
               Intent.canonical(Map.merge(base, %{description: "", bar: ""}))

      refute Intent.canonical(Map.merge(base, %{description: "b\nbar 1\nc", bar: ""})) ==
               Intent.canonical(Map.merge(base, %{description: "b", bar: "c"}))
    end
  end

  describe "signing" do
    test "the owner signs: the assertion, signed_at and the hash are kept", ctx do
      assert {:ok, signed} = sign(ctx)
      card = Repo.get!(Card, ctx.card.id)

      assert {:signed, at} = Intent.state(card)
      assert at == signed.signed_at
      assert card.signed_hash == Intent.challenge(Intent.fields(card, @origin, at))
      assert card.signature["origin"] == @origin
      assert card.signature["signed_by_id"] == ctx.owner.id
      assert card.signature["credential_id"] == Passkeys.encode(ctx.key.credential_id)

      for k <- ~w(authenticator_data client_data_json signature),
          do: assert({:ok, <<_, _::binary>>} = Passkeys.decode(card.signature[k]))
    end

    test "someone else, even with write on the board and a passkey, is refused", ctx do
      member = user_fixture("intent-member@example.com")

      Repo.insert!(
        Slipdock.Access.Grant.changeset(%Slipdock.Access.Grant{}, %{
          level: "write",
          user_id: member.id,
          board_id: ctx.board.id
        })
      )

      member_key = passkey_for(member)
      refute Intent.signer?(member, ctx.card)
      assert {:error, :not_owner} = Intent.signing_challenge(member, ctx.card, @origin)

      # With the owner's own challenge in hand, the member's answer is refused.
      {:ok, wax, at, _} = Intent.signing_challenge(ctx.owner, ctx.card, @origin)

      assert {:error, :not_owner} =
               Intent.sign(member, ctx.card, wax, at, Authenticator.assert(member_key, wax))

      assert Intent.state(Repo.get!(Card, ctx.card.id)) == :unsigned
    end

    test "the owner's answer with somebody else's passkey is refused", ctx do
      other_key = passkey_for(user_fixture("intent-other@example.com"))
      {:ok, wax, at, _} = Intent.signing_challenge(ctx.owner, ctx.card, @origin)

      assert {:error, :invalid} =
               Intent.sign(ctx.owner, ctx.card, wax, at, Authenticator.assert(other_key, wax))

      # A key the owner has, made up for a credential id that is theirs.
      forged = Authenticator.new(credential_id: ctx.key.credential_id)

      assert {:error, :invalid} =
               Intent.sign(ctx.owner, ctx.card, wax, at, Authenticator.assert(forged, wax))

      assert Intent.state(Repo.get!(Card, ctx.card.id)) == :unsigned
    end

    test "an answer to another challenge is refused", ctx do
      {:ok, wax, at, _} = Intent.signing_challenge(ctx.owner, ctx.card, @origin)

      # A sign-in style challenge: random bytes, not the card's text.
      random = Authenticator.assert(ctx.key, wax, challenge_bytes: :crypto.strong_rand_bytes(32))
      assert {:error, :invalid} = Intent.sign(ctx.owner, ctx.card, wax, at, random)

      # Another card's text.
      other = card_fixture(hd(ctx.board.columns), %{"title" => "Something else"})
      {:ok, other_wax, _, _} = Intent.signing_challenge(ctx.owner, other, @origin)
      moved = Authenticator.assert(ctx.key, wax, challenge_bytes: other_wax.bytes)
      assert {:error, :invalid} = Intent.sign(ctx.owner, ctx.card, wax, at, moved)

      # A sign-in challenge kept as if it were the card's.
      {login, _} = Passkeys.authentication_challenge(@origin)

      assert {:error, :changed} =
               Intent.sign(ctx.owner, ctx.card, login, at, Authenticator.assert(ctx.key, login))

      # Unverified user, another origin.
      unverified = Authenticator.assert(ctx.key, wax, flags: Authenticator.present_only())
      assert {:error, :invalid} = Intent.sign(ctx.owner, ctx.card, wax, at, unverified)
      elsewhere = Authenticator.assert(ctx.key, wax, origin: "https://evil.example.net")
      assert {:error, :invalid} = Intent.sign(ctx.owner, ctx.card, wax, at, elsewhere)

      # The challenge's signed-at is part of the text: another one isn't it.
      assert {:error, :changed} =
               Intent.sign(
                 ctx.owner,
                 ctx.card,
                 wax,
                 DateTime.add(at, 1),
                 Authenticator.assert(ctx.key, wax)
               )

      assert Intent.state(Repo.get!(Card, ctx.card.id)) == :unsigned
    end

    test "text changed between the challenge and the answer is refused", ctx do
      {:ok, wax, at, _} = Intent.signing_challenge(ctx.owner, ctx.card, @origin)
      {:ok, _} = Boards.Cards.update_card(ctx.card, %{"bar" => "1. CSV; 2. JSON"}, by: ctx.owner)

      assert {:error, :changed} =
               Intent.sign(ctx.owner, ctx.card, wax, at, Authenticator.assert(ctx.key, wax))
    end

    test "a disabled owner is refused, with a challenge or an answer", ctx do
      {:ok, wax, at, _} = Intent.signing_challenge(ctx.owner, ctx.card, @origin)
      answer = Authenticator.assert(ctx.key, wax)
      disabled = disable!(ctx.owner)

      refute Intent.signer?(disabled, ctx.card)
      assert {:error, :not_owner} = Intent.signing_challenge(disabled, ctx.card, @origin)
      assert {:error, :not_owner} = Intent.sign(disabled, ctx.card, wax, at, answer)
      assert Intent.state(Repo.get!(Card, ctx.card.id)) == :unsigned
    end

    test "no challenge kept, or no passkey at all, says so", ctx do
      assert {:error, :no_challenge} = Intent.sign(ctx.owner, ctx.card, nil, nil, %{})

      bare = user_fixture("intent-bare@example.com")
      board = board_fixture(%{"name" => "Bare"}, owner: bare)
      card = card_fixture(hd(board.columns), %{"title" => "x"})
      assert {:error, :no_passkey} = Intent.signing_challenge(bare, card, @origin)
    end

    test "the options offer only the owner's passkeys, and the challenge is the text's hash",
         ctx do
      {:ok, wax, at, options} = Intent.signing_challenge(ctx.owner, ctx.card, @origin)

      assert options.challenge == Passkeys.encode(wax.bytes)
      assert wax.bytes == Intent.challenge(Intent.fields(ctx.card, @origin, at))
      assert options.userVerification == "required"
      assert options.rpId == "slipdock.example.com"

      assert options.allowCredentials == [
               %{type: "public-key", id: Passkeys.encode(ctx.key.credential_id)}
             ]
    end
  end

  describe "an edit" do
    test "to the title, description or bar unsigns the card, and it says so", ctx do
      for {field, value} <- [{"title", "New title"}, {"description", "New"}, {"bar", "1. new"}] do
        {:ok, _} = sign(ctx, Repo.get!(Card, ctx.card.id))
        assert {:signed, _} = Intent.state(Repo.get!(Card, ctx.card.id))

        {:ok, _} =
          Boards.Cards.update_card(Repo.get!(Card, ctx.card.id), %{field => value}, by: ctx.owner)

        card = Repo.get!(Card, ctx.card.id)
        assert Intent.state(card) == :edited, field
        assert card.signature == nil
        assert card.signed_hash == nil
      end
    end

    test "to anything else leaves it signed", ctx do
      {:ok, _} = sign(ctx)
      {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, ctx.card.id), %{"priority" => "high"})
      assert {:signed, _} = Intent.state(Repo.get!(Card, ctx.card.id))
    end

    test "by a path that writes the row straight away still reads as edited", ctx do
      {:ok, _} = sign(ctx)

      Repo.update_all(Ecto.Query.from(c in Card, where: c.id == ^ctx.card.id),
        set: [description: "Rewritten"]
      )

      assert Intent.state(Repo.get!(Card, ctx.card.id)) == :edited
    end
  end

  describe "the job's intent" do
    setup ctx do
      {:ok, runner, _token} =
        Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"}, ctx.owner)

      {:ok, other, _} =
        Runners.create_runner(ctx.board, %{"name" => "other", "pool" => "dev"}, ctx.owner)

      %{runner: runner, other: other}
    end

    defp claimed(ctx, card) do
      {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "Work on it"})
      assert %{id: id} = Runners.claim(ctx.runner, 0)
      assert id == job.id
      job
    end

    test "is the job's runner's, uncut, with the assertion", ctx do
      long = String.duplicate("A long description. ", 5_000)
      {:ok, card} = Boards.Cards.update_card(ctx.card, %{"description" => long}, by: ctx.owner)
      {:ok, _} = sign(ctx, card)
      job = claimed(ctx, card)

      assert {:ok, intent} = Intent.for_job(ctx.runner, job.id)
      assert intent.signed
      assert intent.description == long
      assert intent.title == "Add a CSV export"
      assert intent.bar == "1. CSV"
      assert intent.card_id == card.id

      {:ok, at, 0} = DateTime.from_iso8601(intent.signed_at)
      fields = Intent.fields(Repo.get!(Card, card.id), intent.origin, at)
      assert Passkeys.decode(intent.challenge) == {:ok, Intent.challenge(fields)}
      assert intent.assertion.credential_id == Passkeys.encode(ctx.key.credential_id)

      # The assertion verifies against the key the owner's keys list gives.
      [key] = Passkeys.public_keys(ctx.owner)
      assert verifies?(key, intent)
    end

    test "is nobody else's: another runner, or a job no longer held", ctx do
      {:ok, _} = sign(ctx)
      job = claimed(ctx, ctx.card)

      assert {:error, :not_found} = Intent.for_job(ctx.other, job.id)
      assert {:error, :not_found} = Intent.for_job(ctx.runner, "#{job.id}x")
      assert {:error, :not_found} = Intent.for_job(ctx.runner, job.id + 1_000_000)

      {:ok, _} = Runners.finish(ctx.runner, job.id, %{exit: "0", output: "done"})
      assert {:error, :not_found} = Intent.for_job(ctx.runner, job.id)
    end

    test "says unsigned, or edited, with no assertion", ctx do
      job = claimed(ctx, ctx.card)

      assert {:ok, %{signed: false, state: "unsigned"} = intent} =
               Intent.for_job(ctx.runner, job.id)

      refute Map.has_key?(intent, :assertion)

      {:ok, _} = sign(ctx)
      {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, ctx.card.id), %{"title" => "Changed"})
      assert {:ok, %{signed: false, state: "edited"}} = Intent.for_job(ctx.runner, job.id)
    end
  end

  describe "the owner's keys" do
    test "are SPKI DER with a fingerprint, for each algorithm offered", ctx do
      [key] = Passkeys.public_keys(ctx.owner)
      {:ok, der} = Passkeys.decode(key.spki)

      assert key.algorithm == -7

      assert key.fingerprint ==
               "sha256:" <> Base.encode16(:crypto.hash(:sha256, der), case: :lower)

      assert key.credential_id == Passkeys.encode(ctx.key.credential_id)

      assert {{:ECPoint, <<4, x::binary-32, y::binary-32>>}, _} =
               :public_key.pem_entry_decode({:SubjectPublicKeyInfo, der, :not_encrypted})

      assert {x, y} == {ctx.key.x, ctx.key.y}

      # Ed25519 and RSA, from the COSE keys a registration would store.
      {ed_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
      ed = cose_passkey(%{1 => 1, 3 => -8, -1 => 6, -2 => ed_pub})
      assert {:ok, -8, ed_der} = Passkeys.spki(ed)
      assert ed_der == Base.decode16!("302A300506032B6570032100") <> ed_pub

      rsa = :public_key.generate_key({:rsa, 2048, 65_537})
      n = :binary.encode_unsigned(elem(rsa, 2))
      e = :binary.encode_unsigned(elem(rsa, 3))

      assert {:ok, -257, rsa_der} =
               Passkeys.spki(cose_passkey(%{1 => 3, 3 => -257, -1 => n, -2 => e}))

      assert {:RSAPublicKey, _, 65_537} =
               :public_key.pem_entry_decode({:SubjectPublicKeyInfo, rsa_der, :not_encrypted})

      assert Passkeys.spki(cose_passkey(%{1 => 2, 3 => -35})) == :error
    end

    test "for a runner are its board tree's owner's, with the origin", ctx do
      {:ok, runner, _} =
        Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"}, ctx.owner)

      keys = Intent.owner_keys(runner, @origin)
      assert keys.origin == @origin
      assert keys.rp_id == "slipdock.example.com"
      assert keys.owner_id == ctx.owner.id
      assert [%{fingerprint: "sha256:" <> _, spki: _, credential_id: _}] = keys.keys
    end

    test "for a runner whose owner is disabled are none", ctx do
      {:ok, runner, _} =
        Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"}, ctx.owner)

      disable!(ctx.owner)

      keys = Intent.owner_keys(runner, @origin)
      assert keys.owner_id == ctx.owner.id
      assert keys.keys == []
    end
  end

  defp disable!(user) do
    user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp cose_passkey(cose),
    do: %Slipdock.Accounts.Passkey{public_key: :erlang.term_to_binary(cose)}

  # What the daemon will check (W-2910): the signature over
  # authenticatorData || SHA-256(clientDataJSON), with the pinned SPKI, and
  # the challenge in clientDataJSON the hash of the canonical text.
  defp verifies?(key, intent) do
    {:ok, der} = Passkeys.decode(key.spki)
    pub = :public_key.pem_entry_decode({:SubjectPublicKeyInfo, der, :not_encrypted})
    {:ok, auth} = Passkeys.decode(intent.assertion.authenticator_data)
    {:ok, client} = Passkeys.decode(intent.assertion.client_data_json)
    {:ok, sig} = Passkeys.decode(intent.assertion.signature)

    Jason.decode!(client)["challenge"] == intent.challenge and
      :public_key.verify(auth <> :crypto.hash(:sha256, client), :sha256, sig, pub)
  end
end
