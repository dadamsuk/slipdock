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
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
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
    page = meeting(board, "recording: manuel2://play?file=x.m4a", "Old note.")
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    refute has_element?(view, player(page) <> "[data-recording-src]")
  end

  test "a vault with no recordings folder says so in the player", ctx do
    %{conn: conn, board: board, vault: vault} = ctx
    vault |> Ecto.Changeset.change(recordings_folder: nil) |> Repo.update!()
    page = meeting(board, "recording: gdrive:Rec/m.m4a", @recording_section)

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert has_element?(view, player(page) <> "[data-recording-problem='no_folder']")
  end

  test "a board in no vault is the same as no folder", %{conn: conn, user: user} do
    loose = board_fixture(%{"name" => "Loose"}, owner: user)
    page = meeting(loose, "recording: gdrive:Rec/m.m4a", @recording_section)

    {:ok, view, _html} = live(conn, ~p"/boards/#{loose}/wiki/#{page.slug}")
    assert has_element?(view, player(page) <> "[data-recording-problem='no_folder']")
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
end
