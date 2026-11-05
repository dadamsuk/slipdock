defmodule SlipdockWeb.NoRawDateInputTest do
  @moduledoc """
  Every date a person sets is a `<.date_field>` (#1720, #1721): the only
  `type="date"` in the web layer is the hidden native input inside it.
  """
  use ExUnit.Case, async: true

  @root "lib/slipdock_web"
  @home "lib/slipdock_web/components/core_components.ex"

  defp raw_dates(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> line =~ ~r/type=(?:"date"|\{\s*"date"\s*\})/ end)
  end

  test "no type=\"date\" outside date_field/1" do
    hits =
      for path <- Path.wildcard(Path.join(@root, "**/*.{ex,heex}")),
          path != @home,
          {line, n} <- raw_dates(File.read!(path)),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert hits == [], "Use <.date_field> (W-1947 §Core):\n" <> Enum.join(hits, "\n")
  end

  test "core_components has exactly one: the date field's own input" do
    # (Its docs say `<input type="date">` in backticks; those don't count.)
    code = Enum.reject(raw_dates(File.read!(@home)), fn {line, _} -> line =~ "`" end)
    assert [{_, _}] = code
  end

  test "the scan catches both spellings, and not datetime-local" do
    assert [_] = raw_dates(~s(<input type="date" name="x" />))
    assert [_] = raw_dates(~s(<.input field={@f} type="date" />))
    assert [_] = raw_dates(~s(<input type={"date"} />))
    assert raw_dates(~s(<input type="datetime-local" />)) == []
  end

  test ".input no longer takes type=\"date\"" do
    {_, attrs} =
      SlipdockWeb.CoreComponents.__components__()
      |> Map.fetch!(:input)
      |> Map.fetch!(:attrs)
      |> Enum.find(&(&1.name == :type))
      |> then(&{&1, &1.opts[:values]})

    refute "date" in attrs
  end
end
