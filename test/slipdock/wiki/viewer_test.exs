defmodule Slipdock.Wiki.ViewerTest do
  @moduledoc "Which viewer a wiki file gets, and the JSON, CSV and transcripts it is read as."
  use ExUnit.Case, async: true

  alias Slipdock.Wiki.{Viewer, WikiFile}

  defp file(name), do: %WikiFile{name: name, content_type: WikiFile.content_type(name)}

  test "the kind follows the name, case and all" do
    assert Viewer.kind(file("cat.PNG")) == :image
    assert Viewer.kind(file("cat.jpeg")) == :image
    assert Viewer.kind(file("logo.svg")) == :svg
    assert Viewer.kind(file("Spec.pdf")) == :pdf
    assert Viewer.kind(file("Report.html")) == :html
    assert Viewer.kind(file("old.HTM")) == :html
    assert Viewer.kind(file("data.json")) == :json
    assert Viewer.kind(file("events.ndjson")) == :json
    assert Viewer.kind(file("sales.csv")) == :csv
    assert Viewer.kind(file("sales.tsv")) == :tsv
    assert Viewer.kind(file("notes.txt")) == :text
    assert Viewer.kind(file("song.mp3")) == :audio
    assert Viewer.kind(file("Memo.M4A")) == :audio
    assert Viewer.kind(file("take.wav")) == :audio
    assert Viewer.kind(file("standup.vtt")) == :transcript
    assert Viewer.kind(file("Film.SRT")) == :transcript
    assert Viewer.kind(file("clip.mp4")) == :none
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

  describe "transcript" do
    @vtt """
    WEBVTT

    NOTE recorded on Tuesday

    1
    00:00:01.000 --> 00:00:04.000
    <v Priya Shah>Morning, <b>all</b>.</v>

    2
    00:00:04.500 --> 00:00:06.000
    <v Priya Shah>Shall we start?

    3
    00:00:06.000 --> 00:01:02.250 align:start
    <v Tom>Yes &amp; quickly.

    4
    00:01:03.000 --> 01:00:00.000
    <v Priya Shah>Good.
    """

    test "cues from the same speaker in a row are one turn; speakers in the order they speak" do
      assert {:ok, %{turns: turns, speakers: speakers, duration_ms: duration}} =
               Viewer.transcript(@vtt, "standup.vtt")

      assert turns == [
               %{
                 speaker: "Priya Shah",
                 start_ms: 1_000,
                 end_ms: 6_000,
                 lines: ["Morning, all.", "Shall we start?"]
               },
               %{speaker: "Tom", start_ms: 6_000, end_ms: 62_250, lines: ["Yes & quickly."]},
               %{speaker: "Priya Shah", start_ms: 63_000, end_ms: 3_600_000, lines: ["Good."]}
             ]

      assert speakers == ["Priya Shah", "Tom"]
      assert duration == 3_600_000
    end

    test "a Name: prefix names the speaker; cues with no name are turns with none" do
      text =
        "WEBVTT\n\n00:01.000 --> 00:02.000\nAda: Hello\n\n00:02.000 --> 00:03.000\njust words\n"

      assert {:ok,
              %{
                turns: [%{speaker: "Ada"}, %{speaker: nil, lines: ["just words"]}],
                speakers: ["Ada"]
              }} =
               Viewer.transcript(text, "a.vtt")
    end

    test "an .srt is read as SubRip" do
      srt = "1\n00:00:01,000 --> 00:00:02,000\nBob: Hi there\n"

      assert {:ok, %{turns: [%{speaker: "Bob", lines: ["Hi there"]}]}} =
               Viewer.transcript(srt, "x.srt")
    end

    test "a file with no cues, or nothing in it, says it isn't a transcript" do
      assert {:error, message} = Viewer.transcript("WEBVTT\n\nNOTE nothing here\n", "a.vtt")
      assert message =~ "doesn't read as a VTT transcript"
      assert {:error, _} = Viewer.transcript("", "a.vtt")
    end
  end
end
