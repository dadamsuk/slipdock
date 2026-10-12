defmodule SlipdockWeb.AttachmentControllerTest do
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Access, Boards}

  setup do
    Slipdock.TestConfig.own_uploads_dir()
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

  test "a view-only reader gets files only on cards their view shows", %{
    board: board,
    card: card,
    image: image,
    user: owner
  } do
    viewer = user_fixture("viewer@example.com")
    {:ok, card} = Boards.update_card(card, %{"title" => "Public notes"})
    hidden = card_fixture(hd(board.columns), %{"title" => "Payroll"})

    {:ok, hidden_file} =
      Boards.add_attachment(
        hidden,
        %{filename: "salaries.png", content_type: "image/png"},
        Boards.attachment_path(image)
      )

    {:ok, view} =
      Boards.create_saved_view(board, %{
        "name" => "Public",
        "config" => Slipdock.Swimlanes.Config.to_map(%Slipdock.Swimlanes.Config{q: "public"})
      })

    {:ok, _} = Access.grant(view, viewer, "read", owner)
    assert Access.board_permission(viewer, board) == :view

    assert get(conn_as(viewer), Boards.attachment_url(image)).status == 200
    assert get(conn_as(viewer), Boards.attachment_url(hidden_file)).status == 404

    # Once the card leaves the view, so do its files.
    {:ok, _} = Boards.update_card(card, %{"title" => "Notes"})
    assert get(conn_as(viewer), Boards.attachment_url(image)).status == 404

    # The owner still reaches both.
    assert get(conn_as(owner), Boards.attachment_url(hidden_file)).status == 200
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

  describe "a recording" do
    setup %{card: card} do
      src = Path.join(System.tmp_dir!(), "kanban-audio-#{System.unique_integer([:positive])}")
      File.write!(src, "0123456789")
      on_exit(fn -> File.rm(src) end)

      {:ok, audio} =
        Boards.add_attachment(card, %{filename: "call.mp3", content_type: "audio/mpeg"}, src)

      %{audio: audio}
    end

    test "is served inline, and says it takes ranges", %{conn: conn, audio: audio} do
      conn = get(conn, Boards.attachment_url(audio))
      assert conn.status == 200
      assert conn.resp_body == "0123456789"
      assert [disp] = get_resp_header(conn, "content-disposition")
      assert disp =~ "inline"
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "a range gets just those bytes", %{conn: conn, audio: audio} do
      for {range, body, content_range} <- [
            {"bytes=2-5", "2345", "bytes 2-5/10"},
            {"bytes=7-", "789", "bytes 7-9/10"},
            {"bytes=-3", "789", "bytes 7-9/10"},
            # Past the end is cut to the end; a suffix longer than the file is all of it.
            {"bytes=8-99", "89", "bytes 8-9/10"},
            {"bytes=-50", "0123456789", "bytes 0-9/10"}
          ] do
        conn = conn |> put_req_header("range", range) |> get(Boards.attachment_url(audio))
        assert conn.status == 206, range
        assert conn.resp_body == body, range
        assert get_resp_header(conn, "content-range") == [content_range], range
        assert get_resp_header(conn, "content-type") == ["audio/mpeg"]
        assert [disp] = get_resp_header(conn, "content-disposition")
        assert disp =~ "inline" and disp =~ "call.mp3"
      end
    end

    test "a range that starts past the end is a 416", %{conn: conn, audio: audio} do
      for range <- ["bytes=10-", "bytes=20-30", "bytes=5-2", "bytes=-0"] do
        conn = conn |> put_req_header("range", range) |> get(Boards.attachment_url(audio))
        assert conn.status == 416, range
        assert get_resp_header(conn, "content-range") == ["bytes */10"]
      end
    end

    test "a range header that doesn't parse, or asks for several, gets the whole file", %{
      conn: conn,
      audio: audio
    } do
      for range <- ["bytes=abc", "items=0-1", "bytes=-", "bytes=0-1,4-5"] do
        conn = conn |> put_req_header("range", range) |> get(Boards.attachment_url(audio))
        assert conn.status == 200, range
        assert conn.resp_body == "0123456789"
      end
    end

    test "a range is no way round the access check", %{audio: audio} do
      stranger = user_fixture("range.stranger@example.com")

      conn =
        conn_as(stranger)
        |> put_req_header("range", "bytes=0-1")
        |> get(Boards.attachment_url(audio))

      assert conn.status == 404
    end
  end
end
