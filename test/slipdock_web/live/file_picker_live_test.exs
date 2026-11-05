defmodule SlipdockWeb.FilePickerLiveTest do
  @moduledoc """
  No page shows the browser's own "Choose file / No file chosen" (#1722):
  the visible pickers are `<.file_picker>`, and every other file input is a
  hidden one behind a button of the page's own. Each upload still works,
  and a wrong kind of file says what is wanted.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Portable, Settings}

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    :ok
  end

  # Every file input on the page: inside a file picker, or hidden.
  defp bare_file_inputs(html) do
    {:ok, doc} = Floki.parse_document(html)

    for input <- Floki.find(doc, "input[type=file]"),
        classes = input |> Floki.attribute("class") |> Enum.join(" ") |> String.split(),
        "file-picker-input" not in classes and "hidden" not in classes,
        do: Floki.raw_html(input)
  end

  test "the source has no file input outside the picker that isn't hidden" do
    hits =
      for path <- Path.wildcard("lib/slipdock_web/**/*.{ex,heex}"),
          path != "lib/slipdock_web/components/core_components.ex",
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/<\.live_file_input|type="file"/,
          # The attributes may run onto the next lines; read the tag whole.
          tag =
            path
            |> File.read!()
            |> String.split("\n")
            |> Enum.slice((n - 1)..(n + 4))
            |> Enum.join(" "),
          not (tag =~ ~r/class="[^"]*\bhidden\b/),
          do: "#{path}:#{n}"

    assert hits == [], "Use <.file_picker> (W-1947 §Core):\n" <> Enum.join(hits, "\n")
  end

  describe "Tools → Publish a Tool" do
    test "is a file picker that publishes, and refuses a wrong file", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/tools")
      assert bare_file_inputs(html) == []

      assert has_element?(
               view,
               "#tools-publish-form-file[data-file-picker]",
               "A tool package (.tar.gz)"
             )

      # The button is a label for the upload's own input (its id is the ref).
      {:ok, doc} = Floki.parse_document(html)
      [for] = doc |> Floki.find("#tools-publish-form-file label.btn") |> Floki.attribute("for")
      assert [_] = Floki.find(doc, "#tools-publish-form-file input[type=file][id='#{for}']")

      name = unique_name()

      input =
        file_input(view, "#tools-publish-form", :package, [
          %{name: "t.tgz", content: package(name)}
        ])

      render_upload(input, "t.tgz")
      assert has_element?(view, "#tools-publish-form-file [data-role=file-name]", "t.tgz")

      assert has_element?(
               view,
               "#tools-publish-form-file [data-role=file-size]",
               ~r/\d+(\.\d)? (B|KB)/
             )

      view |> form("#tools-publish-form") |> render_submit()
      assert {path, _} = assert_redirect(view)
      assert path == "/tools/#{name}?version=1.0.0"
    end

    test "the × takes the chosen file back", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/tools")
      input = file_input(view, "#tools-publish-form", :package, [%{name: "t.tgz", content: "x"}])
      render_upload(input, "t.tgz")

      view
      |> element("#tools-publish-form-file button[aria-label='Remove t.tgz']")
      |> render_click()

      refute has_element?(view, "#tools-publish-form-file [data-role=file-name]", "t.tgz")
    end
  end

  describe "Account → Import & export → Bring boards in" do
    test "is a file picker that imports", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/account/data")
      assert bare_file_inputs(html) == []
      assert has_element?(view, "#import-boards-file[data-file-picker]", "(.json), up to 8 MB")

      document = user |> Portable.export() |> Jason.encode!()

      view
      |> file_input("#import-boards", :board_document, [
        %{name: "boards.json", content: document, type: "application/json"}
      ])
      |> render_upload("boards.json")

      assert has_element?(view, "#import-boards-file [data-role=file-name]", "boards.json")
      html = view |> element("#import-boards") |> render_submit()
      assert html =~ "came in"
    end

    test "a file that isn't .json is refused with what is wanted", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account/data")

      input =
        file_input(view, "#import-boards", :board_document, [
          %{name: "boards.csv", content: "a,b", type: "text/csv"}
        ])

      assert {:error, [[_, :not_accepted]]} = render_upload(input, "boards.csv")

      assert has_element?(
               view,
               "#import-boards-file [data-role=file-error]",
               "That kind of file isn't accepted here. A .json file, up to 7.6 MB."
             )

      assert has_element?(view, "#import-boards-file.file-picker-error")
    end
  end

  describe "Account → Voiceprint" do
    setup do
      meetings_on()

      {:ok, _} =
        Settings.update(%{
          "meetings_voiceprints" => true,
          "meetings_voiceprint_url" => "http://voice.example/embed"
        })

      :ok
    end

    test "the recording is a file picker; the × takes it back", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/account/voiceprint")
      assert bare_file_inputs(html) == []
      assert has_element?(view, "#voiceprint-recording-file[data-file-picker]")

      view
      |> file_input("#voiceprint-recording", :recording, [
        %{name: "me.wav", content: "MY VOICE", type: "audio/wav"}
      ])
      |> render_upload("me.wav")

      assert has_element?(view, "#voiceprint-recording-file [data-role=file-size]", "8 B")

      view
      |> element("#voiceprint-recording-file button[aria-label='Remove me.wav']")
      |> render_click()

      refute has_element?(view, "#voiceprint-recording-file [data-role=file-name]", "me.wav")
    end

    test "a file that isn't audio is refused", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account/voiceprint")

      input =
        file_input(view, "#voiceprint-recording", :recording, [
          %{name: "me.txt", content: "hello", type: "text/plain"}
        ])

      assert {:error, [[_, :not_accepted]]} = render_upload(input, "me.txt")

      assert has_element?(
               view,
               "#voiceprint-recording-file [data-role=file-error]",
               "isn't accepted"
             )
    end
  end

  test "the other pages' hidden file inputs sit behind their own buttons", %{conn: conn} do
    board = board_fixture(%{"name" => "Files"}, owner: user_fixture())
    card = card_fixture(hd(board.columns), %{"title" => "With files"})
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    assert bare_file_inputs(html) == []
  end
end
