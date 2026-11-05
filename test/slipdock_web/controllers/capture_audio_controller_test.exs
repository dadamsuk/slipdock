defmodule SlipdockWeb.CaptureAudioControllerTest do
  @moduledoc """
  A capture's recording is served with the type its sender gave only when
  that is a recording's type. Anything else goes out as bytes to download,
  so nothing sent as a recording is read as a page or a script from this
  origin.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.Meetings

  setup %{user: user} do
    meetings_on()
    %{board: board_fixture(%{"name" => "Calls"}, owner: user)}
  end

  defp capture(board, user, content_type, filename \\ "call.wav") do
    path = Path.join(System.tmp_dir!(), "a-#{System.unique_integer([:positive])}.bin")
    File.write!(path, "<script>alert(1)</script>")
    on_exit(fn -> File.rm(path) end)

    {:ok, capture} =
      Meetings.create_capture(
        board,
        user,
        %{title: "Call", fingerprint: Meetings.fingerprint(audio: path)},
        audio: %{path: path, filename: filename, content_type: content_type}
      )

    capture
  end

  defp type(conn), do: conn |> get_resp_header("content-type") |> List.first()

  test "a recording's own type is kept, and plays inline", %{conn: conn, board: b, user: u} do
    c = capture(b, u, "audio/ogg; codecs=opus")
    res = get(conn, "/captures/#{c.id}/audio")

    assert res.status == 200
    assert type(res) =~ "audio/ogg"
    assert get_resp_header(res, "content-disposition") == []
  end

  for bad <- ["text/html", "application/javascript", "image/svg+xml", "text/html; x=audio/ogg"] do
    test "a #{bad} recording is only ever a download", %{conn: conn, board: b, user: u} do
      c = capture(b, u, unquote(bad))
      res = get(conn, "/captures/#{c.id}/audio")

      assert res.status == 200
      assert type(res) =~ "application/octet-stream"
      assert get_resp_header(res, "content-disposition") == ["attachment"]
      assert get_resp_header(res, "x-content-type-options") == ["nosniff"]
    end
  end

  test "a byte range of a refused type is still a download", %{conn: conn, board: b, user: u} do
    c = capture(b, u, "text/html")
    res = conn |> put_req_header("range", "bytes=0-7") |> get("/captures/#{c.id}/audio")

    assert res.status == 206
    assert res.resp_body == "<script>"
    assert type(res) =~ "application/octet-stream"
  end

  test "with no type given, the name's is used, under the same rule", %{
    conn: conn,
    board: b,
    user: u
  } do
    assert type(get(conn, "/captures/#{capture(b, u, nil, "call.mp3").id}/audio")) =~
             "audio/mpeg"
  end

  test "an image type is not a recording's", %{conn: conn, board: b, user: u} do
    assert type(get(conn, "/captures/#{capture(b, u, "image/png").id}/audio")) =~
             "application/octet-stream"
  end
end
