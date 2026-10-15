defmodule SlipdockWeb.SharedPageEmbedsTest do
  @moduledoc """
  A page shared with somebody draws the images, files and drawings it
  embeds for them, served through the page (#832): the renderer links them
  with `?page=`, and `/wiki-files` and `/wiki-drawings` honour it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.{Drawings, Files}
  alias SlipdockWeb.Wiki.Renderer

  @scene ~s({"type":"excalidraw","version":2,"elements":[],"appState":{},"files":{}})

  setup %{user: sharee} do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Owner's"}, owner: owner)
    {:ok, attachments} = Wiki.create_folder(board, %{"name" => "attachments"})

    path = Path.join(System.tmp_dir!(), "spe-#{System.unique_integer([:positive])}")
    File.write!(path, "bytes")
    scene = path <> ".excalidraw"
    File.write!(scene, @scene)

    file = fn name, from ->
      {:ok, f} = Files.create(board, %{name: name, folder_id: attachments.id}, from)
      f
    end

    image = file.("diagram.png", path)
    pdf = file.("Spec.pdf", path)
    drawing = file.("Plan.excalidraw", scene)
    secret = file.("secret.png", path)

    page =
      page_fixture(
        board,
        %{
          "title" => "Shared",
          "body" => "![[diagram.png]]\n\n![[Spec.pdf]]\n\n![[Plan.excalidraw]]\n\n[[secret.png]]"
        },
        user: owner
      )

    {:ok, _} = Access.grant(page, sharee, "read", owner)

    %{
      owner: owner,
      board: board,
      sharee: sharee,
      page: page,
      image: image,
      pdf: pdf,
      drawing: drawing,
      secret: secret
    }
  end

  describe "the shared page's HTML" do
    test "draws its embeds through the page; a linked file stays the reader's own",
         %{sharee: sharee, page: page, image: image, pdf: pdf, drawing: drawing, secret: secret} do
      html = Renderer.to_html(page.body, page: page, as: sharee, shared: true)

      assert html =~ ~s(<img class="wiki-file-embed" src="#{Files.url(image)}?page=#{page.id}")
      assert html =~ ~s(<a class="wiki-file-link" href="#{Files.url(pdf)}?page=#{page.id}")
      assert html =~ ~s(src="#{Drawings.preview_url(drawing)}&amp;page=#{page.id}")
      refute html =~ Files.url(secret)
    end

    test "the owner's own view links the files as it always did",
         %{owner: owner, page: page, image: image} do
      html = Renderer.to_html(page.body, page: page, as: owner)

      assert html =~ ~s(src="#{Files.url(image)}")
      refute html =~ "?page="
    end

    test "with no page to go through, an embed the reader can't see stays as written",
         %{sharee: sharee, page: page} do
      board = Wiki.board_of(page)
      html = Renderer.to_html("![[diagram.png]]", board: board, as: sharee)

      assert html =~ "![[diagram.png]]"
      refute html =~ "<img"
    end
  end

  describe "GET /wiki-files/:id/:name?page=" do
    test "serves an embedded file to the page's sharee", %{conn: conn, page: page, image: image} do
      resp = get(conn, Files.url(image) <> "?page=#{page.id}")
      assert resp.status == 200
      assert resp.resp_body == "bytes"
    end

    test "is a 404 without the page, through a page that doesn't embed it, or garbage",
         %{conn: conn, page: page, image: image, secret: secret} do
      assert get(conn, Files.url(image)).status == 404
      assert get(conn, Files.url(secret) <> "?page=#{page.id}").status == 404
      assert get(conn, Files.url(image) <> "?page=x").status == 404
    end

    test "is a 404 through a page the reader can't read", %{page: page, image: image} do
      stranger = user_fixture("stranger@example.com")

      assert build_conn()
             |> log_in_user(stranger)
             |> get(Files.url(image) <> "?page=#{page.id}")
             |> Map.fetch!(:status) == 404
    end
  end

  describe "GET /wiki-drawings/file/:id?page=" do
    test "serves an embedded drawing's preview to the page's sharee",
         %{conn: conn, page: page, drawing: drawing} do
      resp = get(conn, Drawings.preview_url(drawing) <> "&page=#{page.id}")
      assert resp.status == 200
      assert resp.resp_body =~ ~r/^<svg /
    end

    test "is a 404 without the page, or through one that doesn't embed it",
         %{conn: conn, owner: owner, sharee: sharee, board: board, drawing: drawing} do
      assert get(conn, Drawings.preview_url(drawing)).status == 404

      other = page_fixture(board, %{"body" => "nothing"}, user: owner)
      {:ok, _} = Access.grant(other, sharee, "read", owner)
      assert get(conn, Drawings.preview_url(drawing) <> "&page=#{other.id}").status == 404
    end
  end
end
