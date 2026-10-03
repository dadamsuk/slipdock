defmodule Slipdock.FieldsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Boards, Fields, Rollup, Votes}
  alias Slipdock.Fields.Expression

  describe "expressions" do
    test "parse and evaluate arithmetic over field references" do
      {:ok, ast} = Expression.parse("{reach} * {impact} * ({confidence} / 100) / {effort}")
      assert Expression.refs(ast) == ~w(reach impact confidence effort)

      assert Expression.eval(ast, %{
               "reach" => 100,
               "impact" => 3,
               "confidence" => 50,
               "effort" => 2
             }) == 75.0

      assert Expression.eval(ast, %{"reach" => 100, "impact" => 3, "confidence" => 50}) == nil

      assert Expression.eval(ast, %{"reach" => 1, "impact" => 1, "confidence" => 1, "effort" => 0}) ==
               nil

      {:ok, ast} = Expression.parse("-{a} + 2 * (3 - 1)")
      assert Expression.eval(ast, %{"a" => 1}) == 3.0

      assert {:error, msg} = Expression.parse("{a} +")
      assert msg =~ "ends too early"
      assert {:error, _} = Expression.parse("{Bad Key}")
      assert {:error, _} = Expression.parse("(1 + 2")
      assert {:error, _} = Expression.parse("")
    end
  end

  describe "definitions and values" do
    setup do
      board = board_fixture()
      [col | _] = board.columns
      a = card_fixture(col, %{"title" => "A"})
      b = card_fixture(col, %{"title" => "B"})
      %{board: board, col: col, a: a, b: b}
    end

    test "fields live on the root board, get a key from their name, and hold typed values", ctx do
      {:ok, size} =
        Fields.create_field(ctx.board, %{
          "name" => "T-shirt size",
          "kind" => "select",
          "options" => [
            %{"label" => "Small", "weight" => 1},
            %{"label" => "Large", "weight" => 3, "color" => "rose"}
          ]
        })

      assert size.key == "t_shirt_size"

      assert [%{"key" => "small", "weight" => 1.0}, %{"key" => "large", "color" => "rose"}] =
               size.options

      {:ok, reach} =
        Fields.create_field(ctx.board, %{
          "name" => "Reach",
          "kind" => "number",
          "config" => %{"min" => 0, "max" => 100}
        })

      {:ok, stars} = Fields.create_field(ctx.board, %{"name" => "Impact", "kind" => "rating"})

      assert [%{key: "t_shirt_size"}, %{key: "reach"}, %{key: "impact"}] =
               Fields.list_fields(ctx.board.id)

      assert {:ok, a} = Fields.set_value(ctx.a, size, "Large")
      assert Fields.value(a, size) == "large"
      assert Fields.numeric(a, size) == 3.0
      assert Fields.format(size, "large") == "Large"

      assert {:ok, a} = Fields.set_value(a, reach, "42")
      assert Fields.numeric(a, reach) == 42.0
      assert {:error, msg} = Fields.set_value(a, reach, "500")
      assert msg =~ "at most 100"
      assert {:error, _} = Fields.set_value(a, reach, "lots")
      assert {:error, _} = Fields.set_value(a, stars, "9")
      assert {:ok, a} = Fields.set_value(a, stars, "4")
      assert Fields.value(a, stars) == 4.0

      assert {:ok, a} = Fields.set_value(a, reach, "")
      assert Fields.value(a, reach) == nil

      assert {:error, _} =
               Fields.create_field(ctx.board, %{"name" => "Reach", "kind" => "number"})

      assert {:error, cs} =
               Fields.create_field(ctx.board, %{
                 "name" => "Score",
                 "kind" => "formula",
                 "config" => %{"expression" => "{a} +"}
               })

      assert %{config: _} = errors_on(cs)
    end

    test "presets install their inputs and formula, and formulas compute per card", ctx do
      {:ok, rice} = Fields.install_preset(ctx.board, "rice")
      fields = Fields.list_fields(ctx.board.id)
      assert Enum.map(fields, & &1.key) == ~w(reach impact confidence effort rice)
      assert rice.kind == "formula"

      # Installing again adds nothing.
      {:ok, _} = Fields.install_preset(ctx.board, "rice")
      assert length(Fields.list_fields(ctx.board.id)) == 5

      by = Map.new(fields, &{&1.key, &1})
      {:ok, a} = Fields.set_value(ctx.a, by["reach"], 200)
      {:ok, a} = Fields.set_value(a, by["impact"], 3)
      {:ok, a} = Fields.set_value(a, by["confidence"], 80)
      {:ok, a} = Fields.set_value(a, by["effort"], 4)
      assert Fields.value(a, rice) == 120.0
      assert Fields.numeric(Boards.get_card!(ctx.b.id), rice) == nil

      board = reload(ctx.board)
      cards = board.columns |> hd() |> Map.fetch!(:cards)
      assert Enum.find(cards, &(&1.id == a.id)).computed[rice.id] == 120.0
    end

    test "a weighted score normalises each input across the board", ctx do
      {:ok, value} = Fields.create_field(ctx.board, %{"name" => "Value", "kind" => "rating"})
      {:ok, effort} = Fields.create_field(ctx.board, %{"name" => "Effort", "kind" => "rating"})

      {:ok, score} =
        Fields.create_field(ctx.board, %{
          "name" => "Score",
          "kind" => "formula",
          "config" => %{
            "mode" => "weighted",
            "weights" => [
              %{"key" => "value", "weight" => 2},
              %{"key" => "effort", "weight" => -1}
            ]
          }
        })

      {:ok, _} = Fields.set_value(ctx.a, value, 5)
      {:ok, _} = Fields.set_value(ctx.a, effort, 1)
      {:ok, _} = Fields.set_value(ctx.b, value, 1)
      {:ok, _} = Fields.set_value(ctx.b, effort, 5)

      board = reload(ctx.board)
      cards = board.columns |> hd() |> Map.fetch!(:cards)
      a = Enum.find(cards, &(&1.id == ctx.a.id))
      b = Enum.find(cards, &(&1.id == ctx.b.id))
      # A: value 100, effort 0 → (2*100 - 1*0)/3 ; B: value 0, effort 100 → -100/3
      assert_in_delta a.computed[score.id], 66.67, 0.01
      assert_in_delta b.computed[score.id], -33.33, 0.01
    end

    test "fields flagged to sum roll up the tree" do
      %{board: board, b: b, e: e} = tree_fixture()

      {:ok, points} =
        Fields.create_field(board, %{"name" => "Points", "kind" => "number", "sum" => true})

      {:ok, _} = Fields.set_value(b, points, 3)
      {:ok, _} = Fields.set_value(e, points, 5)

      rollup = Rollup.build(board.id)
      epic = Enum.find(Map.values(rollup.cards), &(&1.title == "Epic"))
      assert Rollup.stats(rollup, epic).sums == %{points.id => %{total: 8.0, done: 3.0}}
    end
  end

  describe "votes" do
    test "people spend a budget, capped per card" do
      board = board_fixture()
      {:ok, board} = Boards.update_board(board, %{"vote_budget" => 5, "vote_max" => 3})
      [col | _] = board.columns
      a = card_fixture(col, %{"title" => "A"})
      b = card_fixture(col, %{"title" => "B"})
      user = user_fixture()

      assert {:ok, a} = Votes.set(a, user, 3, "Love it")
      assert Slipdock.Boards.Card.vote_total(a) == 3
      assert Votes.mine(a, user) == 3
      assert {:error, msg} = Votes.set(a, user, 4)
      assert msg =~ "At most 3"
      assert {:error, msg} = Votes.set(b, user, 3)
      assert msg =~ "2 votes left"
      assert {:ok, b} = Votes.set(b, user, 2)
      assert Votes.spent(user, board.id) == 5
      assert {:ok, a} = Votes.set(a, user, 1)
      assert Slipdock.Boards.Card.vote_total(a) == 1
      assert {:ok, b} = Votes.set(b, user, 0)
      assert b.votes == []
    end
  end
end
