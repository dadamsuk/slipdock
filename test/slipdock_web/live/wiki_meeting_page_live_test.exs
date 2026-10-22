defmodule SlipdockWeb.WikiMeetingPageLiveTest do
  @moduledoc """
  A meeting page in the W-1690 format: `recording: gdrive:…` in its front
  matter, a `## Recording` section and the transcript in a ```vtt block. The
  page is wired to the player (assets/js/transcript_player.js), and drawing
  it never asks Google Drive anything.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.GoogleStub

  alias Slipdock.{Repo, Vaults}

  @transcript """
  ## Transcript

  ```vtt
  WEBVTT

  1
  00:00:01.500 --> 00:00:03.250
  <v Alice>Shall we start?

  2
  00:00:04.000 --> 00:00:06.000
  <v Bob>Yes.
  ```
  """

  @recording_section """
  ## Recording

  [▶ Play recording and transcript](#recording)
  """

  setup %{user: user} do
    board = board_fixture(%{"name" => "Notes"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
    vault = vault |> Ecto.Changeset.change(recordings_folder: "Rec") |> Repo.update!()
    connect!(user)
    # Drawing a page must never reach Drive.
    stub(fn _conn -> flunk("rendering a page asked Google Drive") end)
    %{board: board, vault: vault}
  end

  defp meeting(board, front_matter, body) do
    page_fixture(board, %{
      "title" => "Meeting #{System.unique_integer([:positive])}",
      "front_matter" => front_matter && "---\n" <> front_matter <> "\n---\n\n",
      "body" => body
    })
  end

  defp player(page), do: "#wiki-player-#{page.id}[phx-hook=TranscriptPlayer]"

  test "a page with a recording and a transcript", %{conn: conn, board: board} do
    page =
      meeting(
        board,
        "type: meeting\nrecording: gdrive:Rec/2026-09/m.m4a",
        "Summary.\n\n" <> @recording_section <> "\n" <> @transcript
      )

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    assert has_element?(
             view,
             player(page) <> "[data-recording-src='/wiki-pages/#{page.id}/recording']"
           )

    refute has_element?(view, player(page) <> "[data-recording-problem]")
    assert has_element?(view, player(page) <> " #wiki-body h2#recording")

    assert has_element?(
             view,
             player(page) <> " #wiki-body a[href='#recording']",
             "Play recording"
           )

    assert has_element?(
             view,
             "#wiki-body article[data-transcript] li[data-start-ms='1500'][data-speaker='Alice']"
           )

    assert has_element?(view, "#wiki-body li[data-start-ms='4000'][data-end-ms='6000']", "Yes.")
  end

  test "a recording with no transcript still gets the player", %{conn: conn, board: board} do
    page = meeting(board, "recording: gdrive:Rec/m.m4a", "Summary.\n\n" <> @recording_section)
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    assert has_element?(view, player(page) <> "[data-recording-src]")
    refute has_element?(view, "#wiki-body [data-transcript]")
  end

  test "a transcript with no recording is searchable, with nothing to play", %{
    conn: conn,
    board: board
  } do
    page = meeting(board, nil, @transcript)
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    assert has_element?(view, player(page))
    refute has_element?(view, player(page) <> "[data-recording-src]")
    assert has_element?(view, "#wiki-body [data-transcript]")
  end

  test "a recording that isn't on Drive is not a player", %{conn: conn, board: board} do
    page = meeting(board, "recording: custom://play?file=x.m4a", "Old note.")
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    refute has_element?(view, player(page) <> "[data-recording-src]")
  end

  test "a vault with no recordings folder says so in the player", ctx do
    %{conn: conn, board: board, vault: vault} = ctx
    vault |> Ecto.Changeset.change(recordings_folder: nil) |> Repo.update!()
    page = meeting(board, "recording: gdrive:Rec/m.m4a", @recording_section)

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert has_element?(view, player(page) <> "[data-recording-problem='no_folder']")

    # #784: the owner is given the setting itself, and no name to ask.
    assert has_element?(
             view,
             player(page) <> "[data-settings-url='/vaults#recordings-folder-#{vault.id}']"
           )

    refute has_element?(view, player(page) <> "[data-vault-owner]")
  end

  test "somebody else reading it is told whom to ask, with no link", ctx do
    %{board: board, vault: vault, user: owner} = ctx
    vault |> Ecto.Changeset.change(recordings_folder: nil) |> Repo.update!()
    page = meeting(board, "recording: gdrive:Rec/m.m4a", @recording_section)
    reader = user_fixture("reader@example.com")
    share_fixture(board, reader, "read")

    {:ok, view, _html} =
      live(log_in_user(build_conn(), reader), ~p"/boards/#{board}/wiki/#{page.slug}")

    assert has_element?(view, player(page) <> "[data-recording-problem='no_folder']")
    refute has_element?(view, player(page) <> "[data-settings-url]")

    assert has_element?(
             view,
             player(page) <>
               "[data-vault-owner='#{Slipdock.Accounts.User.display_name(owner)}']"
           )
  end

  test "a board in no vault says so, with no settings link", %{conn: conn, user: user} do
    loose = board_fixture(%{"name" => "Loose"}, owner: user)
    page = meeting(loose, "recording: gdrive:Rec/m.m4a", @recording_section)

    {:ok, view, _html} = live(conn, ~p"/boards/#{loose}/wiki/#{page.slug}")
    assert has_element?(view, player(page) <> "[data-recording-problem='no_vault']")
    refute has_element?(view, player(page) <> "[data-settings-url]")
    refute has_element?(view, player(page) <> "[data-vault-owner]")
  end

  test "a page with a folder to play from brings no settings help", %{conn: conn, board: board} do
    page = meeting(board, "recording: gdrive:Rec/m.m4a", @recording_section)
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    refute has_element?(view, player(page) <> "[data-recording-problem]")
    refute has_element?(view, player(page) <> "[data-settings-url]")
  end

  test "a server without Google says so", %{conn: conn, board: board} do
    Slipdock.TestConfig.put(:google, [])
    page = meeting(board, "recording: gdrive:Rec/m.m4a", @recording_section)

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert has_element?(view, player(page) <> "[data-recording-problem='not_configured']")
  end

  test "an embedded meeting shows its transcript but brings no player", %{
    conn: conn,
    board: board
  } do
    meeting =
      page_fixture(board, %{
        "title" => "Standup",
        "front_matter" => "---\nrecording: gdrive:Rec/m.m4a\n---\n\n",
        "body" => @recording_section <> "\n" <> @transcript
      })

    host = meeting(board, nil, "Notes from the week.\n\n![[Standup]]\n")
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{host.slug}")

    assert has_element?(view, "#wiki-body .wiki-embed [data-transcript]")
    refute has_element?(view, player(host) <> "[data-recording-src]")
    assert meeting.id
  end

  describe "naming a voice (#1157)" do
    test "an editor can rename a speaker, saved as a revision", %{conn: conn, board: board} do
      page = meeting(board, "type: meeting", @transcript)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      assert has_element?(view, player(page) <> "[data-can-name-speakers='true']")
      assert has_element?(view, "#wiki-body .wiki-transcript-speaker", "Alice")

      html = render_hook(view, "rename_speaker", %{"from" => "Alice", "to" => " Priya Shah "})

      assert html =~ "“Alice” is now “Priya Shah” in the transcript."
      refute html =~ "voiceprint"
      assert has_element?(view, "#wiki-body li[data-speaker='Priya Shah']")
      refute has_element?(view, "#wiki-body li[data-speaker='Alice']")
      assert has_element?(view, "#wiki-body li[data-speaker='Bob']")

      saved = Slipdock.Wiki.get_page!(page.id)
      assert saved.body =~ "<v Priya Shah>Shall we start?"
      assert [latest | _] = Slipdock.Wiki.list_revisions(saved)
      assert latest.summary == "named the voice “Alice” “Priya Shah”"
    end

    test "with voiceprints on, the flash says their voice goes to the server (#1201)", %{
      conn: conn,
      board: board
    } do
      {:ok, _} = Slipdock.Settings.complete_setup(%{"admin_email" => "admin@example.com"})

      {:ok, _} =
        Slipdock.Settings.update(%{
          "transcription_server_url" => "https://transcribe.example:8765",
          "transcription_voiceprints" => true
        })

      page = meeting(board, "type: meeting", @transcript)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      # Alice's 1.75 s is too short to send, so nothing is asked of a server.
      assert render_hook(view, "rename_speaker", %{"from" => "Alice", "to" => "Priya Shah"}) =~
               "Their longest stretch goes to the transcription server as a voiceprint."

      refute render_hook(view, "rename_speaker", %{"from" => "Bob", "to" => "Speaker 2"}) =~
               "voiceprint"
    end

    test "a name that won't do is refused and nothing is saved", %{conn: conn, board: board} do
      page = meeting(board, nil, @transcript)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      assert render_hook(view, "rename_speaker", %{"from" => "Alice", "to" => "a:b"}) =~
               "without &lt;, &gt; or a colon"

      assert render_hook(view, "rename_speaker", %{"from" => "Carol", "to" => "Cat"}) =~
               "Nobody by that name speaks"

      assert render_hook(view, "rename_speaker", %{"from" => "Alice", "to" => ""}) =~
               "A voice needs a name."

      assert Slipdock.Wiki.get_page!(page.id).body == page.body
    end

    test "a reader can't rename a voice", %{board: board} do
      page = meeting(board, nil, @transcript)
      reader = user_fixture("reader@example.com")
      share_fixture(board, reader, "read")

      {:ok, view, _html} =
        live(log_in_user(build_conn(), reader), ~p"/boards/#{board}/wiki/#{page.slug}")

      refute has_element?(view, player(page) <> "[data-can-name-speakers]")
      render_hook(view, "rename_speaker", %{"from" => "Alice", "to" => "Eve"})
      assert Slipdock.Wiki.get_page!(page.id).body == page.body
    end
  end
end
