defmodule SlipdockWeb.DrawingLiveTest do
  @moduledoc """
  A drawing in the Excalidraw editor (W-103 R5.2, R5.3), from the server's
  side: who may open it and who may change it, what the browser is handed,
  and two editors drawing together (#824): changes passed between them and
  saved in the format the drawing was read in — a compressed
  `.excalidraw.md` stays compressed, a `.excalidraw` file stays JSON. The
  browser's half is in assets/js/excalidraw_editor.test.js.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Repo}
  alias Slipdock.Wiki.{DrawingSession, Excalidraw, Files, Page, WikiFile}

  @sketch File.read!("test/support/fixtures/excalidraw/Sketch.excalidraw.md")
  @sketch_json File.read!("test/support/fixtures/excalidraw/sketch.json")

  setup %{user: user} do
    board = board_fixture(%{"name" => "Sketches"}, owner: user)

    drawing =
      page_fixture(
        board,
        %{
          "title" => "Plan",
          "file_name" => "Plan.excalidraw",
          "front_matter" => "---\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n---\n",
          "body" => @sketch
        },
        user: user
      )

    path = Path.join(System.tmp_dir!(), "dl-#{System.unique_integer([:positive])}")
    File.write!(path, "PNGBYTES")
    {:ok, _cat} = Files.create(board, %{name: "cat.png"}, path)
    File.write!(path, @sketch_json)
    {:ok, file} = Files.create(board, %{name: "Flow.excalidraw"}, path)

    settle_drawing_sessions([{:page, drawing.id}, {:file, file.id}])
    %{board: board, drawing: drawing, json_file: file}
  end

  defp el(id, version, extra \\ %{}),
    do:
      Map.merge(
        %{"id" => id, "type" => "rectangle", "version" => version, "versionNonce" => 7},
        extra
      )

  defp saved_scene(%Page{id: id}) do
    {:ok, %{scene: scene}} = Excalidraw.parse_markdown(Repo.get!(Page, id).body)
    scene
  end

  defp saved_scene(%WikiFile{id: id}) do
    {:ok, scene} = Excalidraw.parse_json(File.read!(Files.disk_path(Repo.get!(WikiFile, id))))
    scene
  end

  defp scene_element(scene, id), do: Enum.find(scene["elements"], &(&1["id"] == id))

  # Presence news arrives in its own time: look again for up to a second.
  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp session(view), do: :sys.get_state(view.pid).socket.assigns.session

  describe "opening" do
    test "a writer gets the editor, the scene, and the note's linked images; no Save button",
         %{conn: conn, drawing: drawing} do
      {:ok, view, html} = live(conn, ~p"/drawings/page/#{drawing.id}")
      doc = LazyHTML.from_document(html)

      assert doc
             |> LazyHTML.query("#drawing-editor[phx-hook=ExcalidrawEditor]")
             |> LazyHTML.attribute("data-vendor") == ["/vendor/excalidraw/"]

      assert doc |> LazyHTML.query("#drawing-save") |> Enum.count() == 0

      assert doc |> LazyHTML.query("#drawing-back") |> LazyHTML.attribute("href") == [
               "/boards/#{drawing.board_id}/wiki/#{drawing.slug}"
             ]

      render_hook(view, "load", %{})
      {:ok, %{scene: scene}} = Excalidraw.parse_markdown(@sketch)
      png = "data:image/png;base64," <> Base.encode64("PNGBYTES")

      assert_reply(view, %{
        json: json,
        linked: ["f00d"],
        files: %{"f00d" => %{dataURL: ^png, mimeType: "image/png"}},
        view_only: false
      })

      assert Jason.decode!(json) == scene
      assert is_pid(session(view))
    end

    test "a reader may look but not change anything",
         %{board: board, user: owner, drawing: drawing} do
      reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
      {:ok, _} = Access.grant(board, reader, "read", owner)
      conn = build_conn() |> log_in_user(reader)

      {:ok, view, _html} = live(conn, ~p"/drawings/page/#{drawing.id}")
      render_hook(view, "load", %{})
      assert_reply(view, %{view_only: true})

      render_hook(view, "delta", %{"elements" => [el("box1", 9)]})
      assert_reply(view, %{error: "You can look at this drawing but not change it."})
      :ok = DrawingSession.flush(session(view))
      assert Repo.get!(Page, drawing.id).body == @sketch
    end

    test "a stranger, a page that is no drawing, a file that is no drawing, a bad kind: sent away",
         %{conn: conn, board: board, user: user, drawing: drawing} do
      stranger = user_fixture("stranger-#{System.unique_integer([:positive])}@example.com")

      assert {:error, {:live_redirect, %{to: "/"}}} =
               build_conn() |> log_in_user(stranger) |> live(~p"/drawings/page/#{drawing.id}")

      prose = page_fixture(board, %{"title" => "Prose", "body" => "words"}, user: user)
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/drawings/page/#{prose.id}")

      path = Path.join(System.tmp_dir!(), "dl-#{System.unique_integer([:positive])}")
      File.write!(path, "x")
      {:ok, txt} = Files.create(board, %{name: "notes.txt"}, path)
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/drawings/file/#{txt.id}")
      assert {:error, {:live_redirect, _}} = live(conn, "/drawings/card/#{drawing.id}")
      assert {:error, {:live_redirect, _}} = live(conn, "/drawings/page/nope")
    end

    test "a drawing whose scene is damaged says so rather than opening empty",
         %{conn: conn, board: board, user: user} do
      broken =
        page_fixture(
          board,
          %{"title" => "Broken", "file_name" => "Broken.excalidraw", "body" => "no scene"},
          user: user
        )

      {:ok, view, _} = live(conn, ~p"/drawings/page/#{broken.id}")
      render_hook(view, "load", %{})
      assert_reply(view, %{error: "This drawing can't be opened just now."})
    end
  end

  describe "drawing together" do
    test "what one editor draws reaches the other, and is saved in the note's own format",
         %{conn: conn, drawing: drawing} do
      {:ok, one, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      {:ok, two, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      assert session(one) == session(two)

      text =
        el("txtA1b2c", 2, %{"type" => "text", "text" => "Shipped", "originalText" => "Shipped"})

      png = %{"id" => "p1", "dataURL" => "data:image/png;base64,AAAA", "mimeType" => "image/png"}
      render_hook(one, "delta", %{"elements" => [text], "files" => %{"p1" => png}})
      assert_reply(one, %{stale: []})

      assert_push_event(two, "drawing:remote", %{elements: [^text], files: %{"p1" => ^png}})
      refute_push_event(one, "drawing:remote", _, 50)

      # Ctrl+S: saved now, and everybody is told.
      render_hook(one, "flush", %{})
      assert_push_event(one, "drawing:saved", %{})
      assert_push_event(two, "drawing:saved", %{})

      saved = Repo.get!(Page, drawing.id)
      assert {:ok, %{format: :compressed}} = Excalidraw.parse_markdown(saved.body)
      assert saved.body =~ "Shipped ^txtA1b2c"
      assert saved.body =~ "## Embedded Files\nf00d: [[cat.png]]"
      assert saved.front_matter == drawing.front_matter
    end

    test "an older copy is answered with the newer one", %{conn: conn, drawing: drawing} do
      {:ok, one, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      {:ok, two, _} = live(conn, ~p"/drawings/page/#{drawing.id}")

      render_hook(one, "delta", %{"elements" => [el("box1", 5, %{"x" => 9})], "flush" => true})
      assert_reply(one, %{stale: []})
      render_hook(two, "delta", %{"elements" => [el("box1", 3)]})
      assert_reply(two, %{stale: [%{"version" => 5, "x" => 9}]})
      assert scene_element(saved_scene(drawing), "box1")["x"] == 9
    end

    test "a resync sends everything and gets everything back", %{conn: conn, drawing: drawing} do
      {:ok, one, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      {:ok, two, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      render_hook(one, "delta", %{"elements" => [el("new1", 1)]})

      render_hook(two, "resync", %{"elements" => [el("box1", 2), el("mine", 1)]})
      assert_reply(two, %{elements: elements, files: %{}})
      ids = Enum.map(elements, & &1["id"])
      assert "new1" in ids and "mine" in ids and "oval1" in ids

      render_hook(two, "delta", %{})
      assert_reply(two, %{error: "Nothing was sent."})
      render_hook(two, "resync", %{"elements" => [], "files" => %{}})
      assert_reply(two, %{elements: [_ | _]})
    end

    test "a session that dies is started again from the last save and the browser asked to resync",
         %{conn: conn, drawing: drawing} do
      {:ok, view, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      old = session(view)
      Process.exit(old, :kill)

      assert_push_event(view, "drawing:resync", %{})
      assert is_pid(session(view)) and session(view) != old
    end

    test "warnings and errors from the session reach the browser", %{conn: conn, drawing: drawing} do
      {:ok, view, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      send(view.pid, {:drawing_session, :warning, "Careful"})
      assert_push_event(view, "drawing:notice", %{level: :warning, text: "Careful"})
    end

    test "a .excalidraw file is saved as JSON", %{conn: conn, json_file: file} do
      {:ok, view, _} = live(conn, ~p"/drawings/file/#{file.id}")
      render_hook(view, "load", %{})
      assert_reply(view, %{json: json, linked: [], files: %{}})
      assert Jason.decode!(json) == Jason.decode!(@sketch_json)

      render_hook(view, "delta", %{"elements" => [el("box1", 4, %{"x" => 77})], "flush" => true})
      assert_reply(view, %{stale: []})
      saved = Repo.get!(WikiFile, file.id)
      assert saved.sha256 != file.sha256
      assert scene_element(saved_scene(file), "box1")["x"] == 77
      assert saved.name == "Flow.excalidraw"
    end
  end

  describe "who else is here" do
    setup %{board: board, user: owner} do
      reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
      reader = reader |> Ecto.Changeset.change(name: "Rowan Reed") |> Repo.update!()
      {:ok, _} = Access.grant(board, reader, "read", owner)
      %{reader: reader}
    end

    test "people show in the header with a colour each; readers as viewing; they go when they leave",
         %{conn: conn, reader: reader, user: owner, drawing: drawing} do
      {:ok, one, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      assert_push_event(one, "drawing:people", %{people: []})

      {:ok, two, _} =
        build_conn() |> log_in_user(reader) |> live(~p"/drawings/page/#{drawing.id}")

      assert_push_event(
        one,
        "drawing:people",
        %{people: [%{name: "Rowan Reed", viewing: true} = them]},
        1_000
      )

      assert them.colour == SlipdockWeb.Presence.colour(reader.id)
      assert_push_event(two, "drawing:people", %{people: [%{viewing: false}]}, 1_000)

      html = render(one)
      assert html =~ ~s(data-person="#{owner.id}")
      assert html =~ ~s(data-person="#{reader.id}")
      assert html =~ "Rowan Reed (viewing)"
      assert html =~ "RR"

      ref = Process.monitor(two.pid)
      GenServer.stop(two.pid, :normal)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert eventually(fn -> not (render(one) =~ ~s(data-person="#{reader.id}")) end)
      assert render(one) =~ ~s(data-person="#{owner.id}")
    end

    test "the same person in two tabs is one avatar and two cursors",
         %{conn: conn, user: owner, drawing: drawing} do
      {:ok, one, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      {:ok, _two, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      assert_push_event(one, "drawing:people", %{people: [%{viewing: false}]}, 1_000)

      html = render(one)
      assert length(String.split(html, ~s(data-person="#{owner.id}"))) == 2
    end

    test "pointers reach the others, no more than about twenty a second",
         %{conn: conn, reader: reader, drawing: drawing} do
      {:ok, one, _} = live(conn, ~p"/drawings/page/#{drawing.id}")

      {:ok, two, _} =
        build_conn() |> log_in_user(reader) |> live(~p"/drawings/page/#{drawing.id}")

      render_hook(two, "pointer", %{
        "x" => 10,
        "y" => 20,
        "button" => "down",
        "selected" => ["box1"]
      })

      render_hook(two, "pointer", %{"x" => 11, "y" => 21})

      assert_push_event(one, "drawing:pointer", %{
        x: 10,
        y: 20,
        button: "down",
        selected: ["box1"],
        id: id
      })

      assert is_binary(id)
      refute_push_event(one, "drawing:pointer", %{x: 11}, 20)
      refute_push_event(two, "drawing:pointer", _, 20)

      Process.sleep(50)
      render_hook(two, "pointer", %{"x" => 12, "y" => 22, "tool" => "laser", "evil" => "x"})
      assert_push_event(one, "drawing:pointer", %{x: 12, tool: "laser"} = pointer)
      refute Map.has_key?(pointer, :evil)
    end

    test "pointers are never saved", %{conn: conn, drawing: drawing} do
      {:ok, one, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      {:ok, two, _} = live(conn, ~p"/drawings/page/#{drawing.id}")

      render_hook(two, "pointer", %{"x" => 4242, "y" => 4343, "selected" => ["box1"]})
      assert_push_event(one, "drawing:pointer", %{x: 4242})
      render_hook(one, "flush", %{})
      assert Repo.get!(Page, drawing.id).body == @sketch

      render_hook(one, "delta", %{"elements" => [el("box1", 2)], "flush" => true})
      saved = Repo.get!(Page, drawing.id)
      refute saved.body == @sketch
      {:ok, %{json: json}} = Excalidraw.parse_markdown(saved.body)
      refute json =~ "4242"
      refute json =~ "collaborators"
      refute DrawingSession.scene(session(one)) |> Jason.encode!() =~ "4242"
    end
  end

  describe "getting there" do
    test "a drawing's page offers the editor; other pages don't", %{
      conn: conn,
      board: board,
      user: user,
      drawing: drawing
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/wiki/#{drawing.slug}")
      doc = LazyHTML.from_document(html)

      assert doc |> LazyHTML.query("#open-drawing") |> LazyHTML.attribute("href") == [
               "/drawings/page/#{drawing.id}"
             ]

      assert html =~ "Edit drawing"
      assert html =~ "Edit Markdown"

      prose = page_fixture(board, %{"title" => "Prose", "body" => "words"}, user: user)
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/wiki/#{prose.slug}")
      refute html =~ ~s(id="open-drawing")
    end

    test "the editor's bundle is served from this origin", %{conn: conn} do
      conn = get(conn, "/vendor/excalidraw/excalidraw.js")
      assert conn.status == 200
      assert conn.resp_body =~ "mount"
    end
  end
end
