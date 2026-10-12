defmodule SlipdockWeb.WikiFileControllerTest do
  @moduledoc "`/wiki-files/:id/:name`: a wiki's files, to whoever can read the board."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki.Files

  setup %{user: user} do
    board = board_fixture(%{"name" => "KB"}, owner: user)
    path = Path.join(System.tmp_dir!(), "wf-#{System.unique_integer([:positive])}")
    File.write!(path, "bytes")
    {:ok, png} = Files.create(board, %{name: "a.png"}, path)
    {:ok, svg} = Files.create(board, %{name: "b.svg"}, path)
    %{png: png, svg: svg}
  end

  test "an image is shown inline; anything else, SVG included, is a download",
       %{conn: conn, png: png, svg: svg} do
    shown = get(conn, Files.url(png))
    assert shown.status == 200
    assert shown.resp_body == "bytes"
    assert [disposition] = get_resp_header(shown, "content-disposition")
    assert disposition =~ "inline"

    downloaded = get(conn, Files.url(svg))
    assert [disposition] = get_resp_header(downloaded, "content-disposition")
    assert disposition =~ "attachment"
    assert [type] = get_resp_header(downloaded, "content-type")
    assert type =~ "application/octet-stream"
  end

  test "somebody who can't read the board, or an archived file, gets a 404",
       %{conn: conn, png: png} do
    stranger = user_fixture("stranger@example.com")

    assert build_conn() |> log_in_user(stranger) |> get(Files.url(png)) |> Map.fetch!(:status) ==
             404

    {:ok, _} = Files.archive(png)
    assert get(conn, Files.url(png)).status == 404
  end
end
