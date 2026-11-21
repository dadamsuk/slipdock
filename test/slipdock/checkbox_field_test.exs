defmodule Slipdock.CheckboxFieldTest do
  @moduledoc """
  The checkbox custom field (#3612): on or off, and an empty one counts as
  off everywhere — the toolbar's filters and a view's kept ones, formulas,
  sorting and the swimlane axis. What it takes, what it refuses, and what
  the API gives back.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields, Filters, Swimlanes}
  alias Slipdock.Swimlanes.Config

  setup do
    board = board_fixture(%{"name" => "Invoices"})
    [_backlog, todo | _] = board.columns

    {:ok, paid} = Fields.create_field(board, %{"name" => "Paid", "kind" => "checkbox"})

    {:ok, worth} =
      Fields.create_field(board, %{
        "name" => "Worth",
        "kind" => "formula",
        "config" => %{"mode" => "expression", "expression" => "{paid} * 10"}
      })

    checked = card_fixture(todo, %{"title" => "Checked"})
    empty = card_fixture(todo, %{"title" => "Empty"})
    {:ok, _} = Fields.set_value(checked, paid, "true")

    %{board: board, paid: paid, worth: worth, checked: checked, empty: empty}
  end

  defp loaded(ctx) do
    fields = Fields.list_fields(Boards.Board.root_id(ctx.board))
    Fields.decorate([card(ctx.checked), card(ctx.empty)], fields)
  end

  defp card(card), do: Boards.Cards.get_card!(card.id)
  defp titles(cards), do: Enum.map(cards, & &1.title)

  describe "setting it" do
    test "on is stored as 1.0, and off clears it", %{paid: paid, empty: empty} do
      {:ok, on} = Fields.set_value(card(empty), paid, "Yes")
      assert Fields.value(on, paid) == 1.0

      {:ok, off} = Fields.set_value(on, paid, false)
      assert Fields.value(off, paid) == nil
      assert off.field_values == []
    end

    test "it takes the words and numbers a person or a lane sends", %{paid: paid, empty: empty} do
      for raw <- [true, "true", "TRUE", "1", "1.0", "on", "yes", 1] do
        {:ok, card} = Fields.set_value(card(empty), paid, raw)
        assert Fields.value(card, paid) == 1.0, "#{inspect(raw)} didn't set it"
        {:ok, _} = Fields.set_value(card, paid, "")
      end

      for raw <- [false, "false", "0", "0.0", "Off", "no", 0] do
        {:ok, _} = Fields.set_value(card(empty), paid, "true")
        {:ok, card} = Fields.set_value(card(empty), paid, raw)
        assert Fields.value(card, paid) == nil, "#{inspect(raw)} didn't clear it"
      end
    end

    test "anything else is refused, and the value stays", %{paid: paid, checked: checked} do
      assert Fields.set_value(card(checked), paid, "maybe") ==
               {:error, "Paid takes true or false."}

      assert Fields.set_value(card(checked), paid, "2") == {:error, "Paid takes true or false."}
      assert Fields.value(card(checked), paid) == 1.0
    end
  end

  test "an empty checkbox is 0 in a formula, a checked one 1", %{worth: worth} = ctx do
    [checked, empty] = loaded(ctx)
    assert Fields.value(checked, worth) == 10.0
    assert Fields.value(empty, worth) == 0.0
  end

  test "decorating puts 1.0 or 0.0 in computed, the stored value stays", ctx do
    [checked, empty] = loaded(ctx)
    assert checked.computed[ctx.paid.id] == 1.0
    assert empty.computed[ctx.paid.id] == 0.0
    assert Fields.value(empty, ctx.paid) == nil

    alone = Fields.decorate_one(card(ctx.empty), [ctx.paid])
    assert alone.computed[ctx.paid.id] == 0.0
  end

  describe "filtering" do
    test "Off keeps the empty card, On the checked one", %{paid: paid} = ctx do
      off = Filters.put_field(Filters.empty(), paid, %{"checked" => "false"})
      on = Filters.put_field(Filters.empty(), paid, %{"checked" => "true"})

      assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, off)) |> titles() == ["Empty"]
      assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, on)) |> titles() == ["Checked"]

      # Undecorated too: no value is off.
      assert Filters.matches?(card(ctx.empty), off)
      refute Filters.matches?(card(ctx.empty), on)
    end

    test "the same button again clears the filter", %{paid: paid} do
      off = Filters.put_field(Filters.empty(), paid, %{"checked" => "false"})
      assert Filters.field_condition(off, paid).checked == false
      assert Filters.put_field(off, paid, %{"checked" => "false"}) == Filters.empty()

      on = Filters.put_field(off, paid, %{"checked" => "true"})
      assert Filters.field_condition(on, paid).checked == true
    end

    test "a view keeps Off, and it keeps an empty card, decorated or not", %{paid: paid} = ctx do
      off = Filters.put_field(Filters.empty(), paid, %{"checked" => "false"})
      kept = Filters.saved_fields(off)
      assert kept == %{to_string(paid.id) => %{"checked" => false}}

      # Read back from the address the way a view's form sends it.
      config =
        Config.from_query(
          %{"field_filters" => %{to_string(paid.id) => %{"checked" => "false"}}},
          Config.defaults("table")
        )

      assert config.field_filters == kept

      assert ctx |> loaded() |> Enum.filter(&Swimlanes.matches?(&1, config)) |> titles() ==
               ["Empty"]

      # A page placed on a board isn't decorated: its empty checkbox is off.
      assert Filters.saved_match?(card(ctx.empty), kept)
      refute Filters.saved_match?(card(ctx.checked), kept)

      restored = Filters.put_saved_fields(Filters.empty(), [paid], kept)
      assert Filters.field_condition(restored, paid).checked == false
    end
  end

  test "it sorts off before on", ctx do
    key = "f:#{ctx.paid.id}"
    asc = %Config{Config.defaults("table") | sort: key, dir: "asc"}
    assert ctx |> loaded() |> Swimlanes.sort(asc) |> titles() == ["Empty", "Checked"]
  end

  test "as an axis it has an on lane and an off lane, and the empty card is off", ctx do
    key = "f:#{ctx.paid.id}"
    board = %{fields: [ctx.paid]}
    [checked, empty] = loaded(ctx)

    buckets = Swimlanes.buckets(key, board, [checked, empty], Config.defaults("board"))
    assert Enum.map(buckets, &{&1.key, &1.label}) == [{"1", "✓ Paid"}, {"0", "Not Paid"}]

    assert Swimlanes.card_keys(checked, key, nil) == ["1"]
    assert Swimlanes.card_keys(empty, key, nil) == ["0"]

    # A drop on a lane sends its key, which sets the box.
    assert [{:field, id, "0"}] =
             Swimlanes.move_ops(key, checked, "1", "0", Config.defaults("board"))

    assert id == ctx.paid.id
  end

  test "the card front shows ✓ Paid only when it is checked", ctx do
    {:ok, paid} = Fields.update_field(ctx.paid, %{"show_on_cards" => true})
    [checked, empty] = Fields.decorate([card(ctx.checked), card(ctx.empty)], [paid])

    assert [{_, "✓ Paid"}] = checked.front_fields
    assert empty.front_fields == []
  end

  test "it reads Yes when on and nothing when off", %{paid: paid} do
    assert Fields.format(paid, 1.0) == "Yes"
    assert Fields.format(paid, 0.0) == nil
    assert Fields.format(paid, nil) == nil
    assert Fields.external(paid, 1.0) == true
    assert Fields.external(paid, nil) == nil
  end
end
