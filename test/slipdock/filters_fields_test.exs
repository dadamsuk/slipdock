defmodule Slipdock.FiltersFieldsTest do
  @moduledoc """
  The board toolbar's custom-field filters (#3369): each field's condition is
  read by its kind (`Slipdock.Filters.put_field/3`), and a card passes only
  when its value meets it.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Boards.{Card, FieldDefinition, FieldValue}
  alias Slipdock.Filters

  @size %FieldDefinition{
    id: 1,
    key: "size",
    name: "Size",
    kind: "select",
    options: [%{"key" => "s", "label" => "S"}, %{"key" => "l", "label" => "L"}]
  }
  @impact %FieldDefinition{id: 2, key: "impact", name: "Impact", kind: "rating", config: %{}}
  @effort %FieldDefinition{id: 3, key: "effort", name: "Effort", kind: "number", config: %{}}
  @launch %FieldDefinition{id: 4, key: "launch", name: "Launch", kind: "date", config: %{}}
  @note %FieldDefinition{id: 5, key: "note", name: "Note", kind: "text", config: %{}}
  @score %FieldDefinition{id: 6, key: "score", name: "Score", kind: "formula", config: %{}}

  defp card(title, values, computed \\ %{}) do
    %Card{
      id: System.unique_integer([:positive]),
      title: title,
      field_values:
        Enum.map(values, fn {field, attrs} ->
          struct!(FieldValue, Map.put(attrs, :field_id, field.id))
        end),
      computed: computed
    }
  end

  defp passing(cards, filters),
    do: cards |> Enum.filter(&Filters.matches?(&1, filters)) |> Enum.map(& &1.title)

  defp put(filters \\ Filters.empty(), field, params),
    do: Filters.put_field(filters, field, params)

  setup do
    cards = [
      card(
        "Small",
        [
          {@size, %{option: "s"}},
          {@impact, %{number: 2.0}},
          {@effort, %{number: 1.0}},
          {@launch, %{date: ~D[2026-12-01]}},
          {@note, %{text: "Needs a Designer"}}
        ],
        %{6 => 10.0}
      ),
      card(
        "Large",
        [
          {@size, %{option: "l"}},
          {@impact, %{number: 5.0}},
          {@effort, %{number: 8.0}},
          {@launch, %{date: ~D[2027-03-01]}},
          {@note, %{text: "backend only"}}
        ],
        %{6 => 50.0}
      ),
      card("Blank", [])
    ]

    %{cards: cards}
  end

  test "a choice field passes the options picked, and picking one again drops it", %{cards: cards} do
    filters = put(@size, %{"option" => "s"})
    assert passing(cards, filters) == ["Small"]

    filters = put(filters, @size, %{"option" => "l"})
    assert passing(cards, filters) == ["Small", "Large"]

    filters = filters |> put(@size, %{"option" => "s"}) |> put(@size, %{"option" => "l"})
    assert filters.fields == %{}
    assert passing(cards, filters) == ["Small", "Large", "Blank"]
  end

  test "an option the field doesn't have is not a filter" do
    assert put(@size, %{"option" => "xl"}).fields == %{}
  end

  test "a rating keeps the cards with at least that many stars; the same again clears it",
       %{cards: cards} do
    filters = put(@impact, %{"min" => "3"})
    assert passing(cards, filters) == ["Large"]
    assert passing(cards, put(@impact, %{"min" => "2"})) == ["Small", "Large"]
    assert put(filters, @impact, %{"min" => "3"}).fields == %{}
  end

  test "a number field takes a min, a max or both", %{cards: cards} do
    assert passing(cards, put(@effort, %{"min" => "2", "max" => ""})) == ["Large"]
    assert passing(cards, put(@effort, %{"min" => "", "max" => "1"})) == ["Small"]
    assert passing(cards, put(@effort, %{"min" => "0.5", "max" => "9"})) == ["Small", "Large"]
    assert passing(cards, put(@effort, %{"min" => "2", "max" => "7"})) == []
    assert put(@effort, %{"min" => "", "max" => "abc"}).fields == %{}
  end

  test "a formula field filters on its computed value", %{cards: cards} do
    assert passing(cards, put(@score, %{"min" => "20"})) == ["Large"]
  end

  test "a date field takes from and to, both ends included", %{cards: cards} do
    assert passing(cards, put(@launch, %{"from" => "2027-01-01", "to" => ""})) == ["Large"]
    assert passing(cards, put(@launch, %{"from" => "", "to" => "2026-12-01"})) == ["Small"]

    assert passing(cards, put(@launch, %{"from" => "2026-12-01", "to" => "2027-03-01"})) ==
             ["Small", "Large"]

    assert put(@launch, %{"from" => "not a date"}).fields == %{}
  end

  test "a text field matches words it contains, in any case", %{cards: cards} do
    assert passing(cards, put(@note, %{"text" => "designer"})) == ["Small"]
    assert put(@note, %{"text" => "  "}).fields == %{}
  end

  test "field filters combine with each other and count once each in the badge", %{cards: cards} do
    filters = Filters.empty() |> put(@size, %{"option" => "l"}) |> put(@effort, %{"max" => "5"})
    assert passing(cards, filters) == []
    assert Filters.count(filters) == 2
    assert Filters.any?(filters)

    filters = %{filters | hide_completed: true} |> put(@effort, %{"max" => ""})
    assert passing(cards, filters) == ["Large"]
    assert Filters.count(filters) == 2
  end

  test "a card with no value for the field never passes a filter on it", %{cards: cards} do
    for {field, params} <- [
          {@size, %{"option" => "s"}},
          {@impact, %{"min" => "1"}},
          {@effort, %{"min" => "-100"}},
          {@launch, %{"from" => "1900-01-01"}},
          {@note, %{"text" => "e"}},
          {@score, %{"min" => "-1"}}
        ] do
      refute "Blank" in passing(cards, put(field, params))
    end
  end

  test "a filters map from before the field filters still matches and counts" do
    old = Map.delete(Filters.empty(), :fields)
    assert Filters.matches?(card("Old", []), old)
    assert Filters.count(old) == 0
  end
end
