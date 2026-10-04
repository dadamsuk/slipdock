defmodule Slipdock.TableCsvTest do
  # Every column the table can show, as the CSV export writes it.
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields, Table}
  alias Slipdock.Swimlanes.Config

  setup do
    owner = user_fixture("table-owner@example.com")
    board = board_fixture(%{"name" => "Export"}, owner: owner)
    [backlog, todo | _] = board.columns

    {:ok, points} =
      Fields.create_field(board, %{"name" => "Points", "kind" => "number", "sum" => true})

    full =
      card_fixture(todo, %{
        "title" => "Full",
        "priority" => "high",
        "percent_complete" => 40,
        "color" => "rose",
        "flags" => ["blocked", "review"],
        "start_date" => "2030-01-01",
        "due_date" => "2030-02-01",
        "assignee_id" => owner.id
      })

    empty = card_fixture(backlog, %{"title" => "Empty"})

    Boards.toggle_card_tag(full, tag_fixture(board, "bug"))
    Boards.toggle_card_tag(full, tag_fixture(board, "ui"))
    {:ok, item} = Boards.add_checklist_item(full, "one")
    {:ok, _} = Boards.add_checklist_item(full, "two")
    {:ok, _} = Boards.toggle_checklist_item(item)
    {:ok, _} = Boards.add_comment(full, "First", by: owner)
    {:ok, _} = Boards.add_dependency(full, empty)
    {:ok, _} = Fields.set_value(full, points, "5")
    {:ok, _} = Fields.set_value(empty, points, "3")

    %{board: reload(board), full: full, empty: empty, points: points}
  end

  defp csv(board, fields, rows \\ "none"),
    do: Table.csv(board, %{Config.defaults("table") | fields: fields, rows: rows})

  defp row(csv, title) do
    [header | lines] = String.split(csv, "\r\n", trim: true)
    keys = String.split(header, ",")
    line = Enum.find(lines, &String.starts_with?(&1, title <> ","))
    keys |> Enum.zip(String.split(line, ",")) |> Map.new()
  end

  test "a card with everything on it", %{board: board, full: full, points: points} do
    fields =
      ~w(title column priority assignee flags tags start_date due_date completed
         percent_complete checklist comments dependencies color id) ++ ["f:#{points.id}"]

    assert %{
             "List" => "To Do",
             "Priority" => "high",
             "Assignee" => assignee,
             "Flags" => "blocked; review",
             "Tags" => "bug; ui",
             "Start" => "2030-01-01",
             "Due" => "2030-02-01",
             "Done" => "no",
             "% complete" => "40%",
             "Checklist" => "1/2",
             "Comments" => "1",
             "Dependencies" => "blocked by: Empty",
             "Cover" => "rose",
             "ID" => id,
             "Points" => "5"
           } = row(csv(board, fields), "Full")

    assert assignee =~ "table-owner"
    assert id == to_string(full.id)
  end

  test "a card with nothing on it leaves the cells empty", %{board: board, points: points} do
    fields =
      ~w(title flags tags percent_complete checklist time health color) ++ ["f:#{points.id}"]

    assert %{
             "Flags" => "",
             "Tags" => "",
             "% complete" => "",
             "Checklist" => "",
             "Time" => "",
             "Cover" => ""
           } = row(csv(board, fields), "Empty")
  end

  test "the blocker's side of a dependency", %{board: board} do
    assert %{"Dependencies" => "blocks: Full"} = row(csv(board, ~w(title dependencies)), "Empty")
  end

  test "created and updated are timestamps", %{board: board} do
    %{"Created" => created, "Updated" => updated} =
      row(csv(board, ~w(title created updated)), "Full")

    assert {:ok, _, _} = DateTime.from_iso8601(created)
    assert {:ok, _, _} = DateTime.from_iso8601(updated)
  end

  test "a summed field totals each group", %{board: board, points: points} do
    %{groups: groups} = Table.rows(board, %{Config.defaults("table") | rows: "column"})
    by_label = Map.new(groups, &{&1.label, Table.group_sums(&1.cards, board)})

    assert [{%{id: id}, 5.0}] = by_label["To Do"]
    assert id == points.id
    assert [{_, 3.0}] = by_label["Backlog"]
  end

  test "headers use the board's own field names", %{board: board, points: points} do
    assert Table.field_label("f:#{points.id}", board) == "Points"
    assert Table.field_label("due_date") == "Due"
    assert Table.field_label("nonsense") == "nonsense"
  end
end
