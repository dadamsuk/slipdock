defmodule Slipdock.WikiMoveTest do
  @moduledoc """
  A page moved to another board of its vault (W-103 R11.8): it keeps its code
  and everything that is its own, takes the pages under it, and carries the
  board's things across where the target has a match.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Fields, Repo, Vaults, Wiki}
  alias Slipdock.Boards.{ChecklistItem, Comment, FieldValue}
  alias Slipdock.Wiki.{Move, Page, Placements}

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "KB", "code" => "kbmove"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "jobsmove"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: jobs})
    {:ok, acme} = Wiki.create_folder(jobs, %{"name" => "Acme"})

    {:ok, page} =
      Wiki.create_page(kb, %{"title" => "Interview notes", "body" => "v1"}, user: user)

    {:ok, page} = Wiki.update_page(page, %{"body" => "v2"}, user: user)
    %{user: user, kb: kb, jobs: jobs, acme: acme, page: page}
  end

  test "keeps its code and what is its own, and lands where it was put", %{
    user: user,
    kb: kb,
    jobs: jobs,
    acme: acme,
    page: page
  } do
    Repo.insert!(%Comment{page_id: page.id, body: "a comment"})
    Repo.insert!(%ChecklistItem{page_id: page.id, text: "ask about pay"})

    {:ok, child} =
      Wiki.create_page(kb, %{"title" => "Follow-up", "parent_id" => page.id}, user: user)

    revisions = length(Wiki.list_revisions(page))

    assert {:ok, moved} = Move.to_board(page, jobs, acme, user)

    assert moved.board_id == jobs.id
    assert moved.code == page.code
    assert moved.folder_id == acme.id
    assert is_nil(moved.parent_id)
    assert length(Wiki.list_revisions(moved)) == revisions
    assert Repo.aggregate(from(c in Comment, where: c.page_id == ^page.id), :count) == 1
    assert Repo.aggregate(from(c in ChecklistItem, where: c.page_id == ^page.id), :count) == 1
    assert {:ok, %{id: found}} = Wiki.find_page(page.code)
    assert found == page.id

    # The page under it came too, still under it, in the same folder.
    child = Repo.get!(Page, child.id)
    assert child.board_id == jobs.id
    assert child.parent_id == page.id
    assert child.folder_id == acme.id
    assert {:ok, [%{title: "Follow-up"}]} = Wiki.Tree.children(jobs, {:page, page.id})
  end

  test "tags, fields and pins go across where the target has a match", %{
    user: user,
    kb: kb,
    jobs: jobs,
    page: page
  } do
    shared = tag_fixture(kb, "Ops")
    _theirs = tag_fixture(jobs, "ops")
    alone = tag_fixture(kb, "KB only")
    {:ok, _} = Wiki.set_tags(page, [shared, alone])

    {:ok, effort} =
      Fields.create_field(kb, %{"name" => "Effort", "key" => "effort", "kind" => "number"})

    {:ok, their_effort} =
      Fields.create_field(jobs, %{"name" => "Effort", "key" => "effort", "kind" => "number"})

    {:ok, mood} = Fields.create_field(kb, %{"name" => "Mood", "key" => "mood", "kind" => "text"})
    Repo.insert!(%FieldValue{page_id: page.id, field_id: effort.id, number: 3.0})
    Repo.insert!(%FieldValue{page_id: page.id, field_id: mood.id, text: "fine"})

    [kb_col | _] = Slipdock.Boards.get_board!(kb.id).columns
    [jobs_col | _] = Slipdock.Boards.get_board!(jobs.id).columns
    here = card_fixture(kb_col, %{"title" => "KB card"})
    there = card_fixture(jobs_col, %{"title" => "Journal card"})
    Wiki.pin(page, {:card, here})
    Wiki.pin(page, {:card, there})

    assert {:ok, report} = Move.preview(page, jobs, user)
    assert report.pages == 1
    assert report.tags == %{carried: ["Ops"], dropped: ["KB only"]}
    assert report.fields == %{carried: ["Effort"], dropped: ["Mood"]}
    assert report.pins == %{carried: ["Journal card"], dropped: ["KB card"]}

    {:ok, moved} = Move.to_board(page, jobs, nil, user)

    assert Enum.map(Wiki.tags(moved), & &1.name) == ["ops"]
    values = Repo.all(from(v in FieldValue, where: v.page_id == ^page.id))
    assert [%{field_id: field_id, number: 3.0}] = values
    assert field_id == their_effort.id

    pinned =
      Repo.all(
        from(l in Slipdock.Wiki.Link,
          where: l.page_id == ^page.id and l.pinned,
          select: l.target_card_id
        )
      )

    assert pinned == [there.id]
  end

  test "a slug taken on the target gets the code on the end; a list and parent stay behind", %{
    user: user,
    kb: kb,
    jobs: jobs,
    page: page
  } do
    {:ok, _} = Wiki.create_page(jobs, %{"title" => "Interview notes"}, user: user)
    {:ok, parent} = Wiki.create_page(kb, %{"title" => "Hiring"}, user: user)
    {:ok, page} = Wiki.move_page(page, parent)
    [col | _] = Slipdock.Boards.get_board!(kb.id).columns
    Repo.update_all(from(p in Page, where: p.id == ^page.id), set: [column_id: col.id])
    page = Repo.get!(Page, page.id)

    {:ok, report} = Move.preview(page, jobs, user)
    assert report.parent == "Hiring"
    assert report.list == col.name

    {:ok, moved} = Move.to_board(page, jobs, nil, user)
    assert moved.slug == page.slug <> "-" <> String.downcase(page.code)
    assert is_nil(moved.column_id)
    assert is_nil(moved.parent_id)
  end

  test "an assignee who cannot open the target is let go, and said so", %{
    user: user,
    kb: kb,
    jobs: jobs,
    page: page
  } do
    helper = user_fixture("move.helper@example.com")
    share_fixture(kb, helper)
    {:ok, page} = Wiki.update_page(page, %{"assignee_id" => helper.id}, user: user)

    {:ok, report} = Move.preview(page, jobs, user)
    assert report.assignee.dropped
    {:ok, moved} = Move.to_board(page, jobs, nil, user)
    assert is_nil(moved.assignee_id)
  end

  test "placements stay, except one in the folder it now lives in", %{
    user: user,
    kb: kb,
    jobs: jobs,
    acme: acme,
    page: page
  } do
    {:ok, ideas} = Wiki.create_folder(kb, %{"name" => "Ideas"})
    {:ok, _} = Placements.add(page, ideas, user)
    {:ok, _} = Placements.add(page, acme, user)

    {:ok, moved} = Move.to_board(page, jobs, acme, user)
    assert Enum.map(Placements.folders(moved), & &1.id) == [ideas.id]
  end

  test "refused outside a shared vault, without write access, or to its own board", %{
    user: user,
    kb: kb,
    jobs: jobs,
    acme: acme,
    page: page
  } do
    lone = board_fixture(%{"name" => "Lone", "code" => "lonemove"}, owner: user)
    assert {:error, :unprocessable_entity, _} = Move.to_board(page, lone, nil, user)
    assert {:error, :unprocessable_entity, _} = Move.preview(page, kb, user)

    {:ok, other_folder} = Wiki.create_folder(kb, %{"name" => "Here"})
    assert {:error, :unprocessable_entity, _} = Move.to_board(page, jobs, other_folder, user)

    reader = user_fixture("move.reader@example.com")
    share_fixture(kb, reader)
    share_fixture(jobs, reader, "read")
    assert {:error, :forbidden, _} = Move.to_board(page, jobs, acme, reader)
    assert Repo.get!(Page, page.id).board_id == kb.id
  end
end
