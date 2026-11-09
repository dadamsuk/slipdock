defmodule Slipdock.Flow.DoingListTest do
  @moduledoc """
  `Slipdock.Flow.DoingList.doing?/2`, the query form, reads a list as
  `Slipdock.Flow.doing_list?/1` does (#2629): by its category, else by its
  name. Each list here is asked both ways and must get the same answer.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  require Slipdock.Flow.DoingList, as: DoingList

  alias Slipdock.{Flow, Repo}
  alias Slipdock.Boards.{CardMove, Column}

  @names [
    "Doing",
    "In Progress",
    "WIP",
    "Started",
    "Active work",
    "IN PROGRESS",
    "To Do",
    "Done",
    "Backlog",
    "Review",
    "Triage",
    "Doing done",
    "Inbox"
  ]

  @categories [nil, "", "todo", "doing", "done", "dropped", "triage", "scheduled"]

  test "a list is a doing list in a query exactly when doing_list?/1 says so" do
    board = board_fixture(%{"name" => "Parity", "code" => unique_code()})

    columns =
      for {{name, category}, n} <- Enum.with_index(for n <- @names, c <- @categories, do: {n, c}) do
        Repo.insert!(%Column{
          board_id: board.id,
          name: name,
          category: category,
          position: 100 + n
        })
      end

    ids = Enum.map(columns, & &1.id)

    in_sql =
      from(col in Column,
        where: col.id in ^ids and DoingList.doing?(col.category, col.name),
        select: col.id
      )
      |> Repo.all()
      |> MapSet.new()

    for col <- columns do
      assert MapSet.member?(in_sql, col.id) == Flow.doing_list?(col),
             "#{inspect(col.name)} / #{inspect(col.category)}"
    end

    # The cases that matter most, stated outright.
    by = &Enum.find(columns, fn c -> c.name == elem(&1, 0) and c.category == elem(&1, 1) end)
    assert MapSet.member?(in_sql, by.({"Doing", nil}).id)
    assert MapSet.member?(in_sql, by.({"Doing", ""}).id)
    assert MapSet.member?(in_sql, by.({"Review", "doing"}).id)
    refute MapSet.member?(in_sql, by.({"Doing", "todo"}).id)
    refute MapSet.member?(in_sql, by.({"Doing", "triage"}).id)
    refute MapSet.member?(in_sql, by.({"To Do", nil}).id)
  end

  test "a move reads by its to_category, else its to_column_name" do
    board = board_fixture(%{"name" => "Moves", "code" => unique_code()})
    [_backlog, todo | _] = board.columns
    card = card_fixture(todo)

    Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id),
      set: [to_category: nil, to_column_name: "Doing"]
    )

    doing? = fn ->
      Repo.exists?(
        from(m in CardMove,
          where: m.card_id == ^card.id and DoingList.doing?(m.to_category, m.to_column_name)
        )
      )
    end

    assert doing?.()

    Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id),
      set: [to_category: "todo", to_column_name: "Doing"]
    )

    refute doing?.()

    Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id),
      set: [to_category: nil, to_column_name: nil]
    )

    refute doing?.()
  end

  test "its words are the guide's" do
    for word <- DoingList.words() do
      assert Flow.doing_list?(%Column{name: "x #{word} y", category: nil})
    end
  end
end
