defmodule SlipdockWeb.Meetings.ModeTest do
  @moduledoc """
  Meeting mode across the surfaces (#530): with it off, no route, page,
  MCP tool or guide section; with it on, where the board shows it for whom;
  and the admin's and each person's switches.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Meetings, Settings}

  setup %{user: user} do
    # A row of settings of our own, and a server that has been set up (a
    # fresh row would send every page to the setup wizard).
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    %{board: board}
  end

  defp turn_on(attrs \\ %{}),
    do: {:ok, _} = Settings.update(Map.merge(%{"meetings_enabled" => true}, attrs))

  describe "off" do
    test "the API says meeting mode is off, as a 404", %{conn: conn} do
      body = conn |> get(~p"/api/meetings") |> json_response(404)
      assert body == %{"error" => "meeting mode is off on this server", "code" => "meetings_off"}
    end

    test "the Meetings page is not there", %{conn: conn, board: board} do
      assert_raise SlipdockWeb.MeetingsOff, fn -> live(conn, ~p"/boards/#{board}/meetings") end
      assert_error_sent 404, fn -> get(conn, ~p"/boards/#{board}/meetings") end
    end

    test "the board shows neither the tab nor the menu entry", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      refute has_element?(view, "#view-menu-meetings")
      refute has_element?(view, "#board-share-capture-meeting")
    end

    test "the guide has no meetings section and lists no meeting route", %{conn: conn} do
      body = conn |> get(~p"/api/guide") |> response(200)
      refute body =~ "## Meeting capture"
      refute body =~ "/api/meetings"
    end

    test "MCP lists no meeting tool" do
      assert Enum.all?(
               SlipdockWeb.MCP.Tools.meeting_tools(),
               &(&1 not in SlipdockWeb.MCP.Tools.all())
             )

      assert SlipdockWeb.MCP.Tools.all() -- SlipdockWeb.MCP.Tools.every() == []
    end

    test "Account › Settings offers no Display choice", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account/settings")
      refute has_element?(view, "#display-settings")
    end
  end

  describe "on" do
    test "the API reports the mode", %{conn: conn} do
      turn_on()

      assert %{
               "meetings" => %{
                 "enabled" => true,
                 "visibility" => "used_only",
                 "hideable" => true,
                 "hidden" => false
               }
             } = conn |> get(~p"/api/meetings") |> json_response(200)
    end

    test "used_only: a board with no captures has only the menu entry", %{
      conn: conn,
      board: board
    } do
      turn_on()
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      assert has_element?(
               view,
               "#board-share-capture-meeting[href='/boards/#{board.id}/meetings']"
             )

      refute has_element?(view, "#view-menu-meetings")
    end

    test "used_only: after its first capture the board has a Meetings tab", %{
      conn: conn,
      board: board
    } do
      turn_on()
      Meetings.mark_used(board)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      assert has_element?(view, "#view-menu-meetings")
      refute has_element?(view, "#board-share-capture-meeting")

      # The other card views and the wiki carry the same tab.
      {:ok, table, _html} = live(conn, ~p"/boards/#{board}/table")
      assert has_element?(table, "#view-menu-meetings")
      {:ok, wiki, _html} = live(conn, ~p"/boards/#{board}/wiki")
      assert has_element?(wiki, "#view-menu-meetings")
    end

    test "every_board: the tab on a board that never had a capture", %{
      conn: conn,
      board: board
    } do
      turn_on(%{"meetings_visibility" => "every_board"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      assert has_element?(view, "#view-menu-meetings")
    end

    test "a read-only member is not offered a capture they could not make", %{board: board} do
      turn_on()
      reader = user_fixture("reader@example.com")
      share_fixture(board, [reader], "read")

      {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{board}")
      refute has_element?(view, "#board-share-capture-meeting")
    end

    test "the Meetings page opens, beside the board's other views", %{conn: conn, board: board} do
      turn_on()
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/meetings")
      assert html =~ "No meetings captured here yet"
      assert has_element?(view, "#view-menu-meetings[aria-current='page']")
    end

    test "the Meetings page of somebody else's board is not theirs to read", %{board: board} do
      turn_on()
      stranger = user_fixture("stranger@example.com")

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn_as(stranger), ~p"/boards/#{board}/meetings")
    end

    test "the guide gains its meetings section, and lists the route", %{conn: conn} do
      turn_on()
      body = conn |> get(~p"/api/guide") |> response(200)
      assert body =~ "## Meeting capture"
      assert body =~ "GET    /api/meetings"
      assert body =~ "POST   /api/captures/:id/commit"
      assert body =~ "Answer a capture's questions only with the"
      assert body =~ "A reading is selective"

      # Every tool offered while it is on is named in the guide.
      for tool <- SlipdockWeb.MCP.Tools.meeting_tools(), do: assert(body =~ "`#{tool.name()}`")
    end

    test "turning it back off takes it all away again", %{conn: conn, board: board} do
      turn_on()
      Meetings.mark_used(board)
      {:ok, _} = Settings.update(%{"meetings_enabled" => false})

      assert conn |> get(~p"/api/meetings") |> json_response(404)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      refute has_element?(view, "#view-menu-meetings")
    end
  end

  describe "hidden by the person" do
    setup %{user: user, board: board} do
      turn_on(%{"meetings_visibility" => "every_board"})
      Meetings.mark_used(board)
      {:ok, user} = Accounts.update_display(user, %{"hide_meetings" => true})
      %{conn: conn_as(user)}
    end

    test "they see no meetings UI, even on a board with captures", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      refute has_element?(view, "#view-menu-meetings")
      refute has_element?(view, "#board-share-capture-meeting")
    end

    test "the API still answers them: hiding is a display preference", %{conn: conn} do
      assert %{"meetings" => %{"enabled" => true, "hidden" => true}} =
               conn |> get(~p"/api/meetings") |> json_response(200)
    end
  end

  describe "Account › Settings › Display" do
    test "hides and shows it again", %{conn: conn, user: user, board: board} do
      turn_on(%{"meetings_visibility" => "every_board"})
      {:ok, view, _html} = live(conn, ~p"/account/settings")
      assert has_element?(view, "#display-settings")

      view |> form("#display-form", display: %{hide_meetings: "true"}) |> render_submit()
      assert Accounts.get_user!(user.id).hide_meetings
      {:ok, board_view, _html} = live(conn, ~p"/boards/#{board}")
      refute has_element?(board_view, "#view-menu-meetings")

      view |> form("#display-form", display: %{hide_meetings: "false"}) |> render_submit()
      refute Accounts.get_user!(user.id).hide_meetings
    end

    test "is not offered when the admin does not let people hide it", %{conn: conn} do
      turn_on(%{"meetings_hideable" => false})
      {:ok, view, _html} = live(conn, ~p"/account/settings")
      refute has_element?(view, "#display-settings")
    end
  end

  describe "the board page's cost" do
    # What decides the tab is `Meetings.presence/2`, read from the board row
    # the page already has and the settings (cached in production). Counting
    # its own queries is deterministic; counting a whole page reload was not,
    # since the page process does other work in the same moment (#530).
    test "deciding the tab for a board with no captures asks the database nothing", %{
      board: board,
      user: user
    } do
      for setup <- [
            fn -> :ok end,
            fn -> turn_on() end,
            fn -> turn_on(%{"meetings_visibility" => "every_board"}) end
          ] do
        setup.()
        assert {presence, 0} = counting_queries(fn -> Meetings.presence(user, board) end)
        assert presence in [:none, :menu, :tab]
      end
    end

    test "the board page shows it all the same", %{conn: conn, board: board} do
      turn_on()
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      assert has_element?(view, "#board-share-capture-meeting")
    end

    # Queries made by this process while `fun` runs, leaving out the settings
    # row, which the test suite reads uncached.
    defp counting_queries(fun) do
      counter = :counters.new(1, [])
      id = {__MODULE__, make_ref()}
      me = self()

      :telemetry.attach(
        id,
        [:slipdock, :repo, :query],
        fn _, _, meta, _ ->
          if self() == me and meta[:source] != "settings", do: :counters.add(counter, 1, 1)
        end,
        nil
      )

      result = fun.()
      :telemetry.detach(id)
      {result, :counters.get(counter, 1)}
    end
  end

  describe "the admin's switch" do
    setup %{user: user} do
      {:ok, admin} = Accounts.promote(user)
      %{admin: admin}
    end

    test "Configuration › Meetings turns it on, picks where it shows, and off again", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/config/meetings")
      assert has_element?(view, "#meetings-settings")

      view
      |> form("#meetings-form",
        settings: %{
          meetings_enabled: "true",
          meetings_visibility: "every_board",
          meetings_hideable: "false"
        }
      )
      |> render_submit()

      assert Meetings.enabled?()
      assert Meetings.visibility() == :every_board
      refute Meetings.hideable?()

      view |> form("#meetings-form", settings: %{meetings_enabled: "false"}) |> render_submit()
      refute Meetings.enabled?()
    end

    test "PATCH /api/admin/settings does the same, and reads it back", %{admin: admin} do
      {token, _} = Accounts.create_api_token(admin, "admin", scope: "admin")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> patch(~p"/api/admin/settings", %{
          "meetings_enabled" => true,
          "meetings_visibility" => "every_board"
        })

      assert %{"enabled" => true, "visibility" => "every_board", "hideable" => true} =
               json_response(conn, 200)["settings"]["meetings"]

      assert Meetings.enabled?()
    end
  end
end
