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

  describe "chats (#1073)" do
    test "a turn runs on to the next label, and a leading preamble is nobody's" do
      text = """
      Exported from my notes.

      User: Should we ship the pricing page on Friday?
      I think so, but check with Sam.
      Assistant: Two things first:
      1. the copy
      2. the 20% annual discount
      User: Agreed. Let's ship it Friday.
      """

      assert {:ok, %{format: "chat", lines: lines}} = Transcript.parse(text)

      assert Enum.map(lines, &{&1.speaker, &1.text}) == [
               {nil, "Exported from my notes."},
               {"User",
                "Should we ship the pricing page on Friday? I think so, but check with Sam."},
               {"Assistant", "Two things first: 1. the copy 2. the 20% annual discount"},
               {"User", "Agreed. Let's ship it Friday."}
             ]

      assert Enum.all?(lines, &(&1.start_ms == nil and &1.end_ms == nil))
    end

    test "a label inside a code fence, or a lone Note:, is part of the turn" do
      text = """
      **David:** How do I log it?
      Claude: Like this:
      ```
      User: not a turn
      ```
      Note: it goes to stderr.
      David: Thanks, done.
      """

      assert {:ok, %{format: "chat", lines: lines}} = Transcript.parse(text)
      assert Enum.map(lines, & &1.speaker) == ["David", "Claude", "David"]
      [_, answer, _] = lines
      assert answer.text == "Like this: ``` User: not a turn ``` Note: it goes to stderr."
    end

    test "a label alone on its line takes the words below it" do
      assert {:ok, %{lines: [line]}} =
               Transcript.parse("Claude:\nShip it.\nThen tell people.", format: "chat")

      assert line == %{
               speaker: "Claude",
               start_ms: nil,
               end_ms: nil,
               text: "Ship it. Then tell people."
             }
    end

    test "meetings are still meetings: timestamps or no chat labels read as text" do
      assert {:ok, %{format: "text"}} = Transcript.parse(fixture("pricing.txt"))
      assert {:ok, %{format: "text"}} = Transcript.parse("Priya: hello\nSam: hi")
      assert Transcript.detect("User: hi\nAssistant: hello") == "chat"
      assert Transcript.detect("Priya: see\n```\ncode\n```") == "chat"
    end
  end

  describe "Claude exports (#1073)" do
    @claude_one %{
      "uuid" => "c-1",
      "name" => "Pricing",
      "chat_messages" => [
        %{"sender" => "human", "text" => "Ship Friday?"},
        %{
          "sender" => "assistant",
          "text" => "",
          "content" => [
            %{"type" => "text", "text" => "Yes, if the copy is done."},
            %{"type" => "tool_use", "name" => "x"}
          ]
        }
      ]
    }

    test "one conversation, with the person named" do
      json = Jason.encode!(@claude_one)
      assert Transcript.detect(json) == "claude-export"

      assert {:ok, %{format: "claude-export", lines: lines}} =
               Transcript.parse(json, person: "David")

      assert Enum.map(lines, &{&1.speaker, &1.text}) == [
               {"David", "Ship Friday?"},
               {"Claude", "Yes, if the copy is done."}
             ]
    end

    test "conversations.json: the only one, or one chosen by id or title" do
      other = %{
        "uuid" => "c-2",
        "name" => "Hiring",
        "chat_messages" => [%{"sender" => "human", "text" => "Hire?"}]
      }

      assert {:ok, %{lines: [%{speaker: "User", text: "Ship Friday?"} | _]}} =
               Transcript.parse(Jason.encode!([@claude_one]))

      json = Jason.encode!([@claude_one, other])
      assert Transcript.detect(json, "conversations.json") == "claude-export"

      assert {:error,
              "the export holds 2 conversations; choose one by id or title (\"Pricing\", \"Hiring\")"} =
               Transcript.parse(json)

      assert {:ok, %{lines: [%{text: "Hire?"}]}} = Transcript.parse(json, conversation: "c-2")

      assert {:ok, %{lines: [%{text: "Ship Friday?"} | _]}} =
               Transcript.parse(json, conversation: "Pricing")

      assert {:error, ~s(no conversation in the export has the id or title "Nope")} =
               Transcript.parse(json, conversation: "Nope")
    end

    test "broken or wrong JSON names the format" do
      assert {:error, "the JSON is not valid (at byte " <> rest} =
               Transcript.parse("{\"chat_messages\": [", format: "claude-export")

      assert rest =~ "expected a Claude export"

      assert {:error, "the JSON has no `chat_messages` to read (expected a Claude export)"} =
               Transcript.parse(~s({"a": 1}), format: "claude-export")
    end
  end

  describe "ChatGPT exports (#1073)" do
    defp node(id, parent, children, role, text) do
      message =
        role &&
          %{
            "author" => %{"role" => role},
            "content" => %{"content_type" => "text", "parts" => [text]}
          }

      {id, %{"id" => id, "parent" => parent, "children" => children, "message" => message}}
    end

    defp chatgpt(current) do
      %{
        "title" => "Pricing",
        "id" => "g-1",
        "current_node" => current,
        "mapping" =>
          Map.new([
            node("root", nil, ["sys"], nil, nil),
            node("sys", "root", ["u1"], "system", "You are ChatGPT"),
            node("u1", "sys", ["a1"], "user", "Ship Friday?"),
            node("a1", "u1", ["u2", "u2b"], "assistant", "Yes."),
            node("u2", "a1", ["a2"], "user", "Old edit: ship Monday."),
            node("a2", "u2", [], "assistant", "Monday then."),
            node("u2b", "a1", ["a2b"], "user", "Agreed, Friday."),
            node("a2b", "u2b", [], "assistant", "Friday it is.")
          ])
      }
    end

    test "only the branch the conversation was left on, system messages dropped" do
      json = Jason.encode!(chatgpt("a2b"))
      assert Transcript.detect(json) == "chatgpt-export"

      assert {:ok, %{format: "chatgpt-export", lines: lines}} = Transcript.parse(json)

      assert Enum.map(lines, &{&1.speaker, &1.text}) == [
               {"User", "Ship Friday?"},
               {"ChatGPT", "Yes."},
               {"User", "Agreed, Friday."},
               {"ChatGPT", "Friday it is."}
             ]

      assert {:ok, %{lines: old}} = Transcript.parse(Jason.encode!(chatgpt("a2")))
      assert List.last(old).text == "Monday then."
    end

    test "with no current node, down from the root along the latest child" do
      convo = chatgpt(nil) |> Map.delete("current_node")
      assert {:ok, %{lines: lines}} = Transcript.parse(Jason.encode!([convo]), person: "David")
      assert List.last(lines).text == "Friday it is."
      assert hd(lines).speaker == "David"
    end

    test "chosen from several by title; broken JSON names the format" do
      json = Jason.encode!([chatgpt("a2b"), Map.put(chatgpt("a2"), "title", "Old")])
      assert {:ok, %{lines: lines}} = Transcript.parse(json, conversation: "Old")
      assert List.last(lines).text == "Monday then."

      assert {:error, msg} = Transcript.parse("[{\"mapping\":", format: "chatgpt-export")
      assert msg =~ "expected a ChatGPT export"

      assert {:error, "the JSON has no `mapping` to read (expected a ChatGPT export)"} =
               Transcript.parse("[]", format: "chatgpt-export")
    end
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
