defmodule SlipdockWeb.AttachmentControllerTest do
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.{Access, Boards}

  setup do
    File.rm_rf!(Boards.uploads_dir())
    board = board_fixture()
    [col | _] = board.columns
    card = card_fixture(col)
    src = Path.join(System.tmp_dir!(), "kanban-dl-#{System.unique_integer([:positive])}")
    File.write!(src, <<137, 80, 78, 71, 0, 1, 2, 3>>)
    on_exit(fn -> File.rm(src) end)

    {:ok, image} =
      Boards.add_attachment(card, %{filename: "shot one.png", content_type: "image/png"}, src)

    {:ok, page} =
      Boards.add_attachment(card, %{filename: "page.html", content_type: "text/html"}, src)

    %{board: board, card: card, image: image, page: page}
  end

  test "an image is served inline, anything else as a download", %{
    conn: conn,
    image: image,
    page: page
  } do
    conn = get(conn, Boards.attachment_url(image))
    assert conn.status == 200
    assert conn.resp_body == <<137, 80, 78, 71, 0, 1, 2, 3>>
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert [disp] = get_resp_header(conn, "content-disposition")
    assert disp =~ "inline" and disp =~ "shot%20one.png"

    conn = get(build_conn() |> log_in_user(user_fixture()), Boards.attachment_url(page))
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html"]
    assert [disp] = get_resp_header(conn, "content-disposition")
    assert disp =~ "attachment"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "a user without access to the card gets a 404, and a reader gets the file", %{
    card: card,
    image: image,
    user: owner
  } do
    stranger = user_fixture("stranger@example.com")
    conn = get(conn_as(stranger), Boards.attachment_url(image))
    assert conn.status == 404

    {:ok, _} = Access.grant(card, stranger, "read", owner)
    conn = get(conn_as(stranger), Boards.attachment_url(image))
    assert conn.status == 200
  end

  @tag :anonymous
  test "signed-out requests are sent to the login page", %{conn: conn, image: image} do
    conn = get(conn, Boards.attachment_url(image))
    assert redirected_to(conn) =~ "/login"
  end

  test "a missing file on disk is a 404", %{conn: conn, image: image} do
    File.rm!(Boards.attachment_path(image))
    assert get(conn, Boards.attachment_url(image)).status == 404
  end
end
