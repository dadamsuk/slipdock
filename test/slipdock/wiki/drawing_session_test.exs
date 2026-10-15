defmodule Slipdock.Wiki.DrawingSessionTest do
  @moduledoc """
  A live drawing on the server (#823, W-1730): changes merged and passed on
  to the other editors, readers kept to reading, saves on a debounce that
  are one revision per burst and say who drew, a flush when the last editor
  leaves, and a fresh start from the last save after a crash — for a
  `.excalidraw.md` page and a `.excalidraw` file alike.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Repo, TestConfig}
  alias Slipdock.Wiki.{DrawingSession, Excalidraw, Files, Page, Revision, WikiFile}

  @sketch File.read!("test/support/fixtures/excalidraw/Sketch.excalidraw.md")
  @sketch_json File.read!("test/support/fixtures/excalidraw/sketch.json")

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Sketches"}, owner: owner)

    page =
      page_fixture(
        board,
        %{
          "title" => "Plan",
          "file_name" => "Plan.excalidraw",
          "front_matter" => "---\nexcalidraw-plugin: parsed\n---\n",
          "body" => @sketch
        },
        user: owner
      )

    path = Path.join(System.tmp_dir!(), "ds-#{System.unique_integer([:positive])}")
    File.write!(path, @sketch_json)
    {:ok, file} = Files.create(board, %{name: "Flow.excalidraw"}, path)

    settle_drawing_sessions([{:page, page.id}, {:file, file.id}])
    %{owner: owner, board: board, page: page, json_file: file}
  end

  defp el(id, version, extra \\ %{}),
    do:
      Map.merge(
        %{"id" => id, "type" => "rectangle", "version" => version, "versionNonce" => 7},
        extra
      )

  defp other(board, owner, level) do
    user = user_fixture("#{level}-#{System.unique_integer([:positive])}@example.com")
    {:ok, grant} = Access.grant(board, user, level, owner)
    {user, grant}
  end

  # A second editor in its own process, which does what it is told and
  # passes on everything the session sends it, tagged with its name.
  defp editor(key, user, name) do
    test = self()

    pid =
      spawn_link(fn ->
        # As a LiveView the test mounted would: the session reaches the
        # test's sandbox through its callers.
        Process.put(:"$callers", [test])
        {:ok, session, snapshot} = DrawingSession.join(key, user)
        send(test, {name, :joined, session, snapshot})
        loop(test, name, session)
      end)

    assert_receive {^name, :joined, session, snapshot}
    {pid, session, snapshot}
  end

  defp loop(test, name, session) do
    receive do
      {:push, elements} ->
        send(test, {name, :pushed, DrawingSession.push(session, elements)})
        loop(test, name, session)

      :leave ->
        send(test, {name, :left, DrawingSession.leave(session)})

      message ->
        send(test, {name, message})
        loop(test, name, session)
    end
  end

  defp pushed(pid, name, elements) do
    send(pid, {:push, elements})
    assert_receive {^name, :pushed, reply}
    reply
  end

  defp saved_scene(%Page{id: id}) do
    {:ok, %{scene: scene}} = Excalidraw.parse_markdown(Repo.get!(Page, id).body)
    scene
  end

  defp saved_scene(%WikiFile{id: id}) do
    {:ok, scene} = Excalidraw.parse_json(File.read!(Files.disk_path(Repo.get!(WikiFile, id))))
    scene
  end

  defp element(scene, id), do: Enum.find(scene["elements"], &(&1["id"] == id))

  defp revisions(page),
    do: Repo.all(from r in Revision, where: r.page_id == ^page.id, order_by: [asc: r.id])

  describe "joining" do
    test "the first editor starts the session and gets the scene; the next shares it",
         %{owner: owner, page: page} do
      {:ok, session, snapshot} = DrawingSession.join({:page, page.id}, owner)
      assert snapshot.can_write
      assert snapshot.base == page.content_hash
      assert element(snapshot.scene, "box1")["version"] == 1
      assert DrawingSession.whereis({:page, page.id}) == session

      {_pid, again, _} = editor({:page, page.id}, owner, :b)
      assert again == session
    end

    test "a stranger is refused; a page that is no drawing, a missing one, a damaged one too",
         %{board: board, owner: owner, page: page} do
      stranger = user_fixture("stranger@example.com")
      assert DrawingSession.join({:page, page.id}, stranger) == {:error, :forbidden}

      prose = page_fixture(board, %{"title" => "Prose", "body" => "words"}, user: owner)
      assert DrawingSession.join({:page, prose.id}, owner) == {:error, :not_found}
      assert DrawingSession.join({:page, -1}, owner) == {:error, :not_found}
      assert DrawingSession.join({:card, page.id}, owner) == {:error, :not_found}

      broken =
        page_fixture(board, %{"title" => "B", "file_name" => "B.excalidraw", "body" => "x"},
          user: owner
        )

      assert DrawingSession.join({:page, broken.id}, owner) == {:error, :unreadable}
      assert DrawingSession.whereis({:page, broken.id}) == nil
    end
  end

  describe "changes" do
    test "the winning elements go to everybody else, not back to the sender",
         %{owner: owner, page: page} do
      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)
      {_b, _, _} = editor({:page, page.id}, owner, :b)

      moved = el("box1", 2, %{"x" => 500})
      assert DrawingSession.push(session, [moved, el("new1", 1)]) == {:ok, []}
      assert_receive {:b, {:drawing_session, :elements, [^moved, %{"id" => "new1"}], %{}}}
      refute_receive {:drawing_session, :elements, _, _}, 50
    end

    test "an older version is sent back with the newer one, and nobody hears of it",
         %{owner: owner, page: page} do
      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)
      {b, _, _} = editor({:page, page.id}, owner, :b)

      assert {:ok, []} = pushed(b, :b, [el("box1", 5, %{"x" => 1})])
      assert {:ok, [%{"version" => 5, "x" => 1}]} = DrawingSession.push(session, [el("box1", 3)])
      refute_receive {:b, {:drawing_session, :elements, _, _}}, 50
    end

    test "a deletion and an edit made together settle on the higher version",
         %{owner: owner, page: page} do
      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)
      {b, _, _} = editor({:page, page.id}, owner, :b)

      assert {:ok, []} = pushed(b, :b, [el("oval1", 3, %{"isDeleted" => true})])
      assert {:ok, [%{"isDeleted" => true}]} = DrawingSession.push(session, [el("oval1", 2)])
      :ok = DrawingSession.flush(session)
      assert element(saved_scene(page), "oval1")["isDeleted"] == true
    end

    test "images go once each, and never one the note only links",
         %{owner: owner, page: page} do
      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)
      {_b, _, _} = editor({:page, page.id}, owner, :b)
      png = %{"id" => "p1", "dataURL" => "data:image/png;base64,AAAA", "mimeType" => "image/png"}

      files = %{"p1" => png, "f00d" => %{png | "id" => "f00d"}, "bad" => %{"id" => "bad"}}
      DrawingSession.push(session, [el("img2", 1, %{"fileId" => "p1"})], files)
      assert_receive {:b, {:drawing_session, :elements, [_], %{"p1" => ^png} = sent}}
      assert map_size(sent) == 1

      # Sent again, with nothing new: nobody hears of it.
      DrawingSession.push(session, [], %{"p1" => png})
      refute_receive {:b, {:drawing_session, :elements, _, _}}, 50

      :ok = DrawingSession.flush(session)
      assert Map.keys(saved_scene(page)["files"]) == ["p1"]
    end

    test "a reader gets the changes but may not make any",
         %{board: board, owner: owner, page: page} do
      {reader, _} = other(board, owner, "read")
      {r, _, snapshot} = editor({:page, page.id}, reader, :r)
      refute snapshot.can_write

      assert pushed(r, :r, [el("box1", 9)]) == {:error, :read_only}

      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)
      DrawingSession.push(session, [el("box1", 2)])
      assert_receive {:r, {:drawing_session, :elements, [%{"version" => 2}], _}}
    end

    test "permission is checked on every push, not only on joining",
         %{board: board, owner: owner, page: page} do
      {writer, grant} = other(board, owner, "write")
      {w, _, %{can_write: true}} = editor({:page, page.id}, writer, :w)
      assert {:ok, []} = pushed(w, :w, [el("box1", 2)])

      {:ok, _} = Access.revoke(grant)
      assert pushed(w, :w, [el("box1", 3)]) == {:error, :read_only}
    end

    test "a process that never joined may not push", %{owner: owner, page: page} do
      {_b, session, _} = editor({:page, page.id}, owner, :b)
      assert DrawingSession.push(session, [el("box1", 2)]) == {:error, :not_joined}
    end
  end

  describe "saving" do
    test "a page is saved in its own encoding, its prose and text section kept",
         %{owner: owner, page: page} do
      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)

      DrawingSession.push(session, [
        el("txtA1b2c", 2, %{"type" => "text", "text" => "Shipped", "originalText" => "Shipped"})
      ])

      :ok = DrawingSession.flush(session)
      assert_receive {:drawing_session, :saved, base}

      saved = Repo.get!(Page, page.id)
      assert base == saved.content_hash
      assert {:ok, %{format: :compressed}} = Excalidraw.parse_markdown(saved.body)
      assert saved.body =~ "Shipped ^txtA1b2c"
      assert saved.body =~ "## Embedded Files\nf00d: [[cat.png]]"
      assert element(saved_scene(page), "box1")["version"] == 1

      # Nothing new: no second save.
      :ok = DrawingSession.flush(session)
      refute_receive {:drawing_session, :saved, _}, 50
    end

    test "a .excalidraw file is saved as JSON", %{owner: owner, json_file: file} do
      {:ok, session, snapshot} = DrawingSession.join({:file, file.id}, owner)
      assert snapshot.base == file.sha256

      DrawingSession.push(session, [el("box1", 4, %{"x" => 77})])
      :ok = DrawingSession.flush(session)
      assert_receive {:drawing_session, :saved, sha}

      saved = Repo.get!(WikiFile, file.id)
      assert sha == saved.sha256 and sha != file.sha256
      assert element(saved_scene(file), "box1")["x"] == 77
      assert saved.name == "Flow.excalidraw"
    end

    test "on its own, once nobody has drawn for a moment", %{owner: owner, page: page} do
      TestConfig.put(:drawing_sessions, idle_ms: 30, max_ms: 60_000)
      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)

      DrawingSession.push(session, [el("box1", 2, %{"x" => 1})])
      assert_receive {:drawing_session, :saved, _}, 1_000
      assert element(saved_scene(page), "box1")["x"] == 1
    end

    test "and at the latest every max_ms while drawing goes on", %{owner: owner, page: page} do
      TestConfig.put(:drawing_sessions, idle_ms: 60_000, max_ms: 80)
      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)

      for v <- 2..6 do
        DrawingSession.push(session, [el("box1", v)])
        Process.sleep(30)
      end

      assert_receive {:drawing_session, :saved, _}, 1_000
      assert element(saved_scene(page), "box1")["version"] >= 3
    end

    test "a burst by two people is one revision, put down to the last and naming both",
         %{board: board, owner: owner, page: page} do
      {writer, _} = other(board, owner, "write")
      writer = writer |> Ecto.Changeset.change(name: "Wren") |> Repo.update!()
      before = length(revisions(page))

      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)
      {w, _, _} = editor({:page, page.id}, writer, :w)

      DrawingSession.push(session, [el("box1", 2)])
      DrawingSession.push(session, [el("box1", 3)])
      pushed(w, :w, [el("oval1", 2)])
      :ok = DrawingSession.flush(session)

      assert [revision] = Enum.drop(revisions(page), before)
      assert revision.author_id == writer.id
      assert revision.via == "web"
      assert revision.summary =~ "Drawn together: "
      assert revision.summary =~ "Wren"
    end

    test "a burst by one person names nobody, and is that person's",
         %{owner: owner, page: page} do
      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)
      DrawingSession.push(session, [el("box1", 2)])
      :ok = DrawingSession.flush(session)

      # The owner wrote the page a moment ago, so this joins that revision.
      %{author_id: author_id, summary: summary, body: body} = List.last(revisions(page))
      assert author_id == owner.id
      assert body == Repo.get!(Page, page.id).body
      refute summary && summary =~ "Drawn together"
    end

    test "the last editor out saves and stops the session", %{owner: owner, page: page} do
      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)
      {b, _, _} = editor({:page, page.id}, owner, :b)
      ref = Process.monitor(session)

      pushed(b, :b, [el("box1", 2, %{"x" => 42})])
      send(b, :leave)
      assert_receive {:b, :left, :ok}
      assert Process.alive?(session)
      assert element(saved_scene(page), "box1")["version"] == 1

      :ok = DrawingSession.leave(session)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
      assert element(saved_scene(page), "box1")["x"] == 42
      assert DrawingSession.whereis({:page, page.id}) == nil
    end

    test "an editor whose process ends counts as leaving", %{owner: owner, json_file: file} do
      {b, session, _} = editor({:file, file.id}, owner, :b)
      ref = Process.monitor(session)
      pushed(b, :b, [el("box1", 2, %{"x" => 8})])

      Process.unlink(b)
      Process.exit(b, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
      assert element(saved_scene(file), "box1")["x"] == 8
    end

    test "after a crash it starts again from the last save, and a resync loses nothing",
         %{owner: owner, page: page} do
      {:ok, session, _} = DrawingSession.join({:page, page.id}, owner)
      ref = Process.monitor(session)
      DrawingSession.push(session, [el("box1", 2, %{"x" => 1})])
      :ok = DrawingSession.flush(session)
      DrawingSession.push(session, [el("oval1", 2, %{"x" => 2})])

      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :killed}

      {:ok, fresh, snapshot} = DrawingSession.join({:page, page.id}, owner)
      assert fresh != session
      assert element(snapshot.scene, "box1")["x"] == 1
      assert element(snapshot.scene, "oval1")["version"] == 1

      # The editor sends everything it has; only what the session lacked lands.
      mine = [el("box1", 2, %{"x" => 1}), el("oval1", 2, %{"x" => 2})]
      assert DrawingSession.push(fresh, mine) == {:ok, []}
      :ok = DrawingSession.flush(fresh)
      assert element(saved_scene(page), "oval1")["x"] == 2
    end
  end
end
