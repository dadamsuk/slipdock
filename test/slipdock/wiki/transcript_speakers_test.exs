defmodule Slipdock.Wiki.TranscriptSpeakersTest do
  @moduledoc "Putting a name on a voice in a page's transcript (#1157)."
  use ExUnit.Case, async: true

  alias Slipdock.Wiki.{TranscriptSpeakers, Viewer}

  @body """
  # Standup

  Speaker 1: this line is prose, not a transcript.

  ```vtt
  WEBVTT

  1
  00:00:01.000 --> 00:00:04.000
  <v Speaker 1>Morning, everyone.

  00:00:04.000 --> 00:00:06.000
  <v.loud Speaker 2>Hi.

  00:00:06.000 --> 00:00:09.000
  Speaker 1: Shall we start?
  Speaker 1: is not a name on a second line.

  00:00:09.000 --> 00:00:10.000
  <v Speaker 10>Yes.
  ```

  Speaker 1 again, after the transcript.
  """

  defp speakers(body) do
    [_, vtt] = Regex.run(~r/```vtt\n(.*?)```/s, body)
    {:ok, transcript} = Viewer.transcript(vtt)
    transcript.speakers
  end

  test "renames a voice in every cue it speaks, tag or prefix, and nothing else" do
    assert {:ok, body, 2} = TranscriptSpeakers.rename(@body, "Speaker 1", "Priya Shah")

    assert body =~ "<v Priya Shah>Morning, everyone."
    assert body =~ "<v Priya Shah>Shall we start?"
    assert body =~ "Speaker 1: is not a name on a second line."
    assert body =~ "Speaker 1: this line is prose, not a transcript."
    assert body =~ "Speaker 1 again, after the transcript."
    assert body =~ "<v Speaker 10>Yes."
    assert speakers(body) == ["Priya Shah", "Speaker 2", "Speaker 10"]
  end

  test "keeps a voice tag's class" do
    assert {:ok, body, 1} = TranscriptSpeakers.rename(@body, "Speaker 2", "Sam")
    assert body =~ "<v.loud Sam>Hi."
    assert speakers(body) == ["Speaker 1", "Sam", "Speaker 10"]
  end

  test "naming a voice after a speaker already there makes them one" do
    assert {:ok, body, 1} = TranscriptSpeakers.rename(@body, " Speaker 10 ", "Speaker 1")
    assert speakers(body) == ["Speaker 1", "Speaker 2"]
  end

  test "renames in every transcript on the page, ~~~ fences too" do
    body = "~~~vtt\nWEBVTT\n\n00:00.000 --> 00:01.000\n<v A>One.\n~~~\n\n" <> @body
    assert {:ok, renamed, 1} = TranscriptSpeakers.rename(body, "A", "Ann")
    assert renamed =~ "<v Ann>One."
    assert {:ok, _, 4} = TranscriptSpeakers.rename(body <> body, "Speaker 1", "P")
  end

  test "a longer fence isn't closed by a shorter one" do
    body = "````vtt\nWEBVTT\n```\n00:00.000 --> 00:01.000\n<v A>One.\n````\n"
    assert {:ok, renamed, 1} = TranscriptSpeakers.rename(body, "A", "Ann")
    assert renamed =~ "<v Ann>One."
  end

  test "refuses a name that would not read back as one" do
    assert TranscriptSpeakers.rename(@body, "Speaker 1", "  ") == {:error, :blank}
    assert TranscriptSpeakers.rename(@body, "Speaker 1", "Ann <b>") == {:error, :invalid}
    assert TranscriptSpeakers.rename(@body, "Speaker 1", "Ann: Shah") == {:error, :invalid}
    assert TranscriptSpeakers.rename(@body, "Speaker 1", "Ann\nShah") == {:error, :invalid}

    assert TranscriptSpeakers.rename(@body, "Speaker 1", String.duplicate("a", 61)) ==
             {:error, :invalid}

    assert {:ok, _, 2} = TranscriptSpeakers.rename(@body, "Speaker 1", String.duplicate("a", 60))
  end

  test "refuses the name it already has, and a voice nobody speaks with" do
    assert TranscriptSpeakers.rename(@body, "Speaker 1", " Speaker 1 ") == {:error, :unchanged}
    assert TranscriptSpeakers.rename(@body, "Nobody", "Ann") == {:error, :not_found}

    assert TranscriptSpeakers.rename("No transcript here.", "Speaker 1", "Ann") ==
             {:error, :not_found}
  end

  test "blocks are the text of each vtt block, and nothing outside them" do
    body = """
    Intro

    ```vtt
    WEBVTT
    one
    ```

    ```elixir
    not this
    ```

    ~~~vtt
    two
    ~~~
    """

    assert TranscriptSpeakers.blocks(body) == ["WEBVTT\none", "two"]
    assert TranscriptSpeakers.blocks("No transcript here.") == []
    assert TranscriptSpeakers.blocks("```vtt\nunclosed") == ["unclosed"]
    assert TranscriptSpeakers.blocks(nil) == []
  end
end
