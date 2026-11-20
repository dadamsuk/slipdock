defmodule Slipdock.SessionTokenDigestTest do
  @moduledoc """
  Session tokens are stored as their SHA-256 digest; the cookie keeps the raw
  token (#3503). Signing in, signing out and expiry work through the digest,
  and the migration digests the rows from before it so their sessions carry on.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.Accounts
  alias Slipdock.Accounts.UserToken
  alias Slipdock.Repo

  [{migration, _}] =
    Code.require_file("priv/repo/migrations/20261120020000_hash_session_tokens.exs")

  @migration migration

  defp stored(user) do
    Repo.all(
      from(t in UserToken,
        where: t.user_id == ^user.id and t.context == "session",
        select: t.token
      )
    )
  end

  defp digest(token), do: :crypto.hash(:sha256, token)

  # A session row as one was stored before #3503: the raw token itself.
  defp raw_session_row(user, token, inserted_at \\ DateTime.utc_now(:second)) do
    Repo.insert_all(UserToken, [
      %{user_id: user.id, token: token, context: "session", inserted_at: inserted_at}
    ])
  end

  describe "a new session" do
    test "stores the token's digest and never the token" do
      user = user_fixture("digest@example.com")
      token = Accounts.generate_session_token(user)

      assert byte_size(token) == 32
      assert stored(user) == [digest(token)]
      refute token in stored(user)
      assert Accounts.get_user_by_session_token(token).id == user.id
    end

    test "is found by its raw token only, not by the digest" do
      user = user_fixture("only-raw@example.com")
      token = Accounts.generate_session_token(user)
      [row_token] = stored(user)

      refute Accounts.get_user_by_session_token(row_token)
      refute Accounts.get_user_by_session_token(:crypto.strong_rand_bytes(32))
      refute Accounts.get_user_by_session_token("")
      assert Accounts.get_user_by_session_token(token).id == user.id
    end

    test "each sign-in has its own token and row" do
      user = user_fixture("two@example.com")
      a = Accounts.generate_session_token(user)
      b = Accounts.generate_session_token(user)

      assert a != b
      assert Enum.sort(stored(user)) == Enum.sort([digest(a), digest(b)])
    end
  end

  describe "expiry" do
    test "a session lasts its 30 days and not a day more" do
      user = user_fixture("expiry@example.com")
      token = Accounts.generate_session_token(user)
      days = UserToken.session_validity_days()

      age = fn d ->
        Repo.update_all(UserToken.by_session_token(token),
          set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -d, :day)]
        )
      end

      age.(days - 1)
      assert Accounts.get_user_by_session_token(token).id == user.id

      age.(days + 1)
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "signing out" do
    test "deletes that session's row and leaves the person's others" do
      user = user_fixture("out@example.com")
      gone = Accounts.generate_session_token(user)
      kept = Accounts.generate_session_token(user)

      :ok = Accounts.delete_session_token(gone)

      refute Accounts.get_user_by_session_token(gone)
      assert Accounts.get_user_by_session_token(kept).id == user.id
      assert stored(user) == [digest(kept)]
    end

    test "with a token that matches nothing deletes nothing" do
      user = user_fixture("nothing@example.com")
      token = Accounts.generate_session_token(user)
      [row_token] = stored(user)

      # Neither a stranger's token nor the stored digest itself removes it.
      :ok = Accounts.delete_session_token(:crypto.strong_rand_bytes(32))
      :ok = Accounts.delete_session_token(row_token)

      assert Accounts.get_user_by_session_token(token).id == user.id
    end

    test "signing out everywhere deletes every session row" do
      user = user_fixture("everywhere@example.com")
      a = Accounts.generate_session_token(user)
      b = Accounts.generate_session_token(user)

      :ok = Accounts.delete_all_sessions(user)

      assert stored(user) == []
      refute Accounts.get_user_by_session_token(a)
      refute Accounts.get_user_by_session_token(b)
    end
  end

  describe "the LiveView id" do
    test "is made from the digest, so the row alone gives it" do
      user = user_fixture("socket@example.com")
      token = Accounts.generate_session_token(user)
      expected = "users_sessions:" <> Base.url_encode64(digest(token))

      assert Accounts.session_live_socket_id(token) == expected
      refute Accounts.session_live_socket_id(token) =~ Base.url_encode64(token)

      SlipdockWeb.Endpoint.subscribe(expected)
      Accounts.disconnect_sessions(user)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^expected, event: "disconnect"}
    end
  end

  describe "the migration" do
    test "digests the sessions from before it, which then carry on" do
      user = user_fixture("before@example.com")
      token = :crypto.strong_rand_bytes(32)
      raw_session_row(user, token)

      # Before the migration the raw token is what the row holds, and the
      # new code doesn't find it.
      assert stored(user) == [token]
      refute Accounts.get_user_by_session_token(token)

      Repo.query!(@migration.rehash())

      assert stored(user) == [digest(token)]
      assert Accounts.get_user_by_session_token(token).id == user.id
      assert Accounts.session_live_socket_id(token) == UserToken.live_socket_id(digest(token))
    end

    test "keeps a session's age, so an old one still expires" do
      user = user_fixture("old@example.com")
      token = :crypto.strong_rand_bytes(32)
      too_old = DateTime.add(DateTime.utc_now(:second), -31, :day)
      raw_session_row(user, token, too_old)

      Repo.query!(@migration.rehash())

      assert stored(user) == [digest(token)]
      refute Accounts.get_user_by_session_token(token)
    end

    test "going down ends every browser session and keeps the other tokens" do
      user = user_fixture("down@example.com")
      session = Accounts.generate_session_token(user)
      {api, _} = Accounts.create_api_token(user, "a robot")
      assert stored(user) != []

      # The migration's own `down`, run by Ecto's runner in this process (so
      # inside the test's transaction); `Ecto.Migrator.down/4` would take a
      # lock on a second connection the sandbox can't give it.
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        20_261_120_020_000,
        @migration,
        :forward,
        :down,
        :down,
        log: false
      )

      assert stored(user) == []
      refute Accounts.get_user_by_session_token(session)
      assert {%Accounts.User{}, _} = Accounts.get_api_token(api)
    end

    test "leaves every other kind of token alone" do
      user = user_fixture("others@example.com")
      {api, _} = Accounts.create_api_token(user, "a robot")
      {magic, magic_row} = UserToken.build_hashed_token(user, "magic", sent_to: user.email)
      magic_row = Repo.insert!(magic_row)
      api_before = Repo.all(from(t in UserToken, where: t.context == "api", select: t.token))

      Repo.query!(@migration.rehash())

      assert Repo.all(from(t in UserToken, where: t.context == "api", select: t.token)) ==
               api_before

      assert Repo.reload!(magic_row).token == magic_row.token
      assert {%Accounts.User{}, _} = Accounts.get_api_token(api)
      assert {:ok, _} = Accounts.verify_magic_link(magic)
    end
  end
end
