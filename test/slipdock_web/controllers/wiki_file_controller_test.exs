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

  describe "a whole note Meld Encrypt wrote (.mdenc)" do
    setup %{user: user} do
      board = board_fixture(%{"name" => "Vault"}, owner: user)

      note =
        "test/support/fixtures/meld_vectors.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("notes")
        |> hd()

      path = Path.join(System.tmp_dir!(), "wf-#{System.unique_integer([:positive])}")
      File.write!(path, note["file"])
      {:ok, mdenc} = Files.create(board, %{name: "Diary.mdenc"}, path)
      File.write!(path, "{not meld")
      {:ok, broken} = Files.create(board, %{name: "Broken.mdenc"}, path)
      File.write!(path, "bytes")
      {:ok, other} = Files.create(board, %{name: "c.txt"}, path)
      %{mdenc: mdenc, broken: broken, other: other, note: note}
    end

    test "?view=locked shows it locked, with its hint and its ciphertext and no more",
         %{conn: conn, mdenc: mdenc, note: note} do
      conn = get(conn, Files.url(mdenc) <> "?view=locked")
      html = html_response(conn, 200)
      assert html =~ "meld-locked"
      assert html =~ "data-meld-note="
      assert html =~ Phoenix.HTML.html_escape(note["file"]) |> Phoenix.HTML.safe_to_string()
      assert html =~ note["hint"]
      assert html =~ ~s|id="meld-dialog"|
      refute html =~ note["plaintext"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "without it, the file is still a download", %{conn: conn, mdenc: mdenc, note: note} do
      conn = get(conn, Files.url(mdenc))
      assert conn.resp_body == note["file"]
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end

    test "a file Meld didn't write says it can't be opened; any other file ignores the view",
         %{conn: conn, broken: broken, other: other} do
      html = conn |> get(Files.url(broken) <> "?view=locked") |> html_response(200)
      assert html =~ "be opened here"
      refute html =~ "data-meld-note"

      assert get(conn, Files.url(other) <> "?view=locked").resp_body == "bytes"
    end

    test "somebody who can't read the board gets a 404 for the locked view too", %{mdenc: mdenc} do
      stranger = user_fixture("stranger-meld@example.com")
      conn = build_conn() |> log_in_user(stranger) |> get(Files.url(mdenc) <> "?view=locked")
      assert conn.status == 404
    end
  end
end
