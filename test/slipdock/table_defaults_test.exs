defmodule Slipdock.TableDefaultsTest do
  @moduledoc """
  The table's default columns (#1731): Assignee is one of them, and every
  place that starts from the defaults (a new view's config, its compact
  variant, a wiki query table that names no fields) starts from the same list.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Swimlanes.Config
  alias Slipdock.Table
  alias Slipdock.Wiki.Query

  test "the defaults, in display order, include Assignee" do
    assert Table.default_fields() == ~w(title column priority assignee tags due_date completed)
    assert Enum.all?(Table.default_fields(), &(&1 in Table.field_keys()))
  end

  test "a new config, comfortable or compact, starts from the same columns" do
    assert %Config{}.fields == Table.default_fields()
    assert %Config{}.fields_compact == Table.default_fields()
    assert Config.defaults("table").fields == Table.default_fields()

    for density <- ~w(comfortable compact) do
      shown =
        %{Config.defaults("table") | density: density}
        |> Table.visible_fields()
        |> Enum.map(&elem(&1, 0))

      assert shown == Table.default_fields()
    end
  end

  test "Assignee can still be left out, and a stored config without it stays without it" do
    config = Config.from_query(%{"fields" => "column,priority"})
    refute "assignee" in config.fields
    refute "assignee" in (config |> Table.visible_fields() |> Enum.map(&elem(&1, 0)))

    stored = config |> Config.to_map() |> Config.from_map()
    refute "assignee" in stored.fields
  end

  test "a wiki query table with no fields shows the default columns, Assignee included" do
    user = user_fixture()
    board = board_fixture(%{"name" => "Defaults", "code" => "tbldef1731"}, owner: user)
    [backlog | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Owned"})
    {:ok, _} = Slipdock.Boards.update_card(card, %{"assignee_id" => user.id})

    {:ok, query} = Query.parse("view: table")

    assert {:ok, %{kind: :table, keys: keys, headers: headers, rows: [row]}} =
             Query.run(query, %{board: board, reader: user})

    assert keys == Table.default_fields()
    assert "Assignee" in headers
    at = Enum.find_index(keys, &(&1 == "assignee"))
    assert Enum.at(row.cells, at) == Slipdock.Accounts.User.display_name(user)
  end
end
