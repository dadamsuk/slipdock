defmodule Slipdock.CustomListsTest do
  @moduledoc """
  A board made with lists of its own (`columns:`) rather than a template's,
  and those lists kept as a new template (`save_template:`) in the same go.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.Template

  setup do
    %{user: user_fixture(), name: "Custom #{System.unique_integer([:positive])}"}
  end

  defp lists(board),
    do:
      board.id |> Boards.get_board!() |> Map.fetch!(:columns) |> Enum.map(&{&1.name, &1.category})

  test "makes the lists given, in order, guessing roles from their names", %{user: user} do
    {:ok, board} =
      Boards.create_board(%{"name" => "Pipeline"},
        owner_id: user.id,
        columns: ["Ideas", " Up next ", "", "Doing", %{"name" => "Shipped", "wip_limit" => 3}]
      )

    assert lists(board) == [
             {"Ideas", nil},
             {"Up next", "todo"},
             {"Doing", "doing"},
             {"Shipped", "done"}
           ]

    assert Enum.at(Boards.get_board!(board.id).columns, 3).wip_limit == 3
    assert board.template_id == nil
  end

  test "a category given is kept, not guessed over", %{user: user} do
    {:ok, board} =
      Boards.create_board(%{"name" => "Kept"},
        owner_id: user.id,
        columns: [%{"name" => "Done", "category" => "dropped"}]
      )

    assert lists(board) == [{"Done", "dropped"}]
  end

  test "custom lists win over a template given as well", %{user: user} do
    {:ok, t} = Boards.find_template("Checklist")

    {:ok, board} =
      Boards.create_board(%{"name" => "Both"}, owner_id: user.id, template: t, columns: ["Mine"])

    assert lists(board) == [{"Mine", nil}]
  end

  test "no lists, or only blank ones, is refused and makes nothing", %{user: user} do
    for columns <- [[], ["", "  "]] do
      assert {:error, cs} =
               Boards.create_board(%{"name" => "Empty"}, owner_id: user.id, columns: columns)

      assert {"add at least one list", _} = cs.errors[:columns]
    end

    assert Slipdock.Access.list_boards(user) == []
  end

  test "more than 20 lists is refused", %{user: user} do
    columns = Enum.map(1..21, &"List #{&1}")

    assert {:error, cs} =
             Boards.create_board(%{"name" => "Big"}, owner_id: user.id, columns: columns)

    assert {"can have at most 20 lists", _} = cs.errors[:columns]
  end

  test "save_template keeps the lists as a template the board is made from",
       %{user: user, name: name} do
    {:ok, board} =
      Boards.create_board(%{"name" => "Hiring", "description" => "Candidates"},
        owner_id: user.id,
        columns: ["Applied", "Interview", "Done"],
        save_template: name
      )

    assert {:ok, %Template{} = t} = Boards.find_template(name)
    assert board.template_id == t.id
    assert t.description == "Candidates"

    assert Enum.map(t.columns, &{&1["name"], &1["category"]}) ==
             [{"Applied", nil}, {"Interview", nil}, {"Done", "done"}]

    # And a later board made from it gets the same lists.
    {:ok, again} = Boards.create_board(%{"name" => "Hiring 2"}, owner_id: user.id, template: t)
    assert lists(again) == lists(board)
  end

  test "save_template: true names the template after the board", %{user: user, name: name} do
    {:ok, board} =
      Boards.create_board(%{"name" => name},
        owner_id: user.id,
        columns: ["A"],
        save_template: true
      )

    assert {:ok, t} = Boards.find_template(name)
    assert board.template_id == t.id
  end

  test "a template name already taken refuses the board too", %{user: user, name: name} do
    {:ok, _} = Boards.create_template(%{"name" => name, "columns" => ["X"]})

    assert {:error, cs} =
             Boards.create_board(%{"name" => "Clash"},
               owner_id: user.id,
               columns: ["A"],
               save_template: " #{name} "
             )

    assert {msg, _} = cs.errors[:save_template]
    assert msg == "a template called “#{name}” already exists"
    assert Slipdock.Access.list_boards(user) == []
  end

  test "a template name that is too long is refused with the limit", %{user: user} do
    assert {:error, cs} =
             Boards.create_board(%{"name" => "Long"},
               owner_id: user.id,
               columns: ["A"],
               save_template: String.duplicate("x", 61)
             )

    assert {"template name should be at most 60 character(s)", _} = cs.errors[:save_template]
  end

  test "a board that is refused saves no template either", %{user: user, name: name} do
    assert {:error, cs} =
             Boards.create_board(%{"name" => ""},
               owner_id: user.id,
               columns: ["A"],
               save_template: name
             )

    assert cs.errors[:name]
    assert {:error, :not_found} = Boards.find_template(name)
  end
end
