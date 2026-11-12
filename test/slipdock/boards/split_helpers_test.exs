defmodule Slipdock.Boards.SplitHelpersTest do
  @moduledoc """
  Pins the helpers the split of `Slipdock.Boards` (#2787) took out of
  `list_cards`, `add_link`, `move_column` and `wait_choice`: each test
  fails if its helper is rewritten wrongly (a filter that lets everything
  through, a broadcast that skips the other board, positions never
  written, a choice read from its leading digits).
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo}
  alias Slipdock.Boards.Column

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Split"}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp titles(cards), do: cards |> Enum.map(& &1.title) |> Enum.sort()

  describe "list_cards filters" do
    setup ctx do
      high = card_fixture(ctx.todo, %{"title" => "High", "priority" => "high"})
      low = card_fixture(ctx.doing, %{"title" => "Low", "priority" => "low"})
      Map.merge(ctx, %{high: high, low: low})
    end

    test "priority keeps only the cards of that priority", ctx do
      assert titles(Boards.Cards.list_cards(ctx.board, %{"priority" => "high"})) == ["High"]
      assert titles(Boards.Cards.list_cards(ctx.board, %{"priority" => "low"})) == ["Low"]
    end

    test "a column keeps its cards; a column that does not exist keeps none", ctx do
      assert titles(Boards.Cards.list_cards(ctx.board, %{"column" => ctx.doing.name})) == ["Low"]
      assert Boards.Cards.list_cards(ctx.board, %{"column" => "No such list"}) == []
    end

    test "a tag keeps its cards; a tag that does not exist keeps none", ctx do
      tag = tag_fixture(ctx.board, "urgent")
      {:ok, _} = Boards.Tags.toggle_card_tag(ctx.high, tag)

      assert titles(Boards.Cards.list_cards(ctx.board, %{"tag" => "urgent"})) == ["High"]
      assert Boards.Cards.list_cards(ctx.board, %{"tag" => "no-such-tag"}) == []
    end
  end

  test "a link across boards tells the other board too", ctx do
    other = board_fixture(%{"name" => "Other"}, owner: ctx.owner)
    from = card_fixture(ctx.todo, %{"title" => "Here"})
    to = card_fixture(hd(other.columns), %{"title" => "There"})

    Boards.PubSub.subscribe(other.id)
    assert {:ok, _} = Boards.Links.add_link(from, to, "relates")
    assert_receive {:board_changed, id} when id == other.id
  end

  test "move_column writes every column's new position", ctx do
    assert :ok = Boards.Columns.move_column(ctx.board.id, ctx.done.id, ctx.backlog.id)

    positions =
      Repo.all(
        from(c in Column,
          where: c.board_id == ^ctx.board.id,
          order_by: c.position,
          select: {c.id, c.position}
        )
      )

    assert positions == [
             {ctx.done.id, 0},
             {ctx.backlog.id, 1},
             {ctx.todo.id, 2},
             {ctx.doing.id, 3}
           ]
  end

  test "a choice must be a whole number: \"2x\" is refused, \"2\" is taken", ctx do
    dana = user_fixture("dana@example.com")
    {:ok, _} = Slipdock.Access.grant(ctx.board, dana, "write", ctx.owner)
    card = card_fixture(ctx.todo, %{"title" => "Deploy"})

    {:ok, _} =
      Boards.Waits.open_wait(card, Actor.web(ctx.owner), %{
        "needs" => "Which region?",
        "on_user_id" => dana.id,
        "choices" => ["eu", "us"]
      })

    assert {:error, "choice must be a number from 1 to 2"} =
             Boards.Waits.answer_wait(card, Actor.web(dana), %{"choice" => "2x"})

    assert {:ok, wait} = Boards.Waits.answer_wait(card, Actor.web(dana), %{"choice" => "2"})
    assert wait.choice == 2
  end
end
