defmodule Slipdock.Wiki.TranscriptTagsTest do
  @moduledoc "The moments a recording was tagged at, read from a meeting page (#785)."
  use ExUnit.Case, async: true

  alias Slipdock.Wiki.TranscriptTags

  describe "parse/1" do
    test "reads a recorder's Tags line" do
      assert TranscriptTags.parse("Summary.\n\nTags: #important (0:05) #action (0:10)\n") == [
               %{tag: "important", ms: 5_000},
               %{tag: "action", ms: 10_000}
             ]
    end

    test "hours, fractions, odd spacing and several lines, in time order" do
      body = """
      tags:   #late (1:02:03.5)  #decision(0:07)
      Tags: #first (0:00)
      """

      assert TranscriptTags.parse(body) == [
               %{tag: "first", ms: 0},
               %{tag: "decision", ms: 7_000},
               %{tag: "late", ms: 3_723_500}
             ]
    end

    test "passes over anything that isn't a timed tag" do
      assert TranscriptTags.parse("Tags: #untimed #bad (soon) plain (0:05) #ok (0:01)") == [
               %{tag: "ok", ms: 1_000}
             ]

      assert TranscriptTags.parse("No tags here. #tag (0:05) on a line of its own.") == []
      assert TranscriptTags.parse("Some Tags: are mid-line #x (0:05)") == []
      # A name is letters, digits and _-/ only: markup never reaches the chip.
      assert TranscriptTags.parse("Tags: #a<b>x</b> (0:01) #<script> (0:02)") == []
      assert TranscriptTags.parse("") == []
      assert TranscriptTags.parse(nil) == []
    end
  end

  describe "place/2" do
    # Two turns: Alice's two cues, then Bob's after a silence.
    @turns [
      %{
        cues: [
          %{start_ms: 1_000, end_ms: 5_000, text: "one two three four"},
          %{start_ms: 5_000, end_ms: 6_000, text: "five"}
        ]
      },
      %{cues: [%{start_ms: 10_000, end_ms: 12_000, text: "six seven"}]}
    ]

    defp at(ms), do: TranscriptTags.place(@turns, [%{tag: "t", ms: ms}])

    test "in the cue being spoken, the same fraction of the way through" do
      assert at(1_000) == %{{0, 0} => [{0, %{tag: "t", ms: 1_000}}]}
      assert at(3_000) == %{{0, 0} => [{2, %{tag: "t", ms: 3_000}}]}
      assert at(5_500) == %{{0, 1} => [{1, %{tag: "t", ms: 5_500}}]}
      assert at(11_000) == %{{1, 0} => [{1, %{tag: "t", ms: 11_000}}]}
    end

    test "in a silence, before the next cue; before the first; after the last" do
      assert at(8_000) == %{{1, 0} => [{0, %{tag: "t", ms: 8_000}}]}
      assert at(0) == %{{0, 0} => [{0, %{tag: "t", ms: 0}}]}
      assert at(99_000) == %{{1, 0} => [{2, %{tag: "t", ms: 99_000}}]}
    end

    test "several tags in one cue, and none at all" do
      tags = [%{tag: "a", ms: 2_000}, %{tag: "b", ms: 4_000}]

      assert TranscriptTags.place(@turns, tags) == %{
               {0, 0} => [{1, %{tag: "a", ms: 2_000}}, {3, %{tag: "b", ms: 4_000}}]
             }

      assert TranscriptTags.place(@turns, []) == %{}
      assert TranscriptTags.place([], tags) == %{}
    end
  end
end
