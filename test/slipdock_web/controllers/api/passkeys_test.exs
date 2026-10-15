defmodule SlipdockWeb.API.PasskeysTest do
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Accounts
  alias Slipdock.Accounts.Passkeys
  alias Slipdock.PasskeyAuthenticator, as: Authenticator

  defp add_passkey(user, name) do
    a = Authenticator.new()
    {challenge, _} = Passkeys.registration_challenge(user, "https://slipdock.example.com")
    {:ok, passkey} = Passkeys.register(user, challenge, Authenticator.attest(a, challenge), name)
    passkey
  end

  test "lists the caller's passkeys, and only theirs", %{conn: conn, user: user} do
    assert %{"passkeys" => []} = conn |> get(~p"/api/me/passkeys") |> json_response(200)

    mine = add_passkey(user, "Laptop")
    add_passkey(user_fixture("api-passkeys-other@example.com"), "Not mine")

    assert %{"passkeys" => [entry]} = conn |> get(~p"/api/me/passkeys") |> json_response(200)
    assert entry["id"] == mine.id
    assert entry["name"] == "Laptop"
    assert entry["created_at"]
    assert entry["last_used_at"] == nil
    # Nothing an attacker could use: no credential id, no key.
    assert Map.keys(entry) |> Enum.sort() == ~w(created_at id last_used_at name)
  end

  test "removes one and answers with what is left", %{conn: conn, user: user} do
    gone = add_passkey(user, "Lost phone")
    kept = add_passkey(user, "Laptop")

    assert %{"passkeys" => [%{"id" => id}]} =
             conn |> delete(~p"/api/me/passkeys/#{gone.id}") |> json_response(200)

    assert id == kept.id
    assert Enum.map(Passkeys.list(user), & &1.id) == [kept.id]
  end

  test "somebody else's passkey, or a nonsense id, is a 404", %{conn: conn} do
    theirs = add_passkey(user_fixture("api-passkeys-victim@example.com"), "Theirs")

    assert conn |> delete(~p"/api/me/passkeys/#{theirs.id}") |> json_response(404)
    assert conn |> delete(~p"/api/me/passkeys/nope") |> json_response(404)
    assert Slipdock.Repo.reload(theirs)
  end

  test "a read-only token can list but not remove", %{user: user} do
    passkey = add_passkey(user, "Laptop")
    {token, _} = Accounts.create_api_token(user, "ro", scope: "read")
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    assert %{"passkeys" => [_]} = conn |> get(~p"/api/me/passkeys") |> json_response(200)
    assert conn |> delete(~p"/api/me/passkeys/#{passkey.id}") |> json_response(403)
    assert Slipdock.Repo.reload(passkey)
  end

  @tag :anonymous
  test "needs a token", %{conn: conn} do
    assert conn |> get(~p"/api/me/passkeys") |> json_response(401)
  end
end
