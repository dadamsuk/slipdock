defmodule SlipdockWeb.PublishedPageImagesTest do
  @moduledoc """
  A published page draws the images it embeds (#1166), served through its
  link to anybody, and nothing else of the wiki's files.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.{Embeds, Files}

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Pub images", "code" => "pubimg"}, owner: owner)
    path = Path.join(System.tmp_dir!(), "pubimg-#{System.unique_integer([:positive])}")
    File.write!(path, "png bytes")

    {:ok, image} = Files.create(board, %{name: "Pasted image 1.png"}, path)
    {:ok, inline} = Files.create(board, %{name: "icon.png"}, path)
    {:ok, secret} = Files.create(board, %{name: "secret.png"}, path)
    {:ok, pdf} = Files.create(board, %{name: "Spec.pdf"}, path)

    body = """
    ![[Pasted image 1.png]]

    An ![[icon.png|icon]] in a sentence, and the ![[Spec.pdf]].
    """

    page = page_fixture(board, %{"title" => "Notes", "body" => body}, user: owner)
    {:ok, published} = Wiki.publish(page, user: owner)

    %{
      owner: owner,
      board: board,
      page: published,
      image: image,
      inline: inline,
      secret: secret,
      pdf: pdf
    }
  end

  defp public_html(page) do
    {:ok, _view, html} = live(build_conn(), ~p"/w/#{page.public_token}")
    html
  end

  test "the page draws its images, block and inline, through its own link",
       %{page: page, image: image, inline: inline} do
    html = public_html(page)

    assert html =~
             ~s|<img class="wiki-file-embed" src="/w/#{page.public_token}/files/#{image.id}/Pasted%20image%201.png" alt="Pasted image 1.png"|

    assert html =~ ~s|src="#{Embeds.published_url(inline, page)}" alt="icon"|
    # Nothing in it points into the signed-in app.
    refute html =~ "/wiki-files/"
  end

  test "a file that is not an image stays its name", %{page: page, pdf: pdf} do
    html = public_html(page)

    assert html =~ ~s|<span class="wiki-static">Spec.pdf</span>|
    refute Embeds.published?(page, pdf)
    assert get(build_conn(), Embeds.published_url(pdf, page)).status == 404
  end

  test "an embedded image is served to anybody, signed out",
       %{page: page, image: image} do
    resp = get(build_conn(), Embeds.published_url(image, page))

    assert resp.status == 200
    assert resp.resp_body == "png bytes"
    assert get_resp_header(resp, "content-type") |> hd() =~ "image/png"
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]
  end

  test "the link does not reach the board's other files", %{page: page, secret: secret} do
    assert get(build_conn(), Embeds.published_url(secret, page)).status == 404
    assert get(build_conn(), "/w/#{page.public_token}/files/nope/x.png").status == 404
  end

  test "a wrong token, an unpublished page or an archived file is a 404",
       %{page: page, image: image, inline: inline} do
    url = Embeds.published_url(image, page)
    assert get(build_conn(), String.replace(url, page.public_token, "not-a-token")).status == 404

    {:ok, _} = Files.archive(inline)
    assert get(build_conn(), Embeds.published_url(inline, page)).status == 404

    {:ok, _} = Wiki.unpublish(page)
    assert get(build_conn(), url).status == 404
  end

  test "taking the embed out of the page closes it", %{owner: owner, page: page, image: image} do
    {:ok, page} = Wiki.update_page(page, %{"body" => "No pictures now."}, user: owner)

    refute public_html(page) =~ "<img class=\"wiki-file-embed\""
    assert get(build_conn(), Embeds.published_url(image, page)).status == 404
  end

  test "a sharee who edits the page can't publish the owner's other files through it",
       %{owner: owner, page: page, secret: secret} do
    sharee = user_fixture("pubimg-sharee@example.com")
    {:ok, _} = Access.grant(page, sharee, "write", owner)

    {:ok, page} =
      Wiki.update_page(page, %{"body" => page.body <> "\n![[secret.png]]\n"}, user: sharee)

    html = public_html(page)
    assert html =~ ~s|<span class="wiki-static">secret.png</span>|
    refute html =~ "/files/#{secret.id}/"
    assert get(build_conn(), Embeds.published_url(secret, page)).status == 404
  end
end
