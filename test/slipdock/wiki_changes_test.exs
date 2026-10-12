defmodule Slipdock.WikiChangesTest do
  @moduledoc """
  The change feed across a vault (W-103 R2.8): every page, folder and
  attachment change on the vault's boards after a cursor, each once and as
  it is now, announced to whoever is listening.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Vaults, Wiki}
  alias Slipdock.Wiki.Changes

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "KB", "code" => "chkb"}, owner: user)
    jobs = board_fixture(%{"name" => "Jobs", "code" => "chjobs"}, owner: user)
    outside = board_fixture(%{"name" => "Out", "code" => "chout"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "V"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: jobs})
    start = Changes.since(vault, nil, user).cursor
    %{user: user, kb: kb, jobs: jobs, outside: outside, vault: vault, start: start}
  end

  defp feed(ctx, opts \\ []), do: Changes.since(ctx.vault, ctx.start, ctx.user, opts)

  defp page!(board, user, title, attrs \\ %{}) do
    {:ok, page} =
      Wiki.create_page(board, Map.merge(%{"title" => title, "body" => "x"}, attrs), user: user)

    page
  end

  test "without a cursor: no changes, and the cursor to start from", ctx do
    page!(ctx.kb, ctx.user, "A")
    %{changes: [], cursor: cursor, more: false} = Changes.since(ctx.vault, nil, ctx.user)
    assert cursor > ctx.start
  end

  test "a page change carries what sync needs, across every board of the vault", ctx do
    a = page!(ctx.kb, ctx.user, "A")
    b = page!(ctx.jobs, ctx.user, "B")
    _ = page!(ctx.outside, ctx.user, "Not in the vault")

    %{changes: changes, cursor: cursor, more: false} = feed(ctx)
    assert [%{id: a_id, path: "/A"} = first, %{id: b_id, path: "/Jobs/B"}] = changes
    assert {a_id, b_id} == {a.id, b.id}
    assert first.subject == "page"
    assert first.action == "changed"
    assert first.code == a.code
    assert first.content_hash == a.content_hash
    assert first.archived == false
    assert cursor == List.last(changes).cursor

    assert %{changes: [], cursor: ^cursor} = Changes.since(ctx.vault, cursor, ctx.user)
  end

  test "each subject once, at its latest change", ctx do
    page = page!(ctx.kb, ctx.user, "A")
    {:ok, page} = Wiki.update_page(page, %{"body" => "y"}, user: ctx.user)
    {:ok, _} = Wiki.update_page(page, %{"title" => "A2"}, user: ctx.user)

    assert [%{title: "A2", action: "changed"}] = feed(ctx).changes
  end

  test "archive, restore and delete are said as such", ctx do
    page = page!(ctx.kb, ctx.user, "A")
    child = page!(ctx.kb, ctx.user, "Child", %{"parent_id" => page.id})
    {:ok, _} = Wiki.archive_page(page)

    assert feed(ctx).changes |> Enum.map(&{&1.id, &1.action, &1.archived}) |> Enum.sort() ==
             Enum.sort([{page.id, "archived", true}, {child.id, "archived", true}])

    {:ok, _} = Wiki.unarchive_page(page)
    assert Enum.all?(feed(ctx).changes, &(&1.action == "restored"))

    {:ok, _} = Wiki.delete_page(child)
    assert %{id: id, action: "deleted"} = List.last(feed(ctx).changes)
    assert id == child.id
  end

  test "folders: made, renamed, deleted — and the pages a deletion refiles", ctx do
    {:ok, folder} = Wiki.create_folder(ctx.jobs, %{"name" => "Notes"})
    page = page!(ctx.jobs, ctx.user, "Filed", %{"folder_id" => folder.id})
    {:ok, _} = Wiki.update_folder(folder, %{"name" => "Ideas"})

    assert %{subject: "folder", name: "Ideas", path: "Ideas"} =
             Enum.find(feed(ctx).changes, &(&1.subject == "folder"))

    cursor = feed(ctx).cursor
    {:ok, _} = Wiki.delete_folder(folder)
    changes = Changes.since(ctx.vault, cursor, ctx.user).changes
    assert Enum.any?(changes, &match?(%{subject: "folder", action: "deleted"}, &1))

    assert %{path: "/Jobs/Filed", folder_id: nil} =
             Enum.find(changes, &(&1.id == page.id and &1.subject == "page"))
  end

  test "attachments on pages, added and deleted", ctx do
    page = page!(ctx.kb, ctx.user, "With a file")
    src = Path.join(System.tmp_dir!(), "feed-#{System.unique_integer([:positive])}.txt")
    File.write!(src, "hello")
    on_exit(fn -> File.rm(src) end)

    {:ok, attachment} =
      Wiki.add_attachment(page, %{filename: "a.txt", content_type: "text/plain"}, src)

    assert %{subject: "attachment", page_id: page_id, filename: "a.txt", size: 5} =
             List.last(feed(ctx).changes)

    assert page_id == page.id

    {:ok, _} = Boards.delete_attachment(attachment)
    assert %{subject: "attachment", action: "deleted"} = List.last(feed(ctx).changes)
  end

  test "placements and refiling count as page changes", ctx do
    {:ok, folder} = Wiki.create_folder(ctx.kb, %{"name" => "Also"})
    page = page!(ctx.kb, ctx.user, "Placed")
    cursor = feed(ctx).cursor
    {:ok, _} = Wiki.Placements.add(page, folder, ctx.user)
    assert [%{id: id, subject: "page"}] = Changes.since(ctx.vault, cursor, ctx.user).changes
    assert id == page.id
  end

  test "limit pages through, with more: true until the end", ctx do
    for n <- 1..5, do: page!(ctx.kb, ctx.user, "P#{n}")

    first = feed(ctx, limit: 2)
    assert length(first.changes) == 2
    assert first.more

    second = Changes.since(ctx.vault, first.cursor, ctx.user, limit: 2)
    third = Changes.since(ctx.vault, second.cursor, ctx.user, limit: 2)
    assert length(second.changes) == 2 and second.more
    assert length(third.changes) == 1 and not third.more
  end

  test "a reader sees only what they may open; a scoped token only its boards", ctx do
    {:ok, _} =
      Wiki.create_page(ctx.kb, %{"title" => "Draft", "status" => "draft"}, user: ctx.user)

    page!(ctx.jobs, ctx.user, "Jobs page")

    reader = user_fixture("reader@example.com")
    share_fixture(ctx.kb, reader, "read")
    assert Changes.since(ctx.vault, ctx.start, reader).changes == []

    {_token, row} = Accounts.create_api_token(ctx.user, "kb only", scope_boards: [ctx.kb.id])

    titles =
      Changes.since(ctx.vault, ctx.start, ctx.user, token: row).changes |> Enum.map(& &1.title)

    assert titles == ["Draft"]
  end

  test "a change on a vault board is announced", ctx do
    Changes.subscribe(ctx.vault.id)
    page!(ctx.jobs, ctx.user, "Announced")
    vault_id = ctx.vault.id
    assert_receive {:vault_change, ^vault_id, cursor}
    assert cursor > ctx.start

    page!(ctx.outside, ctx.user, "Quiet")
    refute_receive {:vault_change, _, _}, 50
  end

  describe "keeping a window" do
    defp old_row!(board_id, days_ago) do
      at = DateTime.add(DateTime.utc_now(), -days_ago, :day)

      {1, [%{id: id}]} =
        Repo.insert_all(
          Slipdock.Wiki.Change,
          [
            %{
              board_id: board_id,
              subject: "page",
              subject_id: 1,
              action: "changed",
              inserted_at: at
            }
          ],
          returning: [:id]
        )

      id
    end

    test "prune deletes what is older than the window and keeps the rest", ctx do
      old = old_row!(ctx.kb.id, Changes.retention_days() + 1)
      page!(ctx.kb, ctx.user, "Recent")

      assert Changes.prune() >= 1
      refute Repo.get(Slipdock.Wiki.Change, old)
      assert [%{title: "Recent"}] = Changes.since(ctx.vault, old, ctx.user).changes
      assert Changes.prune() == 0
    end

    test "a cursor older than what is kept is told to resync", ctx do
      old = old_row!(ctx.kb.id, Changes.retention_days() + 5)
      page!(ctx.kb, ctx.user, "Recent")
      Changes.prune()

      stale = Changes.since(ctx.vault, old - 1, ctx.user)
      assert stale.resync
      assert stale.changes == []
      assert stale.cursor > old

      fresh = Changes.since(ctx.vault, old, ctx.user)
      refute fresh.resync
      assert [%{title: "Recent"}] = fresh.changes
    end

    test "nothing pruned, nothing to resync", ctx do
      refute Changes.since(ctx.vault, 0, ctx.user).resync
      refute Changes.since(ctx.vault, nil, ctx.user).resync
    end

    test "prune_hourly prunes at most once an hour" do
      now = ~U[2031-01-01 00:00:00Z]
      assert is_integer(Changes.prune_hourly(now))
      assert Changes.prune_hourly(DateTime.add(now, 59, :minute)) == 0
      assert is_integer(Changes.prune_hourly(DateTime.add(now, 61, :minute)))
    end
  end
end
