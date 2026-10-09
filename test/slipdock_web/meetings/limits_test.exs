defmodule SlipdockWeb.Meetings.LimitsTest do
  @moduledoc """
  The limits where people meet them (#544): a 402 from the API that names
  the limit and says not to retry, the allowance on the upload page, the
  admin's limits and this month's totals in Configuration › Meetings, and
  the same totals over the admin API.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Accounts, Settings}
  alias Slipdock.Meetings.Usage

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    %{board: board}
  end

  test "over a limit, the API answers 402, naming it, not to be retried", %{
    conn: conn,
    board: board
  } do
    {:ok, _} =
      Settings.update(%{
        "meetings_transcript_captures" => 0,
        "meetings_transcript_captures_enabled" => true
      })

    body =
      conn
      |> post(~p"/api/boards/#{board.id}/captures", %{"transcript" => "Sam: hi"})
      |> json_response(402)

    assert body["error"] == "meeting_limit_reached"
    assert body["message"] =~ "the most this server allows (0)"
    assert body["retryable"] == false
  end

  test "the upload page says what is left, and why a meeting was refused", %{
    conn: conn,
    board: board
  } do
    {:ok, _} =
      Settings.update(%{
        "meetings_transcript_captures" => 1,
        "meetings_transcript_captures_enabled" => true
      })

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/new")
    assert view |> element("#capture-allowance") |> render() =~ "1 of 1 captures from transcripts"

    view |> form("#new-capture-form", capture: %{pasted: "Sam: first"}) |> render_submit()
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/new")
    assert view |> element("#capture-allowance") |> render() =~ "0 of 1 captures from transcripts"

    html = view |> form("#new-capture-form", capture: %{pasted: "Sam: second"}) |> render_submit()
    assert html =~ "the most this server allows (1)"
  end

  describe "the admin" do
    setup %{user: user} do
      {:ok, admin} = Accounts.promote(user)
      %{admin: admin}
    end

    test "sets the limits and sees this month's totals and heaviest users", %{
      conn: conn,
      board: board,
      user: user
    } do
      capture = capture_fixture(board, user)
      Usage.record(capture, %{kind: :transcription, seconds: 600.0, cost: 0.5})

      {:ok, view, _} = live(conn, ~p"/config/meetings")
      assert view |> element("#usage-minutes") |> render() =~ "10 min"
      assert view |> element("#usage-cost") |> render() =~ "$0.50"
      assert view |> element("#usage-heaviest") |> render() =~ user.email

      view
      |> form("#meetings-form",
        settings: %{
          meetings_transcription_minutes: "90",
          meetings_transcription_minutes_enabled: "true",
          meetings_audio_retention: "90_days",
          meetings_max_file_mb: "50"
        }
      )
      |> render_submit()

      assert %{transcription_minutes: 90, max_file_mb: 50} = Usage.limits()
      assert Settings.get().meetings_audio_retention == "90_days"
    end

    test "a longest meeting of no minutes is refused", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config/meetings")

      view
      |> form("#meetings-form", settings: %{meetings_longest_minutes: "0"})
      |> render_submit()

      assert Settings.get().meetings_longest_minutes == 240
    end

    test "GET /api/admin/meetings/usage, and the limits in the settings", %{
      admin: admin,
      board: board,
      user: user
    } do
      capture = capture_fixture(board, user)
      Usage.record(capture, %{kind: :reading, tokens_in: 100, tokens_out: 20})
      {token, _} = Accounts.create_api_token(admin, "admin", scope: "admin")
      conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

      body = conn |> get(~p"/api/admin/meetings/usage") |> json_response(200)
      assert body["usage"]["tokens"] == 120

      settings = conn |> get(~p"/api/admin/settings") |> json_response(200)
      assert settings["settings"]["meetings"]["limits"]["transcription_minutes"] == 600
      assert settings["settings"]["meetings"]["audio_retention"] == "30_days"
    end
  end
end
