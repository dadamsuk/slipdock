defmodule Slipdock.Wiki.ViewerTest do
  @moduledoc "Which viewer a wiki file gets, and the JSON and CSV it is read as."
  use ExUnit.Case, async: true

  alias Slipdock.Wiki.{Viewer, WikiFile}

  defp file(name), do: %WikiFile{name: name, content_type: WikiFile.content_type(name)}

  test "the kind follows the name, case and all" do
    assert Viewer.kind(file("cat.PNG")) == :image
    assert Viewer.kind(file("cat.jpeg")) == :image
    assert Viewer.kind(file("logo.svg")) == :svg
    assert Viewer.kind(file("Spec.pdf")) == :pdf
    assert Viewer.kind(file("data.json")) == :json
    assert Viewer.kind(file("events.ndjson")) == :json
    assert Viewer.kind(file("sales.csv")) == :csv
    assert Viewer.kind(file("sales.tsv")) == :tsv
    assert Viewer.kind(file("notes.txt")) == :text
    assert Viewer.kind(file("song.mp3")) == :none
    assert Viewer.kind(file("README")) == :none
  end

  describe "json" do
    test "a document is a tree that keeps the file's key order, and pretty text" do
      assert {:ok, tree, pretty} = Viewer.json(~s({"b": 1, "a": [true, null, "x"]}))

      assert tree ==
               {:object,
                [
                  {"b", {:value, "1"}},
                  {"a", {:array, [{:value, "true"}, {:value, "null"}, {:value, ~s("x")}]}}
                ]}

      assert pretty =~ ~s("b": 1)
      assert String.split(pretty, "\n") |> length() > 1
      assert :binary.match(pretty, ~s("b")) < :binary.match(pretty, ~s("a"))
    end

    test "invalid JSON says the line and column it stopped at" do
      assert {:error, message} = Viewer.json(~s({\n  "a": 1,\n  oops\n}))
      assert message =~ "line 3, column 3"
    end

    test "a document with too many values is pretty text without a tree" do
      big = Jason.encode!(Enum.to_list(1..6_000))
      assert {:ok, nil, pretty} = Viewer.json(big)
      assert pretty =~ "5999"
    end

    test "JSON Lines is an array of its lines, blank lines skipped" do
      assert {:ok, {:array, [{:object, _}, {:value, "2"}]}, _} =
               Viewer.json(~s({"a": 1}\n\n2\n), "log.jsonl")

      assert {:error, "Line 2 isn't JSON."} = Viewer.json(~s(1\nnope\n), "log.ndjson")
    end
  end

  describe "csv" do
    test "the first row is the header; quoted fields keep commas, quotes and line breaks" do
      text = ~s(name,note\r\nAda,"says ""hi"", twice"\r\nBob,"two\nlines"\r\n)

      assert Viewer.csv(text) == %{
               header: ["name", "note"],
               rows: [["Ada", ~s(says "hi", twice)], ["Bob", "two\nlines"]],
               total: 2
             }
    end

    test "tabs as the separator, ragged rows padded, blank lines dropped" do
      assert Viewer.csv("a\tb\tc\n1\n\n2\t3\t4\t5\n", ?\t) == %{
               header: ["a", "b", "c", ""],
               rows: [["1", "", "", ""], ["2", "3", "4", "5"]],
               total: 2
             }
    end

    test "an empty file has no header; an unclosed quote runs to the end" do
      assert Viewer.csv("") == %{header: [], rows: [], total: 0}
      assert %{rows: [["x", "open, still"]]} = Viewer.csv(~s(a,b\nx,"open, still))
    end

    test "a long file is cut at max_rows, with the full count kept" do
      text = Enum.map_join(0..(Viewer.max_rows() + 5), "\n", &"r#{&1}")
      table = Viewer.csv(text)
      assert length(table.rows) == Viewer.max_rows()
      assert table.total == Viewer.max_rows() + 5
      assert hd(table.rows) == ["r1"]
    end
  end
end
