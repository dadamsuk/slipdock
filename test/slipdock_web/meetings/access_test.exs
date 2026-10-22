defmodule SlipdockWeb.Meetings.AccessTest do
  @moduledoc """
  Meetings, recording transcription and voiceprints are for the people an
  admin turns them on for, and for admins (#1206). For anybody else, with
  meeting mode on, it is as though it were off: no tab, no pages, no meeting
  routes or MCP tool, no voiceprint, no transcribing a card's recording, and
  the API says why. Chat capture is not a meeting, and stays theirs.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Accounts, Boards, Meetings, Settings, Transcription}
  alias Slipdock.Meetings.Ingest

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    # Sent while they were allowed; then an admin takes it away.
    {:ok, meeting} = Ingest.ingest(board, user, %{transcript: "Priya: hi\nSam: hello"})
    {:ok, chat} = Ingest.ingest(board, user, %{kind: "chat", transcript: "User: hi\nClaude: yo"})
    %{board: board, meeting: meeting, chat: chat, user: no_meetings(user)}
  end

  defp rpc(conn, method, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
    |> json_response(200)
  end

  describe "who is allowed" do
    test "admins always, anybody else only with the switch on", %{user: user} do
      refute Meetings.allowed?(user)
      refute Meetings.allowed?(nil)
      assert Meetings.allowed?(allow_meetings(user))
      {:ok, admin} = Accounts.promote(user)
      assert Meetings.allowed?(no_meetings(admin))
    end

    test "allowed is not enough while meeting mode is off", %{user: user} do
      user = allow_meetings(user)
      assert Meetings.enabled_for?(user)
      {:ok, _} = Settings.update(%{"meetings_enabled" => false})
      refute Meetings.enabled_for?(user)
      assert Meetings.off_message(user) == "meeting mode is off on this server"
      assert Meetings.off_code(user) == "meetings_off"
    end

    test "somebody not allowed sees none of it on a board", %{user: user, board: board} do
      refute Meetings.enabled_for?(user)
      refute Meetings.available?(user)
      assert Meetings.presence(user, board) == :none
      refute Meetings.kind_enabled_for?("meeting", user)
      assert Meetings.kind_enabled_for?("chat", user)
      assert Meetings.capture_enabled_for?(user)
      assert Meetings.off_code(user) == "meetings_not_allowed"
      assert Meetings.off_message(user) =~ "an admin can turn them on"

      assert Meetings.presence(allow_meetings(user), board) != :none
    end
  end

  describe "the API, for somebody not allowed" do
    test "the mode says it isn't on for them", %{conn: conn} do
      assert %{"meetings" => %{"enabled" => false, "allowed" => false, "chat_enabled" => true}} =
               conn |> get(~p"/api/meetings") |> json_response(200)
    end

    test "a meeting can't be sent, and says why; a chat can", %{conn: conn, board: board} do
      assert %{"code" => "meetings_not_allowed", "error" => error} =
               conn
               |> post(~p"/api/boards/#{board.id}/captures", %{"transcript" => "Priya: hi"})
               |> json_response(404)

      assert error =~ "aren't turned on for you"

      assert %{"capture" => %{"kind" => "chat"}} =
               conn
               |> post(~p"/api/boards/#{board.id}/captures", %{
                 "kind" => "chat",
                 "transcript" => "User: ship it?\nAssistant: yes"
               })
               |> json_response(201)
    end

    test "their board's meetings aren't there; its chats are", %{conn: conn} = ctx do
      assert conn |> get(~p"/api/captures/#{ctx.meeting.id}") |> json_response(404)
      assert conn |> get(~p"/api/captures/#{ctx.chat.id}") |> json_response(200)

      ids =
        conn
        |> get(~p"/api/boards/#{ctx.board.id}/captures")
        |> json_response(200)
        |> Map.fetch!("captures")
        |> Enum.map(& &1["id"])

      assert ids == [ctx.chat.id]
    end

    test "voiceprints aren't there", %{conn: conn} do
      assert %{"code" => "meetings_not_allowed"} =
               conn |> get(~p"/api/me/voiceprint") |> json_response(404)
    end

    test "with only meeting mode on, the meeting routes say why", %{conn: conn} do
      {:ok, _} = Settings.update(%{"chat_capture_enabled" => false})

      assert %{"code" => "meetings_not_allowed"} =
               conn |> get(~p"/api/meetings") |> json_response(404)
    end

    test "allowed again, it all comes back", %{conn: conn, user: user} = ctx do
      allow_meetings(user)

      assert %{"meetings" => %{"enabled" => true, "allowed" => true}} =
               conn |> get(~p"/api/meetings") |> json_response(200)

      assert conn |> get(~p"/api/captures/#{ctx.meeting.id}") |> json_response(200)
    end
  end

  describe "MCP, for somebody not allowed" do
    test "capture_meeting isn't listed or callable; capture_chat is", %{conn: conn} = ctx do
      names = rpc(conn, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
      refute "capture_meeting" in names
      assert "capture_chat" in names
      assert "get_capture" in names

      assert rpc(conn, "tools/call", %{
               name: "capture_meeting",
               arguments: %{board: ctx.board.id, transcript: "Priya: hi"}
             })["error"]["message"] =~ "unknown tool"
    end

    test "allowed, capture_meeting is listed", %{conn: conn, user: user} do
      allow_meetings(user)
      names = rpc(conn, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
      assert "capture_meeting" in names
    end
  end

  describe "pages, for somebody not allowed" do
    test "the Meetings list, a meeting and New are not there",
         %{conn: conn, board: board} = ctx do
      assert_raise SlipdockWeb.MeetingsOff, fn -> live(conn, ~p"/boards/#{board}/meetings") end

      assert_raise SlipdockWeb.MeetingsOff, fn ->
        live(conn, ~p"/boards/#{board}/meetings/new")
      end

      assert_raise SlipdockWeb.MeetingsOff, fn ->
        live(conn, ~p"/boards/#{board}/meetings/#{ctx.meeting.id}")
      end
    end

    test "a chat's page opens as a Conversation, with no Meetings to go to",
         %{conn: conn, board: board} = ctx do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/meetings/#{ctx.chat.id}")
      refute has_element?(view, "#view-menu-meetings")
      refute has_element?(view, ~s(nav a[href="/boards/#{board.id}/meetings"]))
    end

    test "the board has no Meetings tab", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      refute has_element?(view, "#view-menu-meetings")
    end

    test "a meeting's recording isn't served", %{conn: conn} = ctx do
      assert conn |> get(~p"/captures/#{ctx.meeting.id}/audio") |> response(404)
    end
  end

  describe "a card's recording, for somebody not allowed" do
    setup %{board: board} do
      {:ok, _} = Settings.update(%{"transcription_server_url" => "http://transcribe.example"})
      card = card_fixture(hd(board.columns))
      path = Path.join(System.tmp_dir!(), "call-#{System.unique_integer([:positive])}.mp3")
      File.write!(path, "ID3 fake")
      on_exit(fn -> File.rm(path) end)

      {:ok, audio} =
        Boards.add_attachment(card, %{filename: "call.mp3", content_type: "audio/mpeg"}, path)

      %{card: card, audio: audio}
    end

    test "can't be sent to the transcription server", %{conn: conn, card: card, audio: audio} do
      assert %{"error" => error} =
               conn
               |> post(~p"/api/cards/#{card.id}/attachments/#{audio.id}/transcribe")
               |> json_response(403)

      assert error =~ "Transcription isn't turned on for you"
      assert Boards.get_attachment!(audio.id).transcript_status == nil
    end

    test "has no Transcribe button on the card", %{conn: conn, board: board, card: card} = ctx do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
      refute has_element?(view, "#transcribe-#{ctx.audio.id}")

      allow_meetings(ctx.user)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
      assert has_element?(view, "#transcribe-#{ctx.audio.id}")
      assert Transcription.available_to?(Accounts.get_user!(ctx.user.id))
    end
  end

  describe "voiceprints, for somebody not allowed" do
    setup do
      {:ok, _} =
        Settings.update(%{
          "meetings_voiceprints" => true,
          "meetings_voiceprint_url" => "http://voice.example/embed",
          "transcription_server_url" => "http://transcribe.example",
          "transcription_voiceprints" => true
        })

      :ok
    end

    test "they can't enrol, and naming a voice teaches the server nothing", %{user: user} do
      assert Meetings.Voiceprints.enabled?()
      refute Meetings.Voiceprints.enabled_for?(user)
      assert Meetings.Voiceprints.offers(user) == []

      assert {:error, :off} =
               Meetings.Voiceprints.enrol(user, {:recording, "/nope", "me.wav"},
                 consent: Meetings.Voiceprints.wording_version()
               )

      assert Transcription.Voiceprints.enabled?()
      refute Transcription.Voiceprints.enabled_for?(user)
      page = %Slipdock.Wiki.Page{id: 0, body: ""}
      assert Transcription.Voiceprints.page_named(page, "Priya Nair", by: user) == :off
      assert Transcription.Voiceprints.page_named(page, "Priya Nair") == :off

      assert Meetings.Voiceprints.enabled_for?(allow_meetings(user))
      assert Transcription.Voiceprints.enabled_for?(user |> allow_meetings())
    end

    test "the account's Voiceprint tab isn't there", %{conn: conn} do
      assert_raise SlipdockWeb.MeetingsOff, fn -> live(conn, ~p"/account/voiceprint") end
    end
  end
end
