defmodule Slipdock.Wiki.DrawingSessionOutsideTest do
  @moduledoc """
  Writes that reach a drawing some other way while it is open (#826): a
  vault sync, the API, a file replaced, one that slips in before the session
  hears of it, and one that isn't a drawing at all. Each is merged into what
  the editors are drawing rather than refused or saved over, and the next
  save holds both sides.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Vaults, Wiki}
  alias Slipdock.Vaults.Sync
  alias Slipdock.Wiki.{DrawingSession, Excalidraw, Files, Page, Revision, WikiFile}

  @sketch File.read!("test/support/fixtures/excalidraw/Sketch.excalidraw.md")
  @sketch_json File.read!("test/support/fixtures/excalidraw/sketch.json")

  setup %{user: user} do
    board = board_fixture(%{"name" => "Sketches"}, owner: user)

    page =
      page_fixture(
        board,
        %{
          "title" => "Plan",
          "file_name" => "Plan.excalidraw",
          "front_matter" => "---\nexcalidraw-plugin: parsed\n---\n",
          "body" => @sketch
        },
        user: user
      )

    path = Path.join(System.tmp_dir!(), "dso-#{System.unique_integer([:positive])}")
    File.write!(path, @sketch_json)
    {:ok, file} = Files.create(board, %{name: "Flow.excalidraw"}, path)

    settle_drawing_sessions([{:page, page.id}, {:file, file.id}])
    %{board: board, page: page, json_file: file}
  end

  defp el(id, version, extra \\ %{}),
    do:
      Map.merge(
        %{"id" => id, "type" => "rectangle", "version" => version, "versionNonce" => 7},
        extra
      )

  # The scene with `changes` (id => attrs) made to its elements, and `added` on the end.
  defp scene_json(changes, added \\ []) do
    @sketch_json
    |> Jason.decode!()
    |> update_in(["elements"], fn elements ->
      Enum.map(elements, &Map.merge(&1, changes[&1["id"]] || %{})) ++ added
    end)
    |> Jason.encode!()
  end

  defp body_with(json) do
    {:ok, body} = Excalidraw.write_markdown(@sketch, json)
    body
  end

  defp saved(%Page{id: id}) do
    {:ok, %{scene: scene}} = Excalidraw.parse_markdown(Repo.get!(Page, id).body)
    scene
  end

  defp saved(%WikiFile{id: id}) do
    {:ok, scene} = Excalidraw.parse_json(File.read!(Files.disk_path(Repo.get!(WikiFile, id))))
    scene
  end

  defp element(scene, id), do: Enum.find(scene["elements"], &(&1["id"] == id))

  # The session has handled everything sent to it before this call.
  defp settled(session), do: DrawingSession.scene(session)

  test "a vault sync while somebody draws: both reach the next save", %{
    user: user,
    board: board,
    page: page
  } do
    {:ok, session, _} = DrawingSession.join({:page, page.id}, user)
    {:ok, _} = DrawingSession.push(session, [el("oval1", 4, %{"x" => 1})])

    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
    body = body_with(scene_json(%{"box1" => %{"version" => 3, "x" => 321}}))

    {:ok, _} =
      Sync.write_page(vault, user, %{
        "id" => page.id,
        "path" => "Plan.excalidraw.md",
        "content" => page.front_matter <> body
      })

    assert_receive {:drawing_session, :elements, [%{"id" => "box1", "x" => 321}], _}
    settled(session)

    :ok = DrawingSession.flush(session)
    scene = saved(page)
    assert element(scene, "box1")["x"] == 321
    assert element(scene, "oval1")["x"] == 1
  end

  test "an API write while somebody draws is merged, not refused or overwritten", %{
    conn: conn,
    user: user,
    page: page
  } do
    {:ok, session, _} = DrawingSession.join({:page, page.id}, user)
    {:ok, _} = DrawingSession.push(session, [el("oval1", 4, %{"x" => 1})])

    body = body_with(scene_json(%{}, [el("agent1", 1, %{"x" => 50})]))
    conn = patch(conn, ~p"/api/pages/#{page.id}", %{"body" => body})
    assert json_response(conn, 200)

    assert_receive {:drawing_session, :elements, [%{"id" => "agent1"}], _}
    settled(session)

    :ok = DrawingSession.flush(session)
    scene = saved(page)
    assert element(scene, "agent1")["x"] == 50
    assert element(scene, "oval1")["x"] == 1
  end

  test "a write that changes nothing the session lacks doesn't make it save again",
       %{user: user, page: page} do
    {:ok, session, _} = DrawingSession.join({:page, page.id}, user)
    body = body_with(scene_json(%{"box1" => %{"version" => 2}}))
    {:ok, written} = Wiki.update_page(page, %{"body" => body}, user: user, via: "api")

    assert_receive {:drawing_session, :elements, [%{"id" => "box1"}], _}
    settled(session)
    :ok = DrawingSession.flush(session)
    refute_receive {:drawing_session, :saved, _}, 50
    assert Repo.get!(Page, page.id).content_hash == written.content_hash
  end

  test "an older copy written from outside loses to what is being drawn",
       %{user: user, page: page} do
    {:ok, session, _} = DrawingSession.join({:page, page.id}, user)
    {:ok, _} = DrawingSession.push(session, [el("box1", 9, %{"x" => "mine"})])
    body = body_with(scene_json(%{"box1" => %{"version" => 2, "x" => "theirs"}}))
    {:ok, _} = Wiki.update_page(page, %{"body" => body}, user: user, via: "api")

    settled(session)
    refute_receive {:drawing_session, :elements, _, _}, 50
    :ok = DrawingSession.flush(session)
    assert element(saved(page), "box1")["x"] == "mine"
  end

  test "a write that isn't a drawing is kept as a revision, editors are warned, and the next change draws over it",
       %{user: user, page: page} do
    {:ok, session, _} = DrawingSession.join({:page, page.id}, user)
    {:ok, prose} = Wiki.update_page(page, %{"body" => "Just words now."}, user: user, via: "api")

    assert_receive {:drawing_session, :warning, "This drawing was overwritten elsewhere" <> _}
    settled(session)

    # Nobody has drawn: the words stay.
    :ok = DrawingSession.flush(session)
    assert Repo.get!(Page, page.id).body == "Just words now."

    {:ok, _} = DrawingSession.push(session, [el("box1", 2, %{"x" => 5})])
    :ok = DrawingSession.flush(session)
    assert_receive {:drawing_session, :saved, _}

    current = Repo.get!(Page, page.id)
    assert {:ok, %{format: :compressed}} = Excalidraw.parse_markdown(current.body)
    assert element(saved(page), "box1")["x"] == 5
    assert current.body =~ "## Embedded Files\nf00d: [[cat.png]]"

    bodies = Repo.all(from r in Revision, where: r.page_id == ^page.id, select: r.body)
    assert prose.body in bodies
  end

  test "a write the session hasn't heard of yet is merged when its save is refused",
       %{user: user, page: page} do
    {:ok, session, _} = DrawingSession.join({:page, page.id}, user)
    {:ok, _} = DrawingSession.push(session, [el("oval1", 4, %{"x" => 1})])

    # Written as though by the session itself, so nobody tells it.
    body = body_with(scene_json(%{"box1" => %{"version" => 3, "x" => 77}}))
    {:ok, _} = Wiki.update_page(page, %{"body" => body}, user: user, drawing_session: true)
    refute_receive {:drawing_session, :elements, _, _}, 50

    :ok = DrawingSession.flush(session)
    assert_receive {:drawing_session, :elements, [%{"id" => "box1", "x" => 77}], _}
    assert_receive {:drawing_session, :saved, _}
    scene = saved(page)
    assert element(scene, "box1")["x"] == 77
    assert element(scene, "oval1")["x"] == 1
  end

  test "a .excalidraw file replaced while open is merged in", %{user: user, json_file: file} do
    {:ok, session, _} = DrawingSession.join({:file, file.id}, user)
    {:ok, _} = DrawingSession.push(session, [el("oval1", 4, %{"x" => 1})])

    path = Path.join(System.tmp_dir!(), "dso-#{System.unique_integer([:positive])}")
    File.write!(path, scene_json(%{"box1" => %{"version" => 3, "x" => 64}}))
    {:ok, _} = Files.replace(Repo.get!(WikiFile, file.id), %{}, path)

    assert_receive {:drawing_session, :elements, [%{"id" => "box1", "x" => 64}], _}
    settled(session)
    :ok = DrawingSession.flush(session)
    scene = saved(file)
    assert element(scene, "box1")["x"] == 64
    assert element(scene, "oval1")["x"] == 1
  end

  test "nothing is told when no session is open", %{user: user, page: page} do
    assert DrawingSession.whereis({:page, page.id}) == nil
    body = body_with(scene_json(%{"box1" => %{"version" => 2}}))
    assert {:ok, _} = Wiki.update_page(page, %{"body" => body}, user: user)
    assert DrawingSession.outside_write({:page, page.id}) == :ok
  end
end
