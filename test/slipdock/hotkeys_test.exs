defmodule Slipdock.HotkeysTest do
  @moduledoc "Board hotkeys, Ctrl+Shift+a digit (#1101): one person's ten digits."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Hotkeys}

  setup do
    user = user_fixture()
    plan = board_fixture(%{"name" => "Plan"}, owner: user)
    ops = board_fixture(%{"name" => "Ops"}, owner: user)
    %{user: user, plan: plan, ops: ops}
  end

  describe "parse/1" do
    test "reads a digit from an integer or a string, and none from blanks" do
      assert Hotkeys.parse(3) == {:ok, 3}
      assert Hotkeys.parse("0") == {:ok, 0}
      assert Hotkeys.parse(" 7 ") == {:ok, 7}
      for none <- [nil, "", "none", "off"], do: assert(Hotkeys.parse(none) == {:ok, nil})
    end

    test "refuses anything that is not one digit" do
      for bad <- [10, -1, "12", "a", "1.5", 2.0, %{}] do
        assert {:error, message} = Hotkeys.parse(bad)
        assert message =~ "single digit"
      end
    end
  end

  describe "put/3" do
    test "gives a board a digit, which then opens it", %{user: user, plan: plan} do
      assert {:ok, 1} = Hotkeys.put(user, plan, "1")
      assert Hotkeys.get(user, plan) == 1
      assert Hotkeys.target(user, "1").id == plan.id
      assert Hotkeys.target(user, 1).id == plan.id
    end

    test "a digit another board had moves, leaving that board with none",
         %{user: user, plan: plan, ops: ops} do
      {:ok, 1} = Hotkeys.put(user, plan, 1)
      {:ok, 1} = Hotkeys.put(user, ops, 1)

      assert Hotkeys.get(user, plan) == nil
      assert Hotkeys.get(user, ops) == 1
      assert Hotkeys.target(user, 1).id == ops.id
    end

    test "a board keeps one digit: a new one replaces the old", %{user: user, plan: plan} do
      {:ok, 1} = Hotkeys.put(user, plan, 1)
      {:ok, 4} = Hotkeys.put(user, plan, 4)

      assert Hotkeys.get(user, plan) == 4
      assert Hotkeys.target(user, 1) == nil
      assert [{4, %{id: id}}] = Hotkeys.list(user)
      assert id == plan.id
    end

    test "none takes the digit away", %{user: user, plan: plan} do
      {:ok, 2} = Hotkeys.put(user, plan, 2)
      assert {:ok, nil} = Hotkeys.put(user, plan, "none")
      assert Hotkeys.get(user, plan) == nil
      assert Hotkeys.target(user, 2) == nil
    end

    test "a bad digit changes nothing", %{user: user, plan: plan} do
      {:ok, 2} = Hotkeys.put(user, plan, 2)
      assert {:error, _} = Hotkeys.put(user, plan, "12")
      assert Hotkeys.get(user, plan) == 2
    end

    test "the digits are each person's own", %{user: user, plan: plan, ops: ops} do
      other = user_fixture("other@example.com")
      share_fixture(plan, other, "read")

      {:ok, 1} = Hotkeys.put(user, ops, 1)
      {:ok, 1} = Hotkeys.put(other, plan, 1)

      assert Hotkeys.target(user, 1).id == ops.id
      assert Hotkeys.target(other, 1).id == plan.id
      assert Hotkeys.get(user, plan) == nil
    end

    test "refuses a board the person cannot open", %{plan: plan} do
      stranger = user_fixture("stranger@example.com")
      assert {:error, "board not found"} = Hotkeys.put(stranger, plan, 1)
      assert Hotkeys.list(stranger) == []
    end

    test "refuses a sub-board", %{user: user, plan: plan} do
      [column | _] = plan.columns
      card = card_fixture(column, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(card, t)

      assert {:error, message} = Hotkeys.put(user, sub, 1)
      assert message =~ "top-level"
    end
  end

  describe "target/2 and list/1" do
    test "nothing on a digit, or no digit at all, is nil", %{user: user} do
      assert Hotkeys.target(user, 5) == nil
      assert Hotkeys.target(user, "x") == nil
      assert Hotkeys.target(user, "") == nil
      assert Hotkeys.target(nil, 5) == nil
    end

    test "an archived board is not opened, but keeps its digit", %{user: user, plan: plan} do
      {:ok, 3} = Hotkeys.put(user, plan, 3)
      {:ok, _} = Boards.archive_board(plan)

      assert Hotkeys.target(user, 3) == nil
      assert Hotkeys.get(user, plan) == 3
    end

    test "a share taken back stops the digit working", %{plan: plan} do
      other = user_fixture("other@example.com")
      share_fixture(plan, other, "read")
      {:ok, 1} = Hotkeys.put(other, plan, 1)

      [grant] = Enum.filter(Access.list_grants(plan), &(&1.user_id == other.id))
      {:ok, _} = Access.revoke(grant)

      assert Hotkeys.target(other, 1) == nil
      assert Hotkeys.list(other) == []
    end

    test "lists 1–9 then 0, as on the keyboard", %{user: user, plan: plan, ops: ops} do
      {:ok, 0} = Hotkeys.put(user, plan, 0)
      {:ok, 2} = Hotkeys.put(user, ops, 2)

      assert [{2, %{id: ops_id}}, {0, %{id: plan_id}}] = Hotkeys.list(user)
      assert {ops_id, plan_id} == {ops.id, plan.id}
    end

    test "a deleted board takes its digit with it", %{user: user, plan: plan} do
      {:ok, 1} = Hotkeys.put(user, plan, 1)
      {:ok, _} = Boards.delete_board(plan)

      assert Hotkeys.target(user, 1) == nil
      assert Hotkeys.list(user) == []
    end
  end
end
