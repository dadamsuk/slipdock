defmodule SlipdockWeb.BoardCodesLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  describe "the new board form" do
    test "fills the code in from the name, and lets it be overridden", %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, ~p"/")
      render_click(view, "start_create", %{})

      html =
        view
        |> form("#new-board", board: %{"name" => "QVM V1 Remediation", "code" => ""})
        |> render_change()

      assert html =~ ~s(value="qvm-v1-rem")

      # A code the user types is left alone, even as the name carries on changing.
      view
      |> form("#new-board", board: %{"name" => "QVM V1 Remediation", "code" => "qvm"})
      |> render_change()

      html =
        view
        |> form("#new-board", board: %{"name" => "QVM V1 Remediation plan", "code" => "qvm"})
        |> render_change()

      assert html =~ ~s(value="qvm")

      view
      |> form("#new-board", board: %{"name" => "QVM V1 Remediation plan", "code" => "qvm"})
      |> render_submit()

      assert [%{code: "qvm", name: "QVM V1 Remediation plan"}] =
               Slipdock.Access.list_boards(user)
    end

    test "an empty name leaves the code empty", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      render_click(view, "start_create", %{})

      html =
        view
        |> form("#new-board", board: %{"name" => "", "code" => ""})
        |> render_change()

      refute html =~ ~s(value="board")
    end
  end

  describe "board settings" do
    setup %{user: user} do
      %{board: board_fixture(%{"name" => "QVM V1 Remediation"}, owner: user)}
    end

    test "the code shows and can be edited", %{conn: conn, board: board} do
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/settings")
      assert html =~ "qvm-v1-rem"

      view
      |> form("#board-form", board: %{"name" => board.name, "code" => "QVM 1"})
      |> render_submit()

      assert Boards.get_board!(board.id).code == "qvm-1"
    end

    test "clearing the code suggests a fresh one from the name", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")

      html =
        view
        |> form("#board-form", board: %{"name" => "Billing rewrite", "code" => ""})
        |> render_change()

      assert html =~ ~s(value="billing-re")
    end

    test "a code another board has is refused", %{conn: conn, board: board, user: user} do
      board_fixture(%{"name" => "Other", "code" => "taken"}, owner: user)

      html =
        live(conn, ~p"/boards/#{board}/settings")
        |> elem(1)
        |> form("#board-form", board: %{"name" => board.name, "code" => "taken"})
        |> render_submit()

      assert html =~ "is already used by another board"
      assert Boards.get_board!(board.id).code == "qvm-v1-rem"
    end
  end
end
