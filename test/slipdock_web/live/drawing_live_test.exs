defmodule SlipdockWeb.DrawingLiveTest do
  @moduledoc """
  A drawing in the Excalidraw editor (W-103 R5.2, R5.3), from the server's
  side: who may open it and who may change it, what the browser is handed,
  and saving back in the format the drawing was read in — a compressed
  `.excalidraw.md` stays compressed, a `.excalidraw` file stays JSON — with
  a change made meanwhile refused rather than overwritten. The browser's
  half is in assets/js/excalidraw_editor.test.js.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Repo, Wiki}
  alias Slipdock.Wiki.{Excalidraw, Files, Page, WikiFile}

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

    %{board: board, drawing: drawing, json_file: file}
  end

  defp edited(json, text) do
    json
    |> Jason.decode!()
    |> update_in(["elements"], fn elements ->
      Enum.map(elements, fn
        %{"id" => "txtA1b2c"} = el -> %{el | "text" => text, "originalText" => text}
        el -> el
      end)
    end)
    |> Jason.encode!()
  end

  describe "opening" do
    test "a writer gets the editor, the scene as the note holds it, and its linked images",
         %{conn: conn, drawing: drawing} do
      {:ok, view, html} = live(conn, ~p"/drawings/page/#{drawing.id}")
      doc = LazyHTML.from_document(html)

      assert doc
             |> LazyHTML.query("#drawing-editor[phx-hook=ExcalidrawEditor]")
             |> LazyHTML.attribute("data-vendor") == ["/vendor/excalidraw/"]

      assert doc |> LazyHTML.query("#drawing-save") |> Enum.count() == 1

      assert doc |> LazyHTML.query("#drawing-back") |> LazyHTML.attribute("href") == [
               "/boards/#{drawing.board_id}/wiki/#{drawing.slug}"
             ]

      render_hook(view, "load", %{})
      {:ok, %{json: json}} = Excalidraw.parse_markdown(@sketch)
      png = "data:image/png;base64," <> Base.encode64("PNGBYTES")

      assert_reply(view, %{
        json: ^json,
        linked: ["f00d"],
        files: %{"f00d" => %{dataURL: ^png, mimeType: "image/png"}},
        view_only: false,
        base: base
      })

      assert base == drawing.content_hash
    end

    test "a reader may look but not save", %{board: board, user: owner, drawing: drawing} do
      reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
      {:ok, _} = Access.grant(board, reader, "read", owner)
      conn = build_conn() |> log_in_user(reader)

      {:ok, view, html} = live(conn, ~p"/drawings/page/#{drawing.id}")
      refute html =~ ~s(id="drawing-save")

      render_hook(view, "load", %{})
      assert_reply(view, %{view_only: true})

      render_hook(view, "save", %{
        "json" => edited(@sketch_json, "Hacked"),
        "base" => drawing.content_hash
      })

      assert_reply(view, %{error: "You can look at this drawing but not change it."})
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
      assert_reply(view, %{error: "This drawing can't be read: its scene is missing or damaged."})
    end
  end

  describe "saving a page drawing" do
    test "writes it back compressed, with its text section and prose kept in step",
         %{conn: conn, drawing: drawing} do
      {:ok, view, _} = live(conn, ~p"/drawings/page/#{drawing.id}")
      json = edited(@sketch_json, "Shipped")

      render_hook(view, "save", %{"json" => json, "base" => drawing.content_hash})
      saved = Repo.get!(Page, drawing.id)
      assert_reply(view, %{ok: true, base: base})
      assert base == saved.content_hash
      refute base == drawing.content_hash

      assert {:ok, %{format: :compressed, json: ^json}} = Excalidraw.parse_markdown(saved.body)
      assert saved.body =~ "Shipped ^txtA1b2c"
      assert saved.body =~ "## Embedded Files\nf00d: [[cat.png]]"
      assert saved.front_matter == drawing.front_matter
      assert saved.file_name == "Plan.excalidraw"

      # Saved again against the hash it was given back: no conflict.
      render_hook(view, "save", %{"json" => edited(@sketch_json, "Again"), "base" => base})
      assert_reply(view, %{ok: true})
    end

    test "a change made meanwhile is reported, not overwritten", %{
      conn: conn,
      user: user,
      drawing: drawing
    } do
      {:ok, view, _} = live(conn, ~p"/drawings/page/#{drawing.id}")

      {:ok, theirs} =
        Wiki.update_page(drawing, %{"body" => @sketch <> "\n"}, user: user, via: "api")

      render_hook(view, "save", %{
        "json" => edited(@sketch_json, "Mine"),
        "base" => drawing.content_hash
      })

      assert_reply(view, %{error: "This drawing was changed somewhere else" <> _})
      assert Repo.get!(Page, drawing.id).content_hash == theirs.content_hash
    end

    test "what is not a scene is refused", %{conn: conn, drawing: drawing} do
      {:ok, view, _} = live(conn, ~p"/drawings/page/#{drawing.id}")

      render_hook(view, "save", %{"json" => "{\"no\": 1}", "base" => drawing.content_hash})
      assert_reply(view, %{error: "That isn't an Excalidraw scene, so it wasn't saved."})

      render_hook(view, "save", %{})
      assert_reply(view, %{error: "Nothing was sent to save."})
      assert Repo.get!(Page, drawing.id).body == @sketch
    end
  end

  describe "saving a .excalidraw file" do
    test "replaces its bytes with the scene as JSON", %{conn: conn, json_file: file} do
      {:ok, view, _} = live(conn, ~p"/drawings/file/#{file.id}")
      render_hook(view, "load", %{})
      assert_reply(view, %{json: @sketch_json, linked: [], base: sha})
      assert sha == file.sha256

      json = edited(@sketch_json, "Shipped")
      render_hook(view, "save", %{"json" => json, "base" => sha})
      saved = Repo.get!(WikiFile, file.id)
      assert_reply(view, %{ok: true, base: new_sha})
      assert new_sha == saved.sha256
      assert File.read!(Files.disk_path(saved)) == json
      assert saved.name == "Flow.excalidraw"

      render_hook(view, "save", %{"json" => json, "base" => sha})
      assert_reply(view, %{error: "This drawing was changed somewhere else" <> _})

      render_hook(view, "save", %{"json" => "[]", "base" => new_sha})
      assert_reply(view, %{error: "That isn't an Excalidraw scene, so it wasn't saved."})
      assert File.read!(Files.disk_path(Repo.get!(WikiFile, file.id))) == json
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
