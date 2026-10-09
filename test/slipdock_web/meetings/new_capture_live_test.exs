defmodule SlipdockWeb.Meetings.NewCaptureLiveTest do
  @moduledoc """
  The New capture page (#532, screen 2): the three slots, what each
  combination gets, where the data goes (named before anything is sent), and
  sending — which lands on the capture, or says what is wrong.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.Repo
  alias Slipdock.Meetings.Capture

  @dir Path.expand("../../fixtures/meetings", __DIR__)

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    %{board: board}
  end

  defp transcript_upload(view, name \\ "pricing.vtt", content \\ nil) do
    file_input(view, "#new-capture-form", :transcript, [
      %{
        name: name,
        content: content || File.read!(Path.join(@dir, name)),
        type: "text/vtt"
      }
    ])
  end

  test "names the reading model and where it is before anything is sent", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/meetings/new")
    destination = view |> element("#capture-destination") |> render()

    assert destination =~ "The transcript is read by"
    assert destination =~ "test/model"
    assert destination =~ "openrouter.ai"
    assert has_element?(view, "#start-capture[disabled]")
  end

  test "sending a transcript lands on the capture", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/meetings/new")
    upload = transcript_upload(view)
    assert render_upload(upload, "pricing.vtt") =~ "pricing.vtt"

    # The table marks what was chosen.
    assert view |> element("#combo-transcript.bg-primary\\/10") |> has_element?()

    view
    |> form("#new-capture-form", capture: %{title: "Pricing sync", attendees: "Priya, Sam"})
    |> render_submit()

    [capture] = Repo.all(Capture)
    assert capture.title == "Pricing sync"
    assert capture.transcript_format == "vtt"
    assert_redirect(view, ~p"/boards/#{board}/meetings/#{capture.id}")
  end

  test "a pasted transcript works as well as a file", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/meetings/new")

    view
    |> form("#new-capture-form", capture: %{pasted: "Priya: Hello\nSam: Hi"})
    |> render_submit()

    assert [%Capture{transcript: "Priya: Hello\nSam: Hi"}] = Repo.all(Capture)
  end

  test "a malformed file says what is wrong and stores nothing", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/meetings/new")
    upload = transcript_upload(view, "broken.json", "{\"sentences\": [")
    render_upload(upload, "broken.json")

    html = view |> form("#new-capture-form", capture: %{title: "x"}) |> render_submit()
    assert html =~ "the JSON is not valid"
    assert has_element?(view, "#capture-error")
    assert Repo.aggregate(Capture, :count) == 0
  end

  test "the same meeting again goes to the first capture", %{conn: conn, board: board, user: user} do
    first = capture_fixture(board, user, %{transcript: "Priya: Hello\nSam: Hi"})
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/meetings/new")

    view
    |> form("#new-capture-form", capture: %{pasted: "Priya: Hello\r\nSam: Hi\r\n"})
    |> render_submit()

    assert_redirect(view, ~p"/boards/#{board}/meetings/#{first.id}")
    assert Repo.aggregate(Capture, :count) == 1
  end

  test "a slot the admin switched off says so", %{conn: conn, board: board} do
    {:ok, _} = Slipdock.Settings.update(%{"meetings_accept_audio" => false})
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/meetings/new")
    assert view |> element("#slot-audio") |> render() =~ "Not accepted on this server."
  end

  test "the parent board is offered only on a sub-board", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/meetings/new")
    refute view |> element("#capture-scope") |> render() =~ "Its parent board"

    {:ok, template} = Slipdock.Boards.find_template("Simple")
    {:ok, sub} = sub_board(card_fixture(hd(board.columns), %{"title" => "Epic"}), template)
    {:ok, view, _html} = live(conn, ~p"/boards/#{sub}/meetings/new")
    assert view |> element("#capture-scope") |> render() =~ "Its parent board"
  end

  test "somebody who can only read the board cannot send one", %{board: board} do
    reader = user_fixture("reader@example.com")
    share_fixture(board, [reader], "read")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(conn_as(reader), ~p"/boards/#{board}/meetings/new")
  end
end
