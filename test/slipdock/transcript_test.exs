defmodule Slipdock.TranscriptTest do
  @moduledoc """
  The transcripts the wiki shows and voiceprints read (#532, #1817): WebVTT,
  SubRip and "Name: words" read into lines, speakers and times kept, words
  exactly as written, and the mess real exports carry (byte-order marks,
  CRLF, overlapping cues, missing speakers) handled.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Transcript

  @dir Path.expand("../fixtures/transcript", __DIR__)
  defp fixture(name), do: File.read!(Path.join(@dir, name))

  @expected [
    {"Priya", 0, "Let's settle the pricing page."},
    {"Sam", 4_000, "We go with the annual plan at 20% off."},
    {"Priya", 9_000, "Sam, can you update PL-14 by Friday?"}
  ]

  for {file, format} <- [{"pricing.vtt", "vtt"}, {"pricing.srt", "srt"}, {"pricing.txt", "text"}] do
    test "#{file} reads as #{format} into the same lines" do
      assert {:ok, %{format: unquote(format), lines: lines}} =
               Transcript.parse(fixture(unquote(file)), filename: unquote(file))

      assert Enum.map(lines, &{&1.speaker, &1.start_ms, &1.text}) == @expected
      assert [%{end_ms: 4_000}, %{end_ms: 9_000} | _] = lines
    end

    test "#{file} is found to be #{format} from its content alone" do
      assert {:ok, %{format: unquote(format)}} = Transcript.parse(fixture(unquote(file)))
    end
  end

  test "the format given wins over what the content looks like" do
    assert {:ok, %{format: "text", lines: [line | _]}} =
             Transcript.parse(fixture("pricing.vtt"), format: "text")

    assert line.text == "WEBVTT"
  end

  test "a messy WebVTT: BOM, CRLF, STYLE, no hours, overlaps, tags and entities" do
    assert {:ok, %{format: "vtt", lines: lines}} = Transcript.parse(fixture("messy.vtt"))

    assert lines == [
             %{
               speaker: nil,
               start_ms: 1_000,
               end_ms: 3_500,
               text: "Nobody named here & that is fine"
             },
             %{
               speaker: "Sam Smith",
               start_ms: 3_000,
               end_ms: 6_000,
               text: "Overlapping with the one before"
             },
             %{speaker: "Priya", start_ms: 5_000, end_ms: 7_000, text: "and this one too"}
           ]
  end

  test "a messy SRT: CRLF, markup, a cue without a speaker, an empty cue dropped" do
    assert {:ok, %{format: "srt", lines: lines}} = Transcript.parse(fixture("messy.srt"))

    assert lines == [
             %{speaker: nil, start_ms: 1_500, end_ms: 3_000, text: "No speaker on this cue"},
             %{
               speaker: "Sam",
               start_ms: 2_000,
               end_ms: 4_000,
               text: "overlapping, with a speaker"
             }
           ]
  end

  test "plain text keeps lines with no speaker, and is not fooled by a colon mid-sentence" do
    text = "Priya: Hello all\nWe agreed on three things today: ship it, test it, tell people\n"
    assert {:ok, %{format: "text", lines: [a, b]}} = Transcript.parse(text)
    assert a == %{speaker: "Priya", start_ms: nil, end_ms: nil, text: "Hello all"}
    assert b.speaker == nil
    assert b.text == "We agreed on three things today: ship it, test it, tell people"
  end

  test "words are kept exactly, apart from runs of whitespace" do
    {:ok, %{lines: [line]}} = Transcript.parse("Sam:  “Let’s   ship” — 15%… by Fri.")
    assert line.text == "“Let’s ship” — 15%… by Fri."
  end

  describe "refusals" do
    test "an empty transcript" do
      assert {:error, "the transcript is empty"} = Transcript.parse("  \n\uFEFF ")
    end

    test "bytes that are not text" do
      assert {:error, "the transcript is not text (it should be UTF-8)"} =
               Transcript.parse(<<0xFF, 0xFE, 0x00, 0x41>>)
    end

    test "a WebVTT with no cues has no words" do
      assert {:error, "no words were found in the transcript (read as vtt)"} =
               Transcript.parse("WEBVTT\n\nNOTE nothing said\n")
    end

    test "a format only meeting capture read is not read here" do
      assert {:error,
              ~s["otter" is not a transcript format this server reads (it reads vtt, srt, text)]} =
               Transcript.parse(~s({"transcripts": []}), format: "otter")
    end
  end

  test "timestamps of every shape" do
    assert Transcript.timestamp_ms("01:02:03.456") == 3_723_456
    assert Transcript.timestamp_ms("02:03,4") == 123_400
    assert Transcript.timestamp_ms("2:03") == 123_000
  end

  test "person_label? tells a person's name from a placeholder for a voice" do
    for name <- ["Priya Nair", "Ryan", "José", "Dr. Okafor"],
        do: assert(Transcript.person_label?(name))

    for label <- [
          "Speaker 2",
          "speaker_00",
          "SPEAKER_01",
          "Unknown-3",
          "Unknown",
          "Voice 4",
          "S1",
          "spk 2",
          "Participant 7",
          "Guest",
          "",
          "  ",
          "42",
          nil
        ],
        do: refute(Transcript.person_label?(label), inspect(label))
  end
end
