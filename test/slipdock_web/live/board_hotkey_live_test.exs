defmodule SlipdockWeb.BoardHotkeyLiveTest do
  @moduledoc """
  Ctrl+Shift+a digit (#1101): set under Hotkey in board settings, followed
  from any page by the `Keys` hook's `board_hotkey` event.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Hotkeys}
  alias SlipdockWeb.Shortcuts

  setup %{user: user} do
    plan = board_fixture(%{"name" => "Plan"}, owner: user)
    ops = board_fixture(%{"name" => "Ops"}, owner: user)
    %{plan: plan, ops: ops}
  end

  describe "the key" do
    test "goes to the board with that digit, from another board", %{
      conn: conn,
      user: user,
      plan: plan,
      ops: ops
    } do
      {:ok, 1} = Hotkeys.put(user, plan, 1)
      {:ok, view, _} = live(conn, ~p"/boards/#{ops}")

      assert {:error, {:live_redirect, %{to: to}}} =
               render_hook(view, "board_hotkey", %{"digit" => "1"})

      assert to == ~p"/boards/#{plan}"
    end

    test "lands on the board's default view", %{conn: conn, user: user, plan: plan} do
      {:ok, plan} = Boards.update_board(plan, %{"default_view" => "wiki"})
      {:ok, 4} = Hotkeys.put(user, plan, 4)
      {:ok, view, _} = live(conn, ~p"/")

      assert {:error, {:live_redirect, %{to: to}}} =
               render_hook(view, "board_hotkey", %{"digit" => "4"})

      assert to == ~p"/boards/#{plan}/wiki"
    end

    test "a digit with no board says how to give it one, and stays put", %{conn: conn, ops: ops} do
      {:ok, view, _} = live(conn, ~p"/boards/#{ops}")
      html = render_hook(view, "board_hotkey", %{"digit" => "7"})
      assert html =~ "No board on Ctrl+Shift+7"
      assert html =~ "board settings"
    end

    test "is on the shortcut sheet" do
      assert Enum.any?(Shortcuts.all(), fn {key, _} -> key =~ "Ctrl-Shift" end)
    end
  end

  describe "board settings" do
    test "saving the form with a digit gives the board it", %{conn: conn, user: user, plan: plan} do
      {:ok, view, _} = live(conn, ~p"/boards/#{plan}/settings")
      assert has_element?(view, "#board-hotkey")

      view |> form("#board-form", %{"hotkey" => "3"}) |> render_submit()
      assert Hotkeys.get(user, plan) == 3

      {:ok, view, _} = live(conn, ~p"/boards/#{plan}/settings")
      assert has_element?(view, ~s(#board-hotkey option[value="3"][selected]))

      view |> form("#board-form", %{"hotkey" => ""}) |> render_submit()
      assert Hotkeys.get(user, plan) == nil
    end

    test "names the board a digit is on now, and choosing it moves it", %{
      conn: conn,
      user: user,
      plan: plan,
      ops: ops
    } do
      {:ok, 2} = Hotkeys.put(user, ops, 2)
      {:ok, view, _} = live(conn, ~p"/boards/#{plan}/settings")
      assert render(element(view, ~s(#board-hotkey option[value="2"]))) =~ "now Ops"

      view |> form("#board-form", %{"hotkey" => "2"}) |> render_submit()
      assert Hotkeys.get(user, plan) == 2
      assert Hotkeys.get(user, ops) == nil
    end

    test "a sub-board's settings offer none", %{conn: conn, plan: plan} do
      [column | _] = plan.columns
      card = card_fixture(column, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(card, t)

      {:ok, view, _} = live(conn, ~p"/boards/#{sub}/settings")
      refute has_element?(view, "#board-hotkey")
    end
  end
end
