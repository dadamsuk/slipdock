defmodule SlipdockCLI.FieldDetailsRenderTest do
  @moduledoc """
  The DETAILS cell `slipdock fields` gives a number field (#2761): the parts
  its config has, one space apart, and nothing where a part is missing, so a
  field with only a max or only a min reads as that and no more.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  defp plain(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  # The DETAILS cell of a one-field table: from where its header starts to
  # the end of the row, as printed.
  defp details(config) do
    field = %{"id" => 1, "name" => "N", "key" => "n", "kind" => "number", "config" => config}

    [header, row | _] =
      capture_io(fn -> Render.fields([field]) end) |> plain() |> String.split("\n")

    {at, _} = :binary.match(header, "DETAILS")
    binary_part(row, at, byte_size(row) - at)
  end

  test "a number field with only a max shows exactly that" do
    assert details(%{"max" => 10}) == "max 10"
  end

  test "a number field with only a min shows exactly that" do
    assert details(%{"min" => 1}) == "min 1"
  end

  test "a min, a max and a unit, one space apart" do
    assert details(%{"min" => 1, "max" => 10, "unit" => "kg"}) == "min 1 max 10 kg"
  end
end
