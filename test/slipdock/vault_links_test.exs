defmodule Slipdock.VaultLinksTest do
  @moduledoc """
  Links across a vault (W-103 R4.1, R4.2, R4.4): a plain `[[Note]]` tries
  its own board and then every board in the vault, the shortest vault path
  winning a tie; `[[Folder/Note]]` picks one by the end of its path; wanted
  pages and backlinks reach across the vault; boards in no vault are as
  they were.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}
  alias Slipdock.Vaults.Index
  alias Slipdock.Wiki.Links
  alias SlipdockWeb.Wiki.Renderer

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "vlkb"}, owner: user)
    jobs = board_fixture(%{"name" => "Job Hunt", "code" => "vljobs"}, owner: user)
    projx = board_fixture(%{"name" => "Project X", "code" => "vlprojx"}, owner: user)
    outside = board_fixture(%{"name" => "Elsewhere", "code" => "vlout"}, owner: user)
    {:ok, notes} = Wiki.create_folder(projx, %{"name" => "Notes"})

    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: jobs})

    {:ok, _} =
      Vaults.add_mapping(vault, user, %{path: "/Projects/X", board: projx, folder: notes})

    %{user: user, kb: kb, jobs: jobs, projx: projx, outside: outside, notes: notes, vault: vault}
  end

  defp page!(board, user, title, attrs \\ %{}) do
    {:ok, page} =
      Wiki.create_page(board, Map.merge(%{"title" => title, "body" => "…"}, attrs), user: user)

    page
  end

  defp links_to(board, user, body) do
    page = page!(board, user, "Linker #{System.unique_integer([:positive])}", %{"body" => body})
    page |> Wiki.outgoing_links() |> Enum.map(& &1.target_page_id)
  end

  test "a plain [[Note]] finds a page on another board of the vault", ctx do
    note = page!(ctx.jobs, ctx.user, "Acme call")
    assert links_to(ctx.kb, ctx.user, "[[Acme call]]") == [note.id]
  end

  test "its own board comes first", ctx do
    mine = page!(ctx.kb, ctx.user, "Dup")
    _theirs = page!(ctx.jobs, ctx.user, "Dup")
    assert links_to(ctx.kb, ctx.user, "[[Dup]]") == [mine.id]
  end

  test "of several, the shortest vault path wins; more of the path picks another", ctx do
    shorter = page!(ctx.jobs, ctx.user, "Dup", %{"folder_id" => nil})
    longer = page!(ctx.projx, ctx.user, "Dup", %{"folder_id" => ctx.notes.id})

    assert links_to(ctx.kb, ctx.user, "[[Dup]]") == [shorter.id]
    assert links_to(ctx.kb, ctx.user, "[[X/Dup]]") == [longer.id]
    assert links_to(ctx.kb, ctx.user, "[[Projects/X/Dup]]") == [longer.id]
    assert links_to(ctx.kb, ctx.user, "[[Jobs/Dup]]") == [shorter.id]
  end

  test "folders and parent pages are part of the path", ctx do
    {:ok, acme} = Wiki.create_folder(ctx.jobs, %{"name" => "Acme"})
    call = page!(ctx.jobs, ctx.user, "Call", %{"folder_id" => acme.id})
    parent = page!(ctx.jobs, ctx.user, "Parent")
    kid = page!(ctx.jobs, ctx.user, "Kid", %{"parent_id" => parent.id})

    assert links_to(ctx.kb, ctx.user, "[[Acme/Call]]") == [call.id]
    assert links_to(ctx.kb, ctx.user, "[[Parent/Kid|the kid]]") == [kid.id]
    assert links_to(ctx.kb, ctx.user, "[[Other/Call]]") == [nil]

    paths = ctx.vault |> Index.build() |> Map.new(&{&1.id, &1.path})
    assert paths[call.id] == "Jobs/Acme/Call"
    assert paths[kid.id] == "Jobs/Parent/Kid"
  end

  test "aliases and titles needing a safe file name match too", ctx do
    {:ok, aliased} =
      Wiki.create_page(
        ctx.jobs,
        %{"title" => "Long name", "front_matter" => "---\naliases: [Short]\n---\n"},
        user: ctx.user
      )

    colon = page!(ctx.jobs, ctx.user, "Retry: why")
    assert links_to(ctx.kb, ctx.user, "[[short]]") == [aliased.id]
    assert links_to(ctx.kb, ctx.user, "[[Retry- why]]") == [colon.id]
  end

  test "a page in a part of its board no mapping covers is in no vault path", ctx do
    _loose = page!(ctx.projx, ctx.user, "Loose")
    assert links_to(ctx.kb, ctx.user, "[[Loose]]") == [nil]
  end

  test "an archived page is not a target", ctx do
    gone = page!(ctx.jobs, ctx.user, "Gone")
    {:ok, _} = Wiki.archive_page(gone)
    assert links_to(ctx.kb, ctx.user, "[[Gone]]") == [nil]
  end

  test "a board in no vault is unchanged, in both directions", ctx do
    _in_vault = page!(ctx.jobs, ctx.user, "Vault only")
    _out = page!(ctx.outside, ctx.user, "Outside only")

    assert links_to(ctx.outside, ctx.user, "[[Vault only]]") == [nil]
    assert links_to(ctx.kb, ctx.user, "[[Outside only]]") == [nil]
    # Naming the board still works, as it always has.
    assert [id] = links_to(ctx.kb, ctx.user, "[[vlout/Outside only]]")
    assert id
  end

  test "a page written later brings links on other boards of the vault to life", ctx do
    linker = page!(ctx.kb, ctx.user, "Waiting", %{"body" => "[[Later]] and [[Jobs/Later2]]"})
    assert Enum.all?(Wiki.outgoing_links(linker), &(not &1.resolved))

    later = page!(ctx.jobs, ctx.user, "Later")
    later2 = page!(ctx.jobs, ctx.user, "Later2")

    assert linker |> Wiki.outgoing_links() |> Enum.map(& &1.target_page_id) |> Enum.sort() ==
             Enum.sort([later.id, later2.id])
  end

  test "backlinks cross boards", ctx do
    note = page!(ctx.jobs, ctx.user, "Target")
    linker = page!(ctx.kb, ctx.user, "Source", %{"body" => "[[Target]]"})
    assert [%{page: %{id: id}}] = Wiki.backlinks(note)
    assert id == linker.id
  end

  test "a reader only reaches pages they can open", ctx do
    note = page!(ctx.jobs, ctx.user, "Private")
    reader = user_fixture("reader@example.com")
    share_fixture(ctx.kb, reader, "read")
    ref = %{kind: :page, target: "Private", board: nil, label: nil, raw: "[[Private]]", count: 1}

    assert [%{to: nil}] = Links.resolve(ctx.kb, [ref], as: reader)
    assert [%{to: {:page, %{id: id}}}] = Links.resolve(ctx.kb, [ref], as: ctx.user)
    assert id == note.id
  end

  test "the renderer links to the page on its own board", ctx do
    note = page!(ctx.jobs, ctx.user, "Rendered")
    html = Renderer.to_html("See [[Rendered]].", board: ctx.kb, as: ctx.user)
    assert html =~ ~s(href="/boards/#{ctx.jobs.id}/wiki/#{note.slug}")
  end

  describe "the vault's own answers" do
    test "resolve_link names the page and its path", ctx do
      note = page!(ctx.projx, ctx.user, "Deep", %{"folder_id" => ctx.notes.id})

      assert {:ok, %{id: id}, "Projects/X/Deep"} =
               Vaults.resolve_link(ctx.vault, "[[X/Deep|label]]", ctx.user)

      assert id == note.id
      assert {:error, :not_found, _} = Vaults.resolve_link(ctx.vault, "Nowhere", ctx.user)
    end

    test "wanted gathers every board's, merged by what was written", ctx do
      page!(ctx.kb, ctx.user, "A", %{"body" => "[[Missing]]"})
      page!(ctx.jobs, ctx.user, "B", %{"body" => "[[Missing]] [[Missing]]"})
      page!(ctx.outside, ctx.user, "C", %{"body" => "[[Missing]]"})

      assert [%{title: "Missing", count: 3, from: from}] = Vaults.wanted(ctx.vault, ctx.user)
      assert from |> Enum.map(& &1.title) |> Enum.sort() == ~w(A B)
    end
  end
end
