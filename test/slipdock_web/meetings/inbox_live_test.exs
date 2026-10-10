defmodule SlipdockWeb.Meetings.InboxLiveTest do
  @moduledoc """
  The board's Meetings tab as an inbox (#541, screen 4): every capture with
  its state — reading progress included — what it found and has left to
  settle, where it came from, and who committed or discarded it; discard
  keeps the record and writes nothing, and a discarded capture is never
  committed.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Meetings, Repo}
  alias Slipdock.Meetings.{Commit, Pipeline}

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    %{board: board}
  end

  test "each capture's state, counts, source and who", %{conn: conn, board: board, user: user} do
    reading = capture_fixture(board, user, %{title: "Being read", source: "agent"})
    reading = Pipeline.start(reading, mode: :manual)
    reading = Repo.update!(Ecto.Changeset.change(reading, step: "context"))

    review =
      reviewed_capture(board, user, [decision_finding(), action_finding("Sammy")], %{}, %{
        blocking: true,
        title: "Needs you"
      })

    ready = reviewed_capture(board, user, [decision_finding()], %{}, %{title: "Ready one"})
    done = reviewed_capture(board, user, [decision_finding()], %{}, %{title: "Done one"})
    {:ok, _} = Commit.commit(done, user)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings")

    assert view |> element("#capture-#{reading.id}-state") |> render() =~
             "reading — reading the meeting"

    assert view |> element("#capture-#{reading.id}") |> render() =~
             "from an agent by #{user.email}"

    row = view |> element("#capture-#{review.id}") |> render()
    assert row =~ "needs you"
    assert row =~ "2 found"
    assert row =~ "1 to settle"

    assert view |> element("#capture-#{ready.id}-state") |> render() =~ "ready"
    assert view |> element("#capture-#{done.id}") |> render() =~ "committed by #{user.email}"
    refute has_element?(view, "#discard-#{done.id}")
  end

  test "every state a capture can be in reads as itself" do
    import SlipdockWeb.MeetingLive.Components

    for state <- Slipdock.Meetings.Capture.states() do
      assert is_binary(state_label(state))
      assert state_label(state) != ""
    end
  end

  test "discard asks, keeps the record, writes nothing, and the capture can't be committed", %{
    conn: conn,
    board: board,
    user: user
  } do
    capture = reviewed_capture(board, user, [decision_finding()])
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings")

    assert view |> element("#discard-#{capture.id}") |> render() =~ "data-confirm"
    view |> element("#discard-#{capture.id}") |> render_click()

    capture = Meetings.get_capture!(capture.id)
    assert capture.state == "discarded"
    assert capture.discarded_by_id == user.id
    assert view |> element("#capture-#{capture.id}") |> render() =~ "discarded by #{user.email}"

    assert {:error, :conflict, "this capture was discarded, so nothing from it can be written"} =
             Commit.commit(capture, user)

    refute Repo.exists?(from(p in Slipdock.Wiki.Page, where: like(p.title, "Decisions /%")))

    assert Repo.exists?(
             from(e in Slipdock.Meetings.Event,
               where: e.capture_id == ^capture.id and e.data["to"] == "discarded"
             )
           )
  end

  test "a new capture appears without a reload", %{conn: conn, board: board, user: user} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings")
    assert has_element?(view, "#meetings-empty")

    capture = capture_fixture(board, user, %{title: "Fresh"})
    Meetings.broadcast(capture)
    assert has_element?(view, "#capture-#{capture.id}")
  end

  test "somebody who can only read sees the inbox but cannot discard", %{board: board, user: user} do
    capture = reviewed_capture(board, user, [decision_finding()])
    reader = user_fixture("reader@example.com")
    share_fixture(board, [reader], "read")

    {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board}/meetings")
    assert has_element?(view, "#capture-#{capture.id}")
    refute has_element?(view, "#discard-#{capture.id}")
    render_click(view, "discard", %{"id" => to_string(capture.id)})
    assert Meetings.get_capture!(capture.id).state == "ready"
  end

  test "POST /api/captures/:id/discard, and not twice", %{conn: conn, board: board, user: user} do
    capture = reviewed_capture(board, user, [decision_finding()])
    body = conn |> post(~p"/api/captures/#{capture.id}/discard") |> json_response(200)
    assert body["capture"]["state"] == "discarded"
    assert body["capture"]["discarded_by"] == user.email

    again = conn |> post(~p"/api/captures/#{capture.id}/discard") |> json_response(409)
    assert again["error"] == "this capture is discarded already"
  end
end
