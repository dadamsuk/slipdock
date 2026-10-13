defmodule SlipdockWeb.WikiExcalidrawWebTest do
  @moduledoc """
  Excalidraw drawings in the web app (W-103 R5.1): `![[x.excalidraw]]` and
  `![[x.excalidraw.md]]` drawn as an SVG preview in the page, the preview
  served to readers only and unable to run anything, and a drawing's own
  page showing the drawing rather than the plugin's Markdown.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Wiki.{Drawings, Files}
  alias SlipdockWeb.Wiki.Renderer

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

    path = Path.join(System.tmp_dir!(), "exw-#{System.unique_integer([:positive])}")
    File.write!(path, @sketch_json)
    {:ok, file} = Files.create(board, %{name: "Flow.excalidraw"}, path)

    %{board: board, drawing: drawing, json_file: file}
  end

  describe "embedding" do
    test "![[x.excalidraw]] and ![[x.excalidraw.md]] draw the preview and open the drawing",
         %{board: board, user: user, drawing: drawing, json_file: file} do
      html =
        Renderer.to_html(
          "![[Plan.excalidraw]]\n\n![[Plan.excalidraw.md|The plan]]\n\n![[Flow.excalidraw]]",
          board: board,
          as: user
        )

      doc = LazyHTML.from_fragment(html)
      previews = doc |> LazyHTML.query("a.wiki-drawing img.wiki-drawing-preview")
      assert Enum.count(previews) == 3

      assert previews |> LazyHTML.attribute("src") == [
               Drawings.preview_url(drawing),
               Drawings.preview_url(drawing),
               Drawings.preview_url(file)
             ]

      assert doc |> LazyHTML.query("a.wiki-drawing") |> LazyHTML.attribute("href") == [
               "/boards/#{board.id}/wiki/#{drawing.slug}",
               "/boards/#{board.id}/wiki/#{drawing.slug}",
               Files.url(file)
             ]

      assert previews |> LazyHTML.attribute("alt") |> Enum.at(1) == "The plan"
    end

    test "in a sentence, it is drawn inline", %{board: board, user: user, drawing: drawing} do
      html = Renderer.to_html("See ![[Plan.excalidraw]] for it.", board: board, as: user)
      assert html =~ ~s(<p>See <a class="wiki-drawing")
      assert html =~ Drawings.preview_url(drawing)
    end

    test "a missing drawing stays as written, and a published page only names it",
         %{board: board, user: user} do
      assert Renderer.to_html("![[Nowhere.excalidraw]]", board: board, as: user) =~
               "![[Nowhere.excalidraw]]"

      static = Renderer.to_html("![[Plan.excalidraw]]", board: board, static: true)
      refute static =~ "wiki-drawing"
      assert static =~ ~s(<span class="wiki-static">Plan.excalidraw</span>)
    end
  end

  describe "GET /wiki-drawings/:kind/:id" do
    test "the preview as SVG, locked down", %{conn: conn, drawing: drawing, json_file: file} do
      for drawing <- [drawing, file] do
        conn = get(conn, Drawings.preview_url(drawing))
        assert conn.status == 200
        assert [type] = get_resp_header(conn, "content-type")
        assert type =~ "image/svg+xml"
        assert [policy] = get_resp_header(conn, "content-security-policy")
        assert policy =~ "default-src 'none'"
        assert policy =~ "sandbox"
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
        assert conn.resp_body =~ ~r/^<svg /
        assert conn.resp_body =~ ">Ship it</tspan>"
      end
    end

    test "a 404 for a stranger, a page that is not a drawing, an unknown kind or id",
         %{conn: conn, board: board, user: user, drawing: drawing} do
      stranger = user_fixture("stranger-#{System.unique_integer([:positive])}@example.com")

      assert build_conn()
             |> log_in_user(stranger)
             |> get(Drawings.preview_url(drawing))
             |> Map.fetch!(:status) == 404

      prose = page_fixture(board, %{"title" => "Prose", "body" => "words"}, user: user)
      assert get(conn, "/wiki-drawings/page/#{prose.id}").status == 404
      assert get(conn, "/wiki-drawings/card/#{drawing.id}").status == 404
      assert get(conn, "/wiki-drawings/page/x#{drawing.id}").status == 404
      assert get(conn, "/wiki-drawings/page/0").status == 404
    end

    test "signed out, it is a sign-in, not a drawing", %{drawing: drawing} do
      conn = get(build_conn(), Drawings.preview_url(drawing))
      assert conn.status == 302
    end
  end

  describe "a drawing's own page" do
    test "shows the drawing, not the plugin's Markdown", %{
      conn: conn,
      board: board,
      drawing: drawing
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/wiki/#{drawing.slug}")
      doc = LazyHTML.from_document(html)

      assert doc
             |> LazyHTML.query("#wiki-body .wiki-drawing-page img.wiki-drawing-preview")
             |> LazyHTML.attribute("src") == [Drawings.preview_url(drawing)]

      refute html =~ "Switch to EXCALIDRAW VIEW"
      refute html =~ "compressed-json"
    end

    test "a drawing page whose scene can't be read falls back to its Markdown",
         %{conn: conn, board: board, user: user} do
      broken =
        page_fixture(
          board,
          %{"title" => "Broken", "file_name" => "Broken.excalidraw", "body" => "Only *words*"},
          user: user
        )

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/wiki/#{broken.slug}")
      assert html =~ "<em>words</em>"
      refute html =~ "wiki-drawing-page"
    end
  end
end
