defmodule SlipdockWeb.WikiFolderPlacementsLiveTest do
  @moduledoc """
  "Also file in…" for folders in the wiki's tree (#808, #810): the menu's
  dialog, the placed folder's row and its contents, each place opened on
  its own, taking it out again, and the folder page's "Also filed in".
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  alias Slipdock.{Vaults, Wiki}
  alias Slipdock.Wiki.FolderPlacements

  setup %{user: user} do
    kb = board_fixture(%{"name" => "KB", "code" => "kbfp"}, owner: user)
    {:ok, home} = Wiki.create_folder(kb, %{"name" => "Home"})
    {:ok, topic} = Wiki.create_folder(kb, %{"name" => "Topic", "parent_id" => home.id})
    {:ok, inner} = Wiki.create_folder(kb, %{"name" => "Inner", "parent_id" => topic.id})
    {:ok, other} = Wiki.create_folder(kb, %{"name" => "Other"})
    note = page_fixture(kb, %{"title" => "Note", "folder_id" => topic.id})
    %{kb: kb, home: home, topic: topic, inner: inner, other: other, note: note}
  end

  defp dialog(view, keys),
    do: render_hook(view, "tree_dialog", %{"kind" => "also", "keys" => keys})

  test "Also file in… on a folder offers everywhere but itself, its home and its subtree", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.kb}/wiki")
    html = dialog(view, ["folder:#{ctx.topic.id}"])
    assert html =~ "Also file “Topic” in…"

    for barred <- [ctx.topic, ctx.home, ctx.inner],
        do:
          refute(
            has_element?(view, "#tree-targets button[phx-value-target='folder:#{barred.id}']")
          )

    view
    |> element("#tree-targets button[phx-value-target='folder:#{ctx.other.id}']")
    |> render_click()

    assert render(view) =~ "“Topic” is also filed in Other."
    assert [%{id: id}] = FolderPlacements.folders(ctx.topic)
    assert id == ctx.other.id
  end

  test "the placed folder shows in both places, each opened on its own, and comes out", ctx do
    {:ok, _} = FolderPlacements.add(ctx.topic, ctx.other, ctx.user)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.kb}/wiki")
    via = "at:#{ctx.other.id}|folder:#{ctx.topic.id}"

    reply = tree_load(view, %{"keys" => ["folder:#{ctx.other.id}", "folder:#{ctx.home.id}"]})

    assert %{also: true, key: ^via, placed_in: placed_in, kind: "folder"} =
             row(reply, "folder:#{ctx.other.id}", "Topic")

    assert placed_in == ctx.other.id
    refute Map.has_key?(row(reply, "folder:#{ctx.home.id}", "Topic"), :also)

    # Opening it there loads its contents, keyed for that place and fixed in it.
    reply = tree_load(view, %{"keys" => [via], "only" => true})
    assert titles(reply, via) == ["Inner", "Note"]
    note = row(reply, via, "Note")
    assert note.key == "at:#{ctx.other.id}|page:#{ctx.note.id}"
    assert note.via
    assert note.href =~ "/wiki/"

    # Kept open there, and only there.
    render_hook(view, "tree_open", %{"keys" => [via]})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.kb}/wiki")
    reply = tree_load_kept(view)
    assert reply.open == [via]
    assert titles(reply, via) == ["Inner", "Note"]
    refute Map.has_key?(reply.nodes, "folder:#{ctx.topic.id}")

    html =
      render_hook(view, "remove_placement", %{
        "kind" => "folder",
        "id" => to_string(ctx.topic.id),
        "folder" => to_string(ctx.other.id)
      })

    assert html =~ "“Topic” is no longer filed in Other."
    assert FolderPlacements.folders(ctx.topic) == []
    assert Wiki.get_folder(ctx.topic.id).parent_id == ctx.home.id
  end

  test "refused placements say why", ctx do
    {:ok, _} = FolderPlacements.add(ctx.other, ctx.inner, ctx.user)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.kb}/wiki")
    dialog(view, ["folder:#{ctx.topic.id}"])
    # Other sits inside Topic through a placement, so it is not offered…
    refute has_element?(view, "#tree-targets button[phx-value-target='folder:#{ctx.other.id}']")
    # …and asked for anyway, it is refused.
    html = render_hook(view, "also_file_in", %{"target" => "folder:#{ctx.other.id}"})
    assert html =~ "through another placement"
  end

  test "a reader neither gets the dialog nor takes anything out", ctx do
    {:ok, _} = FolderPlacements.add(ctx.topic, ctx.other, ctx.user)
    reader = user_fixture("reader@example.com")
    share_fixture(ctx.kb, reader, "read")
    conn = log_in_user(build_conn(), reader)
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.kb}/wiki")

    assert dialog(view, ["folder:#{ctx.topic.id}"]) =~ "Nothing there you can change."

    render_hook(view, "remove_placement", %{
      "kind" => "folder",
      "id" => to_string(ctx.topic.id),
      "folder" => to_string(ctx.other.id)
    })

    assert [_] = FolderPlacements.folders(ctx.topic)
  end

  test "a garbled or unreadable through-key loads nothing", ctx do
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)
    {:ok, hidden} = Wiki.create_folder(theirs, %{"name" => "Hidden"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.kb}/wiki")

    keys = ["at:#{ctx.other.id}|folder:#{hidden.id}", "at:x|folder:1"]
    reply = tree_load(view, %{"keys" => keys, "only" => true})
    assert reply.nodes == %{}
  end

  test "the folder page says where else it is filed", ctx do
    {:ok, _} = FolderPlacements.add(ctx.topic, ctx.other, ctx.user)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.kb}/wiki?folder=#{ctx.topic.id}")
    assert view |> element("#folder-also-in") |> render() =~ "Other"
    # And the folder it is filed in lists it among its folders, marked.
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.kb}/wiki?folder=#{ctx.other.id}")
    assert render(view) =~ "Also filed here; its home is another folder"
    refute has_element?(view, "#folder-also-in")
  end

  test "in a vault, a folder from another board is placed and opened", ctx do
    jobs = board_fixture(%{"name" => "Journal", "code" => "jobsfp"}, owner: ctx.user)
    {:ok, vault} = Vaults.create_vault(ctx.user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/", board: ctx.kb})
    {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/Journal", board: jobs})
    {:ok, acme} = Wiki.create_folder(jobs, %{"name" => "Acme"})
    page_fixture(jobs, %{"title" => "Client", "folder_id" => acme.id})
    {:ok, _} = FolderPlacements.add(acme, ctx.other, ctx.user)

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.kb}/wiki")
    via = "at:#{ctx.other.id}|folder:#{acme.id}"
    reply = tree_load(view, %{"keys" => ["folder:#{ctx.other.id}", via], "only" => true})
    assert %{key: ^via, board_id: board_id} = row(reply, "folder:#{ctx.other.id}", "Acme")
    assert board_id == jobs.id
    assert titles(reply, via) == ["Client"]
  end
end
