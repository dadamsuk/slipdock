defmodule Slipdock.SeveralChoiceFieldTest do
  @moduledoc """
  A choice field that allows several (#3611): what it takes and refuses,
  the order it keeps, the filter that keeps a card holding any of the
  options picked, the swimlane axis that puts a card in each of its
  options' lanes and a drag that swaps one, the formula that adds their
  weights, the sort, and switching Allow several on and off.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields, Filters, Swimlanes}
  alias Slipdock.Boards.FieldDefinition
  alias Slipdock.Swimlanes.Config

  setup do
    board = board_fixture(%{"name" => "Releases"})
    [_backlog, todo | _] = board.columns

    # Option order differs from the alphabet, so a sort by position shows.
    {:ok, area} =
      Fields.create_field(board, %{
        "name" => "Area",
        "kind" => "select",
        "options" => [
          %{"label" => "Web", "weight" => 1},
          %{"label" => "API", "weight" => 2},
          %{"label" => "Billing", "weight" => 4}
        ],
        "config" => %{"several" => true}
      })

    {:ok, reach} =
      Fields.create_field(board, %{
        "name" => "Reach",
        "kind" => "formula",
        "config" => %{"mode" => "expression", "expression" => "{area} * 10"}
      })

    both = card_fixture(todo, %{"title" => "Both"})
    billing = card_fixture(todo, %{"title" => "Billing only"})
    empty = card_fixture(todo, %{"title" => "Empty"})
    {:ok, _} = Fields.set_value(both, area, "web, api")
    {:ok, _} = Fields.set_value(billing, area, ["billing"])

    %{board: board, area: area, reach: reach, both: both, billing: billing, empty: empty}
  end

  defp card(card), do: Boards.Cards.get_card!(card.id)
  defp titles(cards), do: Enum.map(cards, & &1.title)
  defp area_of(card, area), do: Fields.value(card(card), area)

  defp loaded(ctx) do
    fields = Fields.list_fields(Boards.Board.root_id(ctx.board))
    Fields.decorate([card(ctx.both), card(ctx.billing), card(ctx.empty)], fields)
  end

  test "the field says it allows several, and a single choice doesn't", %{area: area} = ctx do
    assert FieldDefinition.several?(area)

    {:ok, one} =
      Fields.create_field(ctx.board, %{
        "name" => "Size",
        "kind" => "select",
        "options" => ["S", "L"]
      })

    refute FieldDefinition.several?(one)
  end

  describe "setting it" do
    test "takes keys or labels, a list or a comma-separated string, in option order",
         %{area: area, empty: empty} do
      for raw <- ["api, web", "API,Web", ["api", "web"], ["Web", "API"], "web,api,web"] do
        {:ok, set} = Fields.set_value(card(empty), area, raw)
        assert Fields.value(set, area) == ["web", "api"], "#{inspect(raw)} wasn't web, api"
      end

      # Stored in the options column, the single one left empty.
      [stored] = card(empty).field_values
      assert stored.options == ["web", "api"]
      assert stored.option == nil
    end

    test "an unknown option is refused naming the field, and the value stays",
         %{area: area, both: both} do
      assert {:error, message} = Fields.set_value(card(both), area, "web, mobile")
      assert message =~ "Area"
      assert message =~ "mobile"
      assert area_of(both, area) == ["web", "api"]
    end

    test "empty clears it: a blank, an empty list, or a form's lone blank",
         %{area: area, both: both} do
      for raw <- ["", [], [""], nil] do
        {:ok, _} = Fields.set_value(card(both), area, "web")
        {:ok, cleared} = Fields.set_value(card(both), area, raw)
        assert Fields.value(cleared, area) == nil, "#{inspect(raw)} didn't clear it"
        assert cleared.field_values == []
      end
    end

    test "a single choice still takes one option and refuses several", %{board: board, both: both} do
      {:ok, size} =
        Fields.create_field(board, %{
          "name" => "Size",
          "kind" => "select",
          "options" => ["S", "L"]
        })

      {:ok, set} = Fields.set_value(card(both), size, "L")
      assert Fields.value(set, size) == "l"
      assert {:error, message} = Fields.set_value(card(both), size, ["s", "l"])
      assert message =~ "Size"
      assert Fields.value(card(both), size) == "l"
    end
  end

  test "it reads as its labels in option order, and the API gives the keys",
       %{area: area} = ctx do
    assert Fields.format(area, area_of(ctx.both, area)) == "Web, API"
    assert Fields.external(area, area_of(ctx.both, area)) == ["web", "api"]
    assert Fields.format(area, nil) == nil
  end

  test "in a formula it is the sum of its options' weights", %{reach: reach, area: area} = ctx do
    [both, billing, empty] = loaded(ctx)
    assert Fields.numeric(both, area) == 3.0
    assert Fields.value(both, reach) == 30.0
    assert Fields.value(billing, reach) == 40.0
    assert Fields.value(empty, reach) == nil
  end

  describe "filtering" do
    test "keeps a card holding any of the options picked", %{area: area} = ctx do
      api = Filters.put_field(Filters.empty(), area, %{"option" => "api"})
      assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, api)) |> titles() == ["Both"]

      api_or_billing = Filters.put_field(api, area, %{"option" => "billing"})

      assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, api_or_billing)) |> titles() ==
               ["Both", "Billing only"]
    end

    test "a view keeps the filter, and it keeps a card holding any of them",
         %{area: area} = ctx do
      filters = Filters.put_field(Filters.empty(), area, %{"option" => "web"})
      kept = %{Config.defaults("table") | field_filters: Filters.saved_fields(filters)}
      assert ctx |> loaded() |> Enum.filter(&Swimlanes.matches?(&1, kept)) |> titles() == ["Both"]
    end
  end

  describe "kept filters" do
    test "two options picked survive saved_fields and put_saved_fields", %{area: area} = ctx do
      filters =
        Filters.empty()
        |> Filters.put_field(area, %{"option" => "api"})
        |> Filters.put_field(area, %{"option" => "billing"})

      saved = Filters.saved_fields(filters)
      assert saved == %{to_string(area.id) => %{"options" => ["api", "billing"]}}

      fields = Fields.list_fields(Boards.Board.root_id(ctx.board))
      restored = Filters.put_saved_fields(Filters.empty(), fields, saved)
      assert Filters.field_condition(restored, area).options == ["api", "billing"]

      assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, restored)) |> titles() ==
               ["Both", "Billing only"]
    end

    test "a view's options filter survives its address", %{area: area} = ctx do
      filters = Filters.put_field(Filters.empty(), area, %{"option" => "web"})
      config = %{Config.defaults("table") | field_filters: Filters.saved_fields(filters)}

      # Through the query string and back, as a reload reads it.
      query = config |> Config.to_query() |> Plug.Conn.Query.encode()
      back = query |> Plug.Conn.Query.decode() |> Config.from_query(Config.defaults("table"))

      assert back.field_filters == %{to_string(area.id) => %{"options" => ["web"]}}
      assert ctx |> loaded() |> Enum.filter(&Swimlanes.matches?(&1, back)) |> titles() == ["Both"]
    end
  end

  test "it sorts by the first option's place in the field, not its name", %{area: area} = ctx do
    # Web (first) before Billing (third), though "billing" < "web".
    asc = %Config{Config.defaults("table") | sort: "f:#{area.id}", dir: "asc"}
    cards = ctx |> loaded() |> Enum.reverse()
    assert cards |> Swimlanes.sort(asc) |> titles() == ["Both", "Billing only", "Empty"]

    assert cards |> Swimlanes.sort(%{asc | dir: "desc"}) |> titles() ==
             ["Billing only", "Both", "Empty"]
  end

  describe "as a swimlane axis" do
    test "a card sits in each of its options' lanes, and an empty one in none",
         %{board: board, area: area} = ctx do
      key = "f:#{area.id}"
      [both, billing, empty] = loaded(ctx)

      assert Swimlanes.card_keys(both, key, nil) == ["web", "api"]
      assert Swimlanes.card_keys(billing, key, nil) == ["billing"]
      assert Swimlanes.card_keys(empty, key, nil) == ["none"]

      board = %{Boards.get_board!(board.id) | fields: [area, ctx.reach]}
      config = %Config{Config.defaults("swimlanes") | rows: key, cols: "none"}
      grid = Swimlanes.grid(board, config)

      lanes = Map.new(grid.rows, &{&1.key, &1.cells |> List.flatten() |> titles()})
      assert lanes["web"] == ["Both"]
      assert lanes["api"] == ["Both"]
      assert lanes["billing"] == ["Billing only"]
      assert lanes["none"] == ["Empty"]
    end

    test "a drag between two lanes swaps that option and keeps the rest", %{area: area} = ctx do
      key = "f:#{area.id}"
      config = Config.defaults("swimlanes")
      both = card(ctx.both)

      assert [{:field, id, keys}] = Swimlanes.move_ops(key, both, "api", "billing", config)
      assert id == area.id
      assert keys == ["web", "billing"]

      {:ok, moved} = Fields.set_value(both, area, keys)
      assert Fields.value(moved, area) == ["web", "billing"]

      # Onto a lane it is already in, it just leaves the one it came from.
      assert [{:field, _, ["billing"]}] = Swimlanes.move_ops(key, moved, "web", "billing", config)

      # Onto the lane with none, it loses only the one it came from.
      assert [{:field, _, ["web"]}] = Swimlanes.move_ops(key, moved, "billing", "none", config)

      # An empty card dragged into a lane gets that option.
      assert [{:field, _, "api"}] =
               Swimlanes.move_ops(key, card(ctx.empty), "none", "api", config)
    end
  end

  describe "switching Allow several" do
    test "off keeps each card's first option, in the field's option order",
         %{area: area} = ctx do
      # Reorder the options so Billing comes first, then hold Web and Billing.
      {:ok, area} =
        Fields.update_field(area, %{
          "options" => [
            %{"key" => "billing", "label" => "Billing", "weight" => 4},
            %{"key" => "web", "label" => "Web", "weight" => 1},
            %{"key" => "api", "label" => "API", "weight" => 2}
          ]
        })

      {:ok, _} = Fields.set_value(card(ctx.billing), area, "web, billing")
      assert Fields.several_held?(area)

      {:ok, single} = Fields.update_field(area, %{"config" => %{"several" => false}})
      refute FieldDefinition.several?(single)
      refute Fields.several_held?(single)

      # Both held Web and API, stored when Web came before API: Web is first.
      assert area_of(ctx.both, single) == "web"
      # Billing only now held Web and Billing: Billing is first in the field.
      assert area_of(ctx.billing, single) == "billing"
      assert area_of(ctx.empty, single) == nil

      [stored] = card(ctx.billing).field_values
      assert stored.option == "billing"
      assert stored.options == nil
    end

    test "on turns each single option into a list of one", %{board: board, both: both} do
      {:ok, size} =
        Fields.create_field(board, %{
          "name" => "Size",
          "kind" => "select",
          "options" => ["S", "L"]
        })

      {:ok, _} = Fields.set_value(card(both), size, "s")
      refute Fields.several_held?(size)

      {:ok, several} = Fields.update_field(size, %{"config" => %{"several" => true}})
      assert FieldDefinition.several?(several)
      assert area_of(both, several) == ["s"]

      [stored] = Enum.filter(card(both).field_values, &(&1.field_id == size.id))
      assert stored.options == ["s"]
      assert stored.option == nil

      {:ok, set} = Fields.set_value(card(both), several, "s, l")
      assert Fields.value(set, several) == ["s", "l"]
      assert Fields.several_held?(several)
    end

    test "a card holding one option doesn't count as holding several", %{area: area} = ctx do
      {:ok, _} = Fields.set_value(card(ctx.both), area, "web")
      refute Fields.several_held?(area)
    end
  end
end
