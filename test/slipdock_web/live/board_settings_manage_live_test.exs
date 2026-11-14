defmodule SlipdockWeb.BoardSettingsManageLiveTest do
  @moduledoc """
  The Manage tab's delete, archive and restore, fired from the settings
  panel's own buttons by the board's owner (#3116): what happens to the
  board, where the page goes and what it says. The refusals too: a subcard
  board isn't offered Archive, so that event is sent to the panel directly,
  and a restore at the owner's board limit leaves the board archived.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Settings}
  alias Slipdock.Boards.Board

  @panel "#settings-panel-manage"

  setup %{user: user} do
    %{board: board_fixture(%{"name" => "Manageable"}, owner: user)}
  end

  defp open_manage(conn, board) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=manage")
    view
  end

  defp button(view, event), do: element(view, ~s|#{@panel} button[phx-click="#{event}"]|)

  describe "delete_board" do
    test "deletes the board and goes to the index saying so", %{conn: conn, board: board} do
      view = open_manage(conn, board)

      {:ok, _index, html} =
        view |> button("delete_board") |> render_click() |> follow_redirect(conn, ~p"/")

      assert html =~ "Board deleted."
      refute html =~ "Manageable"
      refute Repo.get(Board, board.id)
    end

    test "takes the board's lists and cards with it", %{conn: conn, board: board} do
      card = card_fixture(hd(board.columns), %{"title" => "Goes too"})
      view = open_manage(conn, board)

      view |> button("delete_board") |> render_click()

      assert_redirect(view, ~p"/")
      refute Repo.get(Boards.Card, card.id)
    end
  end

  describe "archive_board" do
    test "archives the board and goes to the index saying where it went", %{
      conn: conn,
      board: board
    } do
      view = open_manage(conn, board)
      refute has_element?(button(view, "unarchive_board"))

      {:ok, index, html} =
        view |> button("archive_board") |> render_click() |> follow_redirect(conn, ~p"/")

      assert html =~ "“Manageable” archived. Find it under Archived on your boards."
      assert %Board{archived_at: %DateTime{}} = Repo.get!(Board, board.id)
      refute has_element?(index, "#boards a", "Manageable")
    end

    test "a subcard's board isn't offered it, and refuses the event", %{conn: conn, board: board} do
      {:ok, template} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card_fixture(hd(board.columns), %{"title" => "Epic"}), template)

      view = open_manage(conn, sub)
      refute has_element?(button(view, "archive_board"))

      html = view |> with_target("#board-settings") |> render_hook("archive_board", %{})
      refute html =~ "archived. Find it"

      assert render(view) =~ "Subcard boards go away with their card."
      refute_redirected(view, ~p"/")
      assert %Board{archived_at: nil} = Repo.get!(Board, sub.id)
      assert %Board{archived_at: nil} = Repo.get!(Board, board.id)
    end
  end

  describe "unarchive_board" do
    setup %{board: board} do
      {:ok, board} = Boards.Arrangement.archive_board(board)
      %{board: board}
    end

    test "restores the board, stays on it and offers Archive again", %{conn: conn, board: board} do
      view = open_manage(conn, board)
      refute has_element?(button(view, "archive_board"))

      view |> button("unarchive_board") |> render_click()

      assert render(view) =~ "Board restored."
      assert %Board{archived_at: nil} = Repo.get!(Board, board.id)
      refute has_element?(button(view, "unarchive_board"))
      assert has_element?(button(view, "archive_board"))
    end

    test "is refused at the owner's board limit, and the board stays archived", %{
      conn: conn,
      user: user,
      board: board
    } do
      board_fixture(%{"name" => "Replacement"}, owner: user)

      {:ok, _} =
        Settings.complete_setup(%{"admin_email" => "admin@example.com", "board_limit" => 1})

      view = open_manage(conn, board)
      view |> button("unarchive_board") |> render_click()

      html = render(view)
      refute html =~ "Board restored."
      # The quota's own sentence (#3117), not a blank flash.
      assert view |> element("#flash-error") |> render() =~
               "You own all 1 boards this server allows one person."

      assert %Board{archived_at: %DateTime{}} = Repo.get!(Board, board.id)
      assert has_element?(button(view, "unarchive_board"))
    end
  end
end
