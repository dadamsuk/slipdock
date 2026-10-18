defmodule SlipdockWeb.Meetings.ChatGateTest do
  @moduledoc """
  Chat capture's own switch (#1075): on by default and independent of
  meeting mode. While either is on, the review routes, pages and MCP tools
  are there; sending a meeting stays meeting mode's; and a capture whose own
  kind is off is not there at all.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Meetings, Settings}
  alias Slipdock.Meetings.Ingest

  setup %{user: user} do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    board = board_fixture(%{"name" => "Pricing"}, owner: user)

    {:ok, chat} =
      Ingest.ingest(board, user, %{kind: "chat", transcript: "User: hi\nClaude: hello"})

    # A meeting sent while meeting mode was on, which is then turned off.
    {:ok, _} = Settings.update(%{"meetings_enabled" => true})
    {:ok, meeting} = Ingest.ingest(board, user, %{transcript: "Priya: hi\nSam: hello"})
    {:ok, _} = Settings.update(%{"meetings_enabled" => false})

    %{board: board, chat: chat, meeting: meeting}
  end

  defp tool_names, do: Enum.map(SlipdockWeb.MCP.Tools.all(), & &1.name())

  test "chat capture is on by default, and the mode says so", %{conn: conn} do
    assert Settings.get().chat_capture_enabled == true
    assert Meetings.chat_enabled?()
    refute Meetings.enabled?()
    assert Meetings.capture_enabled?()

    assert %{"meetings" => %{"enabled" => false, "chat_enabled" => true}} =
             conn |> get(~p"/api/meetings") |> json_response(200)
  end

  describe "chat on, meeting mode off" do
    test "MCP lists the review tools but not capture_meeting" do
      names = tool_names()
      assert ~w(get_capture resolve_capture_question commit_capture) -- names == []
      refute "capture_meeting" in names
    end

    test "the API shows the chat, not the meeting", %{conn: conn, board: board} = ctx do
      assert %{"capture" => %{"id" => id}} =
               conn |> get(~p"/api/captures/#{ctx.chat.id}") |> json_response(200)

      assert id == ctx.chat.id

      assert %{"error" => "capture not found"} =
               conn |> get(~p"/api/captures/#{ctx.meeting.id}") |> json_response(404)

      ids =
        conn
        |> get(~p"/api/boards/#{board.id}/captures")
        |> json_response(200)
        |> Map.fetch!("captures")
        |> Enum.map(& &1["id"])

      assert ids == [ctx.chat.id]
    end

    test "a chat can be sent; a meeting cannot", %{conn: conn, board: board} do
      assert %{"capture" => %{"kind" => "chat"}} =
               conn
               |> post(~p"/api/boards/#{board.id}/captures", %{
                 "kind" => "chat",
                 "transcript" => "User: ship it?\nAssistant: yes"
               })
               |> json_response(201)

      assert %{"code" => "meetings_off", "error" => "meeting mode is off on this server"} =
               conn
               |> post(~p"/api/boards/#{board.id}/captures", %{"transcript" => "Priya: hi"})
               |> json_response(404)
    end

    test "the chat's review page opens; the meeting's and the Meetings list do not",
         %{conn: conn, board: board} = ctx do
      assert {:ok, _view, _html} = live(conn, ~p"/boards/#{board}/meetings/#{ctx.chat.id}")

      assert_raise SlipdockWeb.MeetingsOff, fn ->
        live(conn, ~p"/boards/#{board}/meetings/#{ctx.meeting.id}")
      end

      assert_raise SlipdockWeb.MeetingsOff, fn -> live(conn, ~p"/boards/#{board}/meetings") end
    end

    test "voiceprints stay meeting mode's", %{conn: conn} do
      assert %{"code" => "meetings_off"} =
               conn |> get(~p"/api/me/voiceprint") |> json_response(404)
    end

    test "the guide lists the capture routes, but has no meeting section", %{conn: conn} do
      body = conn |> get(~p"/api/guide") |> response(200)
      assert body =~ "/api/captures/:id"
      refute body =~ "## Meeting capture"
    end
  end

  describe "meeting mode on, chat off" do
    setup do
      {:ok, _} =
        Settings.update(%{"meetings_enabled" => true, "chat_capture_enabled" => false})

      :ok
    end

    test "every capture tool but the chat is offered; the chat is not there",
         %{conn: conn, board: board} = ctx do
      assert ~w(capture_meeting get_capture resolve_capture_question commit_capture) --
               tool_names() == []

      assert conn |> get(~p"/api/captures/#{ctx.chat.id}") |> json_response(404)
      assert conn |> get(~p"/api/captures/#{ctx.meeting.id}") |> json_response(200)

      assert %{"code" => "chat_capture_off", "error" => "chat capture is off on this server"} =
               conn
               |> post(~p"/api/boards/#{board.id}/captures", %{
                 "kind" => "chat",
                 "transcript" => "User: hi"
               })
               |> json_response(404)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/meetings")
      assert has_element?(view, "#capture-#{ctx.meeting.id}")
      refute has_element?(view, "#capture-#{ctx.chat.id}")
    end
  end

  test "both off: no capture tool at all" do
    {:ok, _} = Settings.update(%{"chat_capture_enabled" => false})
    refute Meetings.capture_enabled?()

    assert Enum.all?(
             ~w(capture_meeting get_capture resolve_capture_question commit_capture),
             &(&1 not in tool_names())
           )
  end

  test "Configuration › Meetings turns chat capture off and on", %{conn: conn, user: user} do
    {:ok, _} = Accounts.promote(user)
    {:ok, view, _html} = live(conn, ~p"/config/meetings")
    assert has_element?(view, "#chat-capture-enabled[checked]")

    view |> form("#meetings-form", settings: %{chat_capture_enabled: "false"}) |> render_submit()
    refute Meetings.chat_enabled?()

    view |> form("#meetings-form", settings: %{chat_capture_enabled: "true"}) |> render_submit()
    assert Meetings.chat_enabled?()
  end
end
