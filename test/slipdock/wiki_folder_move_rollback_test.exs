defmodule Slipdock.WikiFolderMoveRollbackTest do
  @moduledoc """
  A folder move is all or nothing (#745). Not async: the trigger that makes
  it fail locks the pages table until the test's sandbox rolls it away.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Wiki}
  alias Slipdock.Wiki.{Folder, FolderMove, Page}

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "Keystone", "code" => "kbr"}, owner: user)
    hunt = board_fixture(%{"name" => "Journal Desk", "code" => "huntr"}, owner: user)
    {:ok, jobs} = Wiki.create_folder(kb, %{"name" => "Journal"})
    {:ok, acme} = Wiki.create_folder(kb, %{"name" => "Acme", "parent_id" => jobs.id})
    {:ok, top} = Wiki.create_page(kb, %{"title" => "Plan", "folder_id" => jobs.id}, user: user)
    %{user: user, kb: kb, hunt: hunt, jobs: jobs, acme: acme, top: top}
  end

  defp page(id), do: Repo.get!(Page, id)
  defp folder(id), do: Repo.get(Folder, id)

  test "a failure part-way rolls every row back", ctx do
    %{user: user, kb: kb, hunt: hunt, jobs: jobs} = ctx

    # Pages are written after folders: fail on the first page, and the
    # folders already moved must come back.
    # (DDL is transactional here, so the test's sandbox takes it away.)
    Repo.query!("""
    CREATE FUNCTION pg_temp.fail_page_move() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'disk on fire'; END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER fail_page_move BEFORE UPDATE OF board_id ON pages
    FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_page_move()
    """)

    assert {:error, :unprocessable_entity, message} = FolderMove.to_board(jobs, hunt, user)
    assert message =~ "nothing moved"
    assert message =~ "disk on fire"

    assert folder(jobs.id).board_id == kb.id
    assert folder(ctx.acme.id).board_id == kb.id
    assert page(ctx.top.id).board_id == kb.id
  end
end
