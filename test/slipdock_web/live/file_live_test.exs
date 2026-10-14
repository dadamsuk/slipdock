defmodule SlipdockWeb.FileLiveTest do
  @moduledoc """
  `/files/:id`: a wiki file shown in a viewer that suits it — an image, a
  PDF, JSON as a folding tree, CSV as a table, text — with the download
  always there, and refused to anybody who can't read the board.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Files, Viewer}

  setup %{user: user} do
    %{board: board_fixture(%{"name" => "Data"}, owner: user)}
  end

  defp stored(board, name, bytes, attrs \\ %{}) do
    path = Path.join(System.tmp_dir!(), "fl-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    {:ok, file} = Files.create(board, Map.put(attrs, :name, name), path)
    File.rm(path)
    file
  end

  test "an image is drawn from its own url, with the download beside it",
       %{conn: conn, board: board} do
    file = stored(board, "cat.png", "PNG")
    {:ok, view, _html} = live(conn, ~p"/files/#{file.id}")

    assert view |> element("#file-image") |> render() =~ ~s(src="#{Files.url(file)}")
    assert view |> element("#file-download") |> render() =~ ~s(href="#{Files.url(file)}")
    assert page_title(view) =~ "cat.png"
  end

  test "an SVG and a PDF are asked for inline, which the controller sandboxes",
       %{conn: conn, board: board} do
    svg = stored(board, "logo.svg", "<svg/>")
    pdf = stored(board, "Spec.pdf", "%PDF-1.4")

    {:ok, view, _} = live(conn, ~p"/files/#{svg.id}")
    assert view |> element("#file-image") |> render() =~ "#{Files.url(svg)}?view=inline"

    {:ok, view, _} = live(conn, ~p"/files/#{pdf.id}")
    assert view |> element("iframe#file-pdf") |> render() =~ "#{Files.url(pdf)}?view=inline"
  end

  test "an HTML file is drawn in a sandboxed frame, asked for inline",
       %{conn: conn, board: board} do
    file = stored(board, "Report.html", "<h1>Hi</h1>")
    {:ok, view, _} = live(conn, ~p"/files/#{file.id}")

    frame = view |> element("iframe#file-html") |> render()
    assert frame =~ "#{Files.url(file)}?view=inline"
    assert frame =~ ~s(sandbox="")
  end

  test "an .mp3 or .m4a plays in an audio player, asked for inline",
       %{conn: conn, board: board} do
    for name <- ["song.mp3", "Memo.m4a"] do
      file = stored(board, name, "ID3")
      {:ok, view, _} = live(conn, ~p"/files/#{file.id}")

      player = view |> element("audio#file-audio") |> render()
      assert player =~ ~s(src="#{Files.url(file)}?view=inline")
      assert player =~ "controls"
      assert player =~ ~s(preload="metadata")
      refute has_element?(view, "#file-none")
    end
  end

  test "JSON is a tree whose outer levels are open and deeper ones folded",
       %{conn: conn, board: board} do
    file = stored(board, "config.json", ~s({"name": "x", "deep": {"inner": {"leaf": [1, 2]}}}))
    {:ok, view, _} = live(conn, ~p"/files/#{file.id}")

    html = view |> element("#file-json") |> render()
    assert html =~ "2 keys"
    assert html =~ "&quot;x&quot;"
    assert html =~ "2 items"
    [_root, deep, inner, leaf] = Regex.scan(~r/<details[^>]*>/, html) |> List.flatten()
    assert deep =~ "open"
    refute inner =~ "open"
    refute leaf =~ "open"
  end

  test "JSON that isn't valid says where, and shows the text as it is",
       %{conn: conn, board: board} do
    file = stored(board, "broken.json", ~s({"a": 1,\n oops}))
    {:ok, view, _} = live(conn, ~p"/files/#{file.id}")

    assert view |> element("#file-problem") |> render() =~ "line 2"
    assert view |> element("#file-text") |> render() =~ "oops"
    refute has_element?(view, "#file-json")
  end

  test "a CSV is a table with its header; a long one says it was cut",
       %{conn: conn, board: board} do
    file = stored(board, "people.csv", "name,age\nAda,36\n\"Lovelace, A\",37\n")
    {:ok, view, _} = live(conn, ~p"/files/#{file.id}")

    assert view |> element("#file-table thead") |> render() =~ "age"
    assert view |> element("#file-table tbody") |> render() =~ "Lovelace, A"
    refute has_element?(view, "#file-table-cut")

    long = stored(board, "long.tsv", Enum.map_join(0..(Viewer.max_rows() + 1), "\n", &"#{&1}\tx"))
    {:ok, view, _} = live(conn, ~p"/files/#{long.id}")
    assert view |> element("#file-table-cut") |> render() =~ "first 1000 of 1001 rows"
  end

  test "text is shown as written; text too big or not UTF-8 says so",
       %{conn: conn, board: board} do
    note = stored(board, "notes.txt", "line one\n<b>not bold</b>")
    {:ok, view, _} = live(conn, ~p"/files/#{note.id}")
    assert view |> element("#file-text") |> render() =~ "&lt;b&gt;not bold"

    binary = stored(board, "raw.txt", <<0xFF, 0xFE, 0x00>>)
    {:ok, view, _} = live(conn, ~p"/files/#{binary.id}")
    assert view |> element("#file-problem") |> render() =~ "text this viewer can read"

    big = stored(board, "huge.csv", "a\n")
    {:ok, _} = big |> Ecto.Changeset.change(size: Viewer.max_text() + 1) |> Slipdock.Repo.update()
    {:ok, view, _} = live(conn, ~p"/files/#{big.id}")
    assert view |> element("#file-problem") |> render() =~ "too big to show here"
  end

  test "a .vtt transcript reads as speakers' turns with their times; a broken one shows its text",
       %{conn: conn, board: board} do
    vtt = """
    WEBVTT

    00:00:01.000 --> 00:00:03.000
    <v Priya>Morning.

    00:00:03.000 --> 00:00:05.000
    <v Priya>Shall we start?

    00:01:05.000 --> 00:01:09.000
    <v Tom>Yes <i>please</i>.
    """

    file = stored(board, "standup.vtt", vtt)
    {:ok, view, _} = live(conn, ~p"/files/#{file.id}")

    assert view |> element("#file-transcript-summary") |> render() =~
             "1:09 · 2 speakers · 2 turns"

    priya = view |> element(~s(#file-transcript li[data-speaker="Priya"])) |> render()
    assert priya =~ "0:01"
    assert priya =~ "Morning."
    assert priya =~ "Shall we start?"
    assert priya =~ "border-sky-500"
    assert priya =~ ~s(data-start-ms="1000")
    assert priya =~ ~s(data-end-ms="5000")
    assert has_element?(view, "#file-transcript[data-transcript]")
    tom = view |> element(~s(#file-transcript li[data-speaker="Tom"])) |> render()
    assert tom =~ "1:05"
    assert tom =~ "Yes please."
    assert tom =~ "border-amber-500"
    refute has_element?(view, "#file-text")

    broken = stored(board, "empty.vtt", "WEBVTT\n\nNOTE no cues\n")
    {:ok, view, _} = live(conn, ~p"/files/#{broken.id}")
    assert view |> element("#file-problem") |> render() =~ "read as a VTT transcript"
    assert view |> element("#file-text") |> render() =~ "NOTE no cues"
  end

  test "a transcript's times are m:ss, and h:mm:ss from an hour" do
    assert SlipdockWeb.FileViewer.clock(0) == "0:00"
    assert SlipdockWeb.FileViewer.clock(65_999) == "1:05"
    assert SlipdockWeb.FileViewer.clock(3_599_000) == "59:59"
    assert SlipdockWeb.FileViewer.clock(3_723_000) == "1:02:03"
  end

  test "a kind with no viewer offers the download", %{conn: conn, board: board} do
    file = stored(board, "clip.mp4", "ID3")
    {:ok, view, _} = live(conn, ~p"/files/#{file.id}")
    assert view |> element("#file-none") |> render() =~ ~s(href="#{Files.url(file)}")
  end

  test "Back goes to the folder the file is filed in", %{conn: conn, board: board} do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Reports"})
    filed = stored(board, "a.txt", "x", %{folder_id: folder.id})
    loose = stored(board, "b.txt", "x")

    {:ok, view, _} = live(conn, ~p"/files/#{filed.id}")
    assert view |> element("#file-back") |> render() =~ "folder=#{folder.id}"

    {:ok, view, _} = live(conn, ~p"/files/#{loose.id}")
    assert view |> element("#file-back") |> render() =~ ~s(href="/boards/#{board.id}/wiki")
  end

  test "a stranger, an archived file and a nonsense id are all turned away",
       %{conn: conn, board: board} do
    file = stored(board, "secret.json", "{}")
    stranger = build_conn() |> log_in_user(user_fixture("stranger@example.com"))
    assert {:error, {:live_redirect, %{to: "/"}}} = live(stranger, ~p"/files/#{file.id}")

    {:ok, _} = Files.archive(file)
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/files/#{file.id}")
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/files/nope")
  end
end
