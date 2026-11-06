defmodule Slipdock.TranscriptionAccessMigrationTest do
  @moduledoc """
  The migration that gives transcription its own permission (#1817):
  everybody who had `meetings_access` has `transcription_access`, nobody else
  gains it, and a new account starts without it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Repo

  [{migration, _}] =
    Code.require_file("priv/repo/migrations/20261106192935_add_users_transcription_access.exs")

  @migration migration

  test "everybody with meetings gets transcription; nobody else does" do
    had = user_fixture("had@example.com")
    hadnt = user_fixture("hadnt@example.com")
    kept = user_fixture("kept@example.com")

    # As they stood before: only meetings_access set. `kept` had
    # transcription without meetings, which the copy mustn't take away.
    Repo.update_all(User, set: [transcription_access: false, meetings_access: false])
    Repo.update_all(from(u in User, where: u.id == ^had.id), set: [meetings_access: true])
    Repo.update_all(from(u in User, where: u.id == ^kept.id), set: [transcription_access: true])

    Repo.query!(@migration.copy())

    assert Repo.reload!(had).transcription_access
    refute Repo.reload!(hadnt).transcription_access
    assert Repo.reload!(kept).transcription_access
  end

  test "the column is there, not null, and off by default" do
    %{rows: [[default, nullable]]} =
      Repo.query!(
        "SELECT column_default, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = 'users' AND column_name = 'transcription_access'"
      )

    assert default == "false"
    assert nullable == "NO"

    {:ok, user} = Slipdock.Accounts.get_or_create_user_by_email("fresh@example.com")
    refute Repo.reload!(user).transcription_access
  end
end
