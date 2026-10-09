defmodule Slipdock.Meetings.TranscriptTest do
  @moduledoc """
  Transcripts in every format read into the same lines (#532): speakers and
  times kept, words exactly as written, and the mess real exports carry
  (byte-order marks, CRLF, overlapping cues, missing speakers) handled.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Meetings.{Calendar, Transcript}

  @dir Path.expand("../../fixtures/meetings", __DIR__)
  defp fixture(name), do: File.read!(Path.join(@dir, name))

  @expected [
    {"Priya", 0, "Let's settle the pricing page."},
    {"Sam", 4_000, "We go with the annual plan at 20% off."},
    {"Priya", 9_000, "Sam, can you update PL-14 by Friday?"}
  ]

  for {file, format} <- [
        {"pricing.vtt", "vtt"},
        {"pricing.srt", "srt"},
        {"pricing.txt", "text"},
        {"pricing_otter.txt", "blocks"},
        {"pricing_fireflies.json", "fireflies"},
        {"pricing_otter.json", "otter"}
      ] do
    test "#{file} reads as #{format} into the same lines" do
      assert {:ok, %{format: unquote(format), lines: lines}} =
               Transcript.parse(fixture(unquote(file)), filename: unquote(file))

      assert Enum.map(lines, &{&1.speaker, &1.start_ms, &1.text}) == @expected
      # Every line ends where the next starts, or later.
      assert [%{end_ms: e1}, %{end_ms: e2} | _] = lines
      assert e1 == 4_000 and e2 == 9_000
    end
  end

  test "the format is found from the content when the name says nothing" do
    for file <-
          ~w(pricing.vtt pricing.srt pricing.txt pricing_otter.txt pricing_fireflies.json pricing_otter.json) do
      assert {:ok, %{lines: lines}} = Transcript.parse(fixture(file))
      assert Enum.map(lines, & &1.text) == Enum.map(@expected, &elem(&1, 2)), file
    end
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
      assert {:error, "the transcript is empty"} = Transcript.parse("\uFEFF")
    end

    test "bytes that are not text" do
      assert {:error, "the transcript is not text (it should be UTF-8)"} =
               Transcript.parse(<<0xFF, 0xFE, 0x00, 0x41>>)
    end

    test "JSON that is broken, or is not a known export" do
      assert {:error, "the JSON is not valid" <> _} =
               Transcript.parse("{\"sentences\": [", filename: "x.json")

      assert {:error, "the JSON has no `sentences`" <> _} = Transcript.parse(~s({"words": 1}))

      assert {:error, "the JSON has no `transcripts`" <> _} =
               Transcript.parse(~s({"a": 1}), format: "otter")
    end

    test "a WebVTT with no cues has no words" do
      assert {:error, "no words were found in the transcript (read as vtt)"} =
               Transcript.parse("WEBVTT\n\nNOTE nothing said\n")
    end

    test "a format nobody reads" do
      assert {:error, ~s("docx" is not a transcript format) <> _} =
               Transcript.parse("hello", format: "docx")
    end
  end

  test "timestamps of every shape" do
    assert Transcript.timestamp_ms("01:02:03.456") == 3_723_456
    assert Transcript.timestamp_ms("02:03,4") == 123_400
    assert Transcript.timestamp_ms("2:03") == 123_000
  end

  describe "invites" do
    test "attendees, start and title, unfolding long lines and unquoting names" do
      assert {:ok, invite} = Calendar.parse(fixture("pricing.ics"))
      assert invite.title == "Pricing sync, weekly"
      assert invite.started_at == ~U[2026-10-07 10:00:00Z]

      assert invite.attendees == [
               %{name: "Priya Shah", email: "priya@example.com"},
               %{name: "Sam Smith", email: "sam@example.com"},
               %{name: "Lee, Jo", email: "jo@example.com"}
             ]
    end

    test "an invite with no event is refused" do
      assert {:error, "the invite has no event in it"} =
               Calendar.parse("BEGIN:VCALENDAR\nEND:VCALENDAR")
    end

    test "a date-only start reads as midnight, a nonsense one as nothing" do
      ics = "BEGIN:VEVENT\nDTSTART;VALUE=DATE:20261007\nEND:VEVENT"
      assert {:ok, %{started_at: ~U[2026-10-07 00:00:00Z], attendees: []}} = Calendar.parse(ics)
      assert {:ok, %{started_at: nil}} = Calendar.parse("BEGIN:VEVENT\nDTSTART:soon\nEND:VEVENT")
    end
  end
end
