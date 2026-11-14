defmodule Slipdock.FieldsUnitTest do
  @moduledoc "How a number field's unit is written after its value (#1698)."
  use ExUnit.Case, async: true

  alias Slipdock.Boards.FieldDefinition
  alias Slipdock.Fields

  defp number(unit), do: %FieldDefinition{kind: "number", config: %{"unit" => unit}}

  test "a percentage sits against its number" do
    assert Fields.format(number("%"), 80) == "80%"
    assert Fields.format(number("%"), 12.5) == "12.50%"
  end

  test "other signs that sit against the number do too" do
    assert Fields.format(number("°"), 21) == "21°"
  end

  test "a word is written after a space" do
    assert Fields.format(number("people"), 12) == "12 people"
    assert Fields.format(number("weeks"), 0.5) == "0.50 weeks"
  end

  test "no unit, or a blank one, is the number alone" do
    assert Fields.format(number(nil), 3) == "3"
    assert Fields.format(number(""), 3) == "3"
    assert Fields.format(%FieldDefinition{kind: "number", config: %{}}, 3) == "3"
  end

  test "tight_unit?/1 is true only for the signs that sit against a number" do
    for sign <- ~w(% ‰ ° ′ ″), do: assert(Fields.tight_unit?(sign))
    for word <- ["people", "", nil, " %", "pts"], do: refute(Fields.tight_unit?(word))
  end
end
