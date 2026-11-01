defmodule Slipdock.Wiki.WikiMoveTest do
  @moduledoc """
  One board's wiki into a folder of another (W-2201): what moves, what stays
  with its cards, links that find what they found before, and running it
  twice.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.Repo
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Files, Folder, Links, Page, Revision, WikiFile, WikiMove}

  setup do
    user = user_fixture("wikimove-#{System.unique_integer([:positive])}@example.com")
    kb = board_fixture(%{"name" => "Knowledge", "code" => "wmkb"}, owner: user)
    emp = board_fixture(%{"name" => "Employ", "code" => "wmemp"}, owner: user)

    {:ok, archive} = Wiki.create_folder(emp, %{"name" => "Archive"})
    {:ok, acme} = Wiki.create_folder(emp, %{"name" => "Acme", "parent_id" => archive.id})
    status = page_fixture(emp, %{"title" => "Status", "folder_id" => acme.id}, user: user)
    {:ok, file} = Files.create(emp, %{name: "deck.pdf", folder_id: archive.id}, source("pdf"))

    # A page at the top, with one under it, that means emp's own Status.
    crib = page_fixture(emp, %{"title" => "Crib Sheet", "body" => "See [[Status]]."}, user: user)
    child = page_fixture(emp, %{"title" => "Crib detail", "parent_id" => crib.id}, user: user)

    # A card's own page, which stays with the card.
    card = card_fixture(hd(emp.columns), %{"title" => "Idea 1"})
    {:ok, idea} = Wiki.create_page_from_card(card, user: user, title: "Stress test")

    # On the target: a Status of its own, and links to both.
    kb_status = page_fixture(kb, %{"title" => "Status"}, user: user)

    index =
      page_fixture(
        kb,
        %{"title" => "Index", "body" => "[[Employ/Archive/Acme/Status|Acme]] and [[Status]]"},
        user: user
      )

    %{
      user: user,
      kb: kb,
      emp: emp,
      status: status,
      deck: file,
      crib: crib,
      child: child,
      idea: idea,
      kb_status: kb_status,
      index: index
    }
  end

  defp source(bytes) do
    path = Path.join(System.tmp_dir!(), "wikimove-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp run(ctx, opts \\ []), do: WikiMove.run(ctx.user, ctx.emp, ctx.kb, "Jobs", opts)

  # The pages a page's links find now, in the order written.
  defp targets(page_id) do
    page = Repo.get!(Page, page_id)
    board = Repo.get!(Slipdock.Boards.Board, page.board_id)
    refs = page.body |> Links.extract() |> Enum.filter(&(&1.kind == :page))

    board
    |> Links.resolve(refs, from: page)
    |> Enum.map(fn
      %{to: {:page, %Page{id: id}}} -> id
      _ -> nil
    end)
  end

  defp jobs(kb) do
    Repo.one(
      from(f in Folder, where: f.board_id == ^kb.id and f.name == "Jobs" and is_nil(f.parent_id))
    )
  end

  test "a dry run reports what it would do and changes nothing", ctx do
    before = Repo.aggregate(from(p in Page, where: p.board_id == ^ctx.emp.id), :count)

    assert {:ok, report} = run(ctx, dry_run: true)
    assert report.dry_run
    assert report.pages == 3
    assert report.files == 1
    assert [%{name: "Archive", pages: 1, folders: 2, files: 1}] = report.folders

    assert Repo.aggregate(from(p in Page, where: p.board_id == ^ctx.emp.id), :count) == before
    assert jobs(ctx.kb) == nil
    assert Repo.get!(Page, ctx.index.id).body =~ "[[Employ/Archive/Acme/Status|Acme]]"
  end

  test "the wiki lands in the folder, keeping codes; a card's page stays", ctx do
    assert {:ok, report} = run(ctx)
    refute report.dry_run
    folder = jobs(ctx.kb)

    for page <- [ctx.status, ctx.crib, ctx.child] do
      moved = Repo.get!(Page, page.id)
      assert moved.board_id == ctx.kb.id
      assert moved.code == page.code
    end

    assert Repo.get!(Page, ctx.crib.id).folder_id == folder.id
    assert Repo.get!(Page, ctx.child.id).parent_id == ctx.crib.id
    archive = Repo.get_by!(Folder, board_id: ctx.kb.id, name: "Archive")
    assert archive.parent_id == folder.id
    assert %WikiFile{board_id: kb_id} = Repo.get!(WikiFile, ctx.deck.id)
    assert kb_id == ctx.kb.id

    assert Repo.get!(Page, ctx.idea.id).board_id == ctx.emp.id
    assert report.stayed == [%{code: ctx.idea.code, title: "Stress test"}]
  end

  test "every link finds what it found before; rewrites are revisions", ctx do
    index_before = targets(ctx.index.id)
    crib_before = targets(ctx.crib.id)
    assert index_before == [ctx.status.id, ctx.kb_status.id]
    assert crib_before == [ctx.status.id]

    assert {:ok, report} = run(ctx)
    assert report.unverified == []

    assert targets(ctx.index.id) == index_before
    assert targets(ctx.crib.id) == crib_before

    # Below the board's folder, so renaming the board breaks nothing.
    assert Repo.get!(Page, ctx.index.id).body =~ "[[Jobs/Archive/Acme/Status|Acme]]"
    assert Repo.get!(Page, ctx.crib.id).body =~ "[[Jobs/Archive/Acme/Status]]"

    assert Enum.sort(Enum.map(report.rewrites, & &1.source)) ==
             Enum.sort([{:page, ctx.index.id}, {:page, ctx.crib.id}])

    assert %Revision{via: "migration"} =
             Repo.one(
               from(r in Revision,
                 where: r.page_id == ^ctx.index.id,
                 order_by: [desc: r.id],
                 limit: 1
               )
             )
  end

  test "a second run moves nothing, rewrites nothing and reuses the folder", ctx do
    assert {:ok, _} = run(ctx)
    folder = jobs(ctx.kb)
    body = Repo.get!(Page, ctx.index.id).body

    assert {:ok, again} = run(ctx)
    assert again.pages == 0
    assert again.folders == []
    assert again.rewrites == []
    assert jobs(ctx.kb).id == folder.id
    assert Repo.get!(Page, ctx.index.id).body == body
  end

  describe "refused, with nothing changed" do
    test "the same board", ctx do
      assert {:error, _} = WikiMove.run(ctx.user, ctx.emp, ctx.emp, "Jobs")
    end

    test "a board that isn't the person's", ctx do
      other = board_fixture(%{"name" => "Other", "code" => "wmoth"})
      assert {:error, _} = WikiMove.run(ctx.user, other, ctx.kb, "Jobs")
    end

    test "a folder with no name", ctx do
      assert {:error, _} = WikiMove.run(ctx.user, ctx.emp, ctx.kb, "  ")
    end

    test "a folder that would land on one of the same name", ctx do
      {:ok, jobs} = Wiki.create_folder(ctx.kb, %{"name" => "Jobs"})
      {:ok, _} = Wiki.create_folder(ctx.kb, %{"name" => "Archive", "parent_id" => jobs.id})

      assert {:error, reason} = run(ctx)
      assert reason =~ "Archive"
      assert Repo.get!(Page, ctx.status.id).board_id == ctx.emp.id
      assert Repo.get!(Page, ctx.crib.id).board_id == ctx.emp.id
      assert Repo.get!(Page, ctx.index.id).body =~ "[[Employ/Archive/Acme/Status|Acme]]"
    end
  end

  test "run_named finds the person and the boards, and says which is missing", ctx do
    assert {:ok, %{dry_run: true}} =
             WikiMove.run_named(ctx.user.email, "wmemp", "wmkb", "Jobs", dry_run: true)

    assert {:error, "no board nope"} = WikiMove.run_named(ctx.user.email, "nope", "wmkb", "Jobs")

    assert {:error, "no user nobody@example.com"} =
             WikiMove.run_named("nobody@example.com", "wmemp", "wmkb", "Jobs")
  end
end
