defmodule SlipdockWeb.Meetings.AnalysingLiveTest do
  @moduledoc """
  The Analysing screen (#536, screen 3): the steps as they go, findings as
  they are found (dropped ones with why), live without a reload; a failure
  with its reason and a Retry; and the same over the API.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{AIStub, Meetings}
  alias Slipdock.Meetings.Pipeline

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    capture = capture_fixture(board, user)
    %{board: board, capture: capture}
  end

  @decision %{
    "kind" => "decision",
    "title" => "Annual plan at 20% off",
    "evidence" => [%{"line" => "L2", "quote" => "We go with the annual plan at 20% off."}]
  }

  @made_up %{
    "kind" => "action",
    "title" => "Invented",
    "evidence" => [%{"line" => "L1", "quote" => "nobody said this"}]
  }

  test "the steps move along and the findings appear, without a reload", %{
    conn: conn,
    board: board,
    capture: capture
  } do
    AIStub.reply_with(%{"findings" => [@decision, @made_up]})
    capture = Pipeline.start(capture, mode: :manual)
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}")

    assert has_element?(view, "#step-ingest[data-state=done]")
    assert has_element?(view, "#step-transcribe[data-state=running]")
    assert has_element?(view, "#step-read[data-state=pending]")
    assert render(view) =~ "You can leave this page"

    capture = Pipeline.run(capture, stop_after: "context")
    assert has_element?(view, "#step-context[data-state=done]")
    assert has_element?(view, "#step-read[data-state=running]")

    Pipeline.run(capture)

    html = render(view)
    assert html =~ "Annual plan at 20% off"
    assert html =~ "Dropped: its quote is not in the transcript"
    assert view |> element("#capture-state") |> render() =~ "ready"
    refute has_element?(view, "#capture-analysing")
  end

  test "a failure shows why, and Retry carries on", %{conn: conn, board: board, capture: capture} do
    AIStub.fail_with(503, "the upstream model is overloaded")
    Pipeline.start(capture, mode: :sync)

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}")
    assert view |> element("#capture-failure") |> render() =~ "overloaded"
    assert has_element?(view, "#step-read[data-state=failed]")

    AIStub.reply_with(%{"findings" => [@decision]})
    Slipdock.TestConfig.merge(:meetings, pipeline: :sync)
    view |> element("#retry-capture") |> render_click()

    assert Meetings.get_capture!(capture.id).state == "ready"
    assert view |> element("#capture-state") |> render() =~ "ready"
  end

  test "somebody who can only read sees the failure but no Retry", %{
    board: board,
    capture: capture
  } do
    AIStub.fail_with(500, "boom")
    Pipeline.start(capture, mode: :sync)

    reader = user_fixture("reader@example.com")
    share_fixture(board, [reader], "read")
    {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{board}/meetings/#{capture.id}")

    assert has_element?(view, "#capture-failure")
    refute has_element?(view, "#retry-capture")
  end

  test "POST /api/captures/:id/retry carries a failed one on, and refuses anything else", %{
    conn: conn,
    capture: capture
  } do
    body = conn |> post(~p"/api/captures/#{capture.id}/retry") |> json_response(409)
    assert body["error"] == "only a failed capture can be retried (this one is receiving)"

    AIStub.fail_with(503, "down")
    Pipeline.start(capture, mode: :sync)
    AIStub.reply_with(%{"findings" => []})
    Slipdock.TestConfig.merge(:meetings, pipeline: :sync)

    body = conn |> post(~p"/api/captures/#{capture.id}/retry") |> json_response(200)
    assert body["capture"]["state"] == "ready"
  end

  test "a transcript sent through the API is read straight through when the pipeline runs", %{
    conn: conn,
    board: board
  } do
    Slipdock.TestConfig.merge(:meetings, pipeline: :sync)
    AIStub.reply_with(%{"findings" => [@decision]})

    body =
      conn
      |> post(~p"/api/boards/#{board.id}/captures", %{
        "transcript" => transcript() <> "\nSam: once more"
      })
      |> json_response(201)

    assert body["capture"]["state"] == "ready"

    assert [%{"title" => "Annual plan at 20% off", "status" => "kept"}] =
             body["capture"]["findings"]
  end
end
