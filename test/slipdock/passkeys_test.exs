defmodule Slipdock.PasskeysTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Accounts
  alias Slipdock.Accounts.{Passkey, Passkeys}
  alias Slipdock.PasskeyAuthenticator, as: Authenticator

  @origin "https://slipdock.example.com"

  setup do
    %{user: user_fixture(), authenticator: Authenticator.new()}
  end

  defp add(user, authenticator, name \\ "Laptop") do
    {challenge, _options} = Passkeys.registration_challenge(user, @origin)
    Passkeys.register(user, challenge, Authenticator.attest(authenticator, challenge), name)
  end

  defp sign_in(authenticator, opts \\ []) do
    {challenge, _options} = Passkeys.authentication_challenge(@origin)
    Passkeys.authenticate(challenge, Authenticator.assert(authenticator, challenge, opts))
  end

  describe "registration_challenge/2" do
    test "asks for a discoverable, verified passkey for this host, naming the account by id",
         %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      {challenge, options} = Passkeys.registration_challenge(user, @origin)

      assert challenge.rp_id == "slipdock.example.com"
      assert challenge.origin == @origin
      assert options.challenge == Passkeys.encode(challenge.bytes)
      assert options.rp.id == "slipdock.example.com"
      assert options.user.id == Passkeys.encode(<<user.id::64>>)
      assert options.user.name == user.email
      assert options.authenticatorSelection.residentKey == "required"
      assert options.authenticatorSelection.userVerification == "required"
      assert options.attestation == "none"
      assert Enum.map(options.pubKeyCredParams, & &1.alg) == [-7, -8, -257]
      # The authenticator already added is excluded, so it is not added twice.
      assert options.excludeCredentials == [
               %{type: "public-key", id: Passkeys.encode(a.credential_id)}
             ]
    end
  end

  describe "register/4" do
    test "keeps the credential, its key and its name", %{user: user, authenticator: a} do
      assert {:ok, %Passkey{} = passkey} = add(user, a, "  Work laptop  ")
      assert passkey.user_id == user.id
      assert passkey.credential_id == a.credential_id
      assert passkey.name == "Work laptop"
      assert passkey.sign_count == 0
      assert %{-2 => x, -3 => y} = Passkey.cose_key(passkey)
      assert {x, y} == {a.x, a.y}
      assert [%Passkey{id: id}] = Passkeys.list(user)
      assert id == passkey.id
    end

    test "names an unnamed passkey by its place in the list", %{user: user, authenticator: a} do
      assert {:ok, %{name: "Passkey 1"}} = add(user, a, "")
      assert {:ok, %{name: "Passkey 2"}} = add(user, Authenticator.new(), nil)
    end

    test "cuts a long name to fit", %{user: user, authenticator: a} do
      assert {:ok, passkey} = add(user, a, String.duplicate("x", 200))
      assert String.length(passkey.name) == Passkey.name_max()
    end

    test "with no challenge kept, there is nothing to answer", %{user: user, authenticator: a} do
      {challenge, _} = Passkeys.registration_challenge(user, @origin)
      response = Authenticator.attest(a, challenge)
      assert Passkeys.register(user, nil, response, "x") == {:error, :no_challenge}
      assert Passkeys.list(user) == []
    end

    test "refuses an answer to a different challenge", %{user: user, authenticator: a} do
      {challenge, _} = Passkeys.registration_challenge(user, @origin)

      response =
        Authenticator.attest(a, challenge, challenge_bytes: :crypto.strong_rand_bytes(32))

      assert Passkeys.register(user, challenge, response, "x") == {:error, :invalid}
    end

    test "refuses an answer made on another site", %{user: user, authenticator: a} do
      {challenge, _} = Passkeys.registration_challenge(user, @origin)

      assert Passkeys.register(
               user,
               challenge,
               Authenticator.attest(a, challenge, origin: "https://evil.example.net"),
               "x"
             ) == {:error, :invalid}

      assert Passkeys.register(
               user,
               challenge,
               Authenticator.attest(a, challenge, rp_id: "evil.example.net"),
               "x"
             ) == {:error, :invalid}
    end

    test "refuses a passkey whose user was not verified", %{user: user, authenticator: a} do
      {challenge, _} = Passkeys.registration_challenge(user, @origin)
      response = Authenticator.attest(a, challenge, flags: Authenticator.present_only_attested())
      assert Passkeys.register(user, challenge, response, "x") == {:error, :invalid}
    end

    test "refuses a sign-in challenge, an expired one, and garbage", %{
      user: user,
      authenticator: a
    } do
      {login, _} = Passkeys.authentication_challenge(@origin)

      assert Passkeys.register(user, login, Authenticator.attest(a, login), "x") ==
               {:error, :invalid}

      {challenge, _} = Passkeys.registration_challenge(user, @origin)
      stale = %{challenge | issued_at: challenge.issued_at - 3600}

      assert Passkeys.register(user, stale, Authenticator.attest(a, stale), "x") ==
               {:error, :invalid}

      assert Passkeys.register(user, challenge, %{}, "x") == {:error, :invalid}

      assert Passkeys.register(
               user,
               challenge,
               %{"attestationObject" => "!!", "clientDataJSON" => "!!"},
               "x"
             ) == {:error, :invalid}
    end

    test "a registration challenge answers once", %{user: user} do
      {challenge, _} = Passkeys.registration_challenge(user, @origin)
      a = Authenticator.new()

      assert {:ok, _} =
               Passkeys.register(user, challenge, Authenticator.attest(a, challenge), "x")

      b = Authenticator.new()

      assert Passkeys.register(user, challenge, Authenticator.attest(b, challenge), "y") ==
               {:error, :invalid}

      assert length(Passkeys.list(user)) == 1
    end

    test "a credential already on an account here is not added again",
         %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      other = user_fixture("passkey-other@example.com")
      assert add(other, a) == {:error, :already_added}
      assert Passkeys.list(other) == []
    end

    test "stops at the cap", %{user: user} do
      for _ <- 1..Passkeys.max_per_user(), do: {:ok, _} = add(user, Authenticator.new())
      assert add(user, Authenticator.new()) == {:error, :too_many}
      assert length(Passkeys.list(user)) == Passkeys.max_per_user()
    end
  end

  describe "authenticate/2" do
    test "signs its owner in and records the use", %{user: user, authenticator: a} do
      {:ok, passkey} = add(user, a)
      assert is_nil(passkey.last_used_at)

      assert {:ok, signed_in} = sign_in(a, user_handle: <<user.id::64>>, sign_count: 3)
      assert signed_in.id == user.id

      passkey = Repo.reload!(passkey)
      assert passkey.sign_count == 3
      assert %DateTime{} = passkey.last_used_at
    end

    test "works without a user handle too", %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      assert {:ok, %{id: id}} = sign_in(a, user_handle: nil)
      assert id == user.id
    end

    test "the options name no account", _ do
      {challenge, options} = Passkeys.authentication_challenge(@origin)
      assert options.rpId == "slipdock.example.com"
      assert options.userVerification == "required"
      assert options.challenge == Passkeys.encode(challenge.bytes)
      refute Map.has_key?(options, :allowCredentials)
    end

    test "a passkey nobody has added is refused", %{authenticator: a} do
      assert sign_in(a) == {:error, :invalid}
    end

    test "a removed passkey is refused", %{user: user, authenticator: a} do
      {:ok, passkey} = add(user, a)
      assert Passkeys.delete(user, passkey.id) == :ok
      assert sign_in(a) == {:error, :invalid}
    end

    test "a disabled account cannot sign in with one", %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      {:ok, _} = Accounts.disable(user)
      assert sign_in(a) == {:error, :invalid}
    end

    test "a signature from a different key is refused", %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      impostor = Authenticator.new(credential_id: a.credential_id)
      assert sign_in(impostor) == {:error, :invalid}
    end

    test "a user handle naming somebody else is refused", %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      other = user_fixture("passkey-handle@example.com")
      assert sign_in(a, user_handle: <<other.id::64>>) == {:error, :invalid}
    end

    test "a user who was only present, not verified, is refused", %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      assert sign_in(a, flags: Authenticator.present_only()) == {:error, :invalid}
    end

    test "an answer for another site or another challenge is refused",
         %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      assert sign_in(a, origin: "https://evil.example.net") == {:error, :invalid}
      assert sign_in(a, rp_id: "evil.example.net") == {:error, :invalid}
      assert sign_in(a, challenge_bytes: :crypto.strong_rand_bytes(32)) == {:error, :invalid}
      assert sign_in(a, type: "webauthn.create") == {:error, :invalid}
    end

    test "no challenge, the wrong kind, or garbage", %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      {challenge, _} = Passkeys.authentication_challenge(@origin)
      response = Authenticator.assert(a, challenge)

      assert Passkeys.authenticate(nil, response) == {:error, :no_challenge}

      {registration, _} = Passkeys.registration_challenge(user, @origin)
      assert Passkeys.authenticate(registration, response) == {:error, :invalid}

      assert Passkeys.authenticate(challenge, %{}) == {:error, :invalid}

      assert Passkeys.authenticate(challenge, Map.put(response, "signature", "%%")) ==
               {:error, :invalid}
    end

    test "each challenge answers once", %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      {challenge, _} = Passkeys.authentication_challenge(@origin)

      assert {:ok, _} = Passkeys.authenticate(challenge, Authenticator.assert(a, challenge))

      assert Passkeys.authenticate(challenge, Authenticator.assert(a, challenge)) ==
               {:error, :invalid}
    end

    test "a garbled answer does not use the challenge up", %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      {challenge, _} = Passkeys.authentication_challenge(@origin)
      impostor = Authenticator.new(credential_id: a.credential_id)

      assert Passkeys.authenticate(challenge, Authenticator.assert(impostor, challenge)) ==
               {:error, :invalid}

      assert {:ok, _} = Passkeys.authenticate(challenge, Authenticator.assert(a, challenge))
    end

    test "a counter that went backwards is a clone, and is refused", %{
      user: user,
      authenticator: a
    } do
      {:ok, passkey} = add(user, a)
      assert {:ok, _} = sign_in(a, sign_count: 5)
      assert {:error, :cloned} = sign_in(a, sign_count: 5)
      assert {:error, :cloned} = sign_in(a, sign_count: 2)
      # Refused, so nothing about it changed.
      assert Repo.reload!(passkey).sign_count == 5
      assert {:ok, _} = sign_in(a, sign_count: 6)
    end

    test "a counter that never counts (a synced passkey) is fine", %{user: user, authenticator: a} do
      {:ok, _} = add(user, a)
      assert {:ok, _} = sign_in(a, sign_count: 0)
      assert {:ok, _} = sign_in(a, sign_count: 0)
    end
  end

  describe "list/1 and delete/2" do
    test "only ever the account's own", %{user: user, authenticator: a} do
      {:ok, mine} = add(user, a)
      other = user_fixture("passkey-lister@example.com")
      {:ok, theirs} = add(other, Authenticator.new())

      assert Enum.map(Passkeys.list(user), & &1.id) == [mine.id]
      assert Passkeys.delete(user, theirs.id) == {:error, :not_found}
      assert Enum.map(Passkeys.list(other), & &1.id) == [theirs.id]
      assert Passkeys.delete(user, mine.id) == :ok
      assert Passkeys.delete(user, mine.id) == {:error, :not_found}
      assert Passkeys.list(user) == []
    end

    test "go with the account", %{user: user, authenticator: a} do
      {:ok, passkey} = add(user, a)
      Repo.delete!(user)
      refute Repo.get(Passkey, passkey.id)
    end
  end
end
