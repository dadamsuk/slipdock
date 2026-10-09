defmodule Slipdock.MeetingsFixtures do
  @moduledoc "Captures, findings and questions for meeting capture's tests."

  alias Slipdock.{Meetings, Repo, Settings}
  alias Slipdock.Meetings.{Evidence, Finding, Question}

  @doc "Meeting mode on, on a server that has been set up."
  def meetings_on(attrs \\ %{}) do
    # A row of this test's own, marked set up: a fresh row would send every
    # page to the setup wizard.
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})

    {:ok, _} = Settings.update(Map.merge(%{"meetings_enabled" => true}, attrs))
    :ok
  end

  @doc "A short transcript, as the lines ingest would make of it."
  def lines do
    [
      %{speaker: "Priya", start_ms: 0, end_ms: 4_000, text: "Let's settle the pricing page."},
      %{
        speaker: "Sam",
        start_ms: 4_000,
        end_ms: 9_000,
        text: "We go with the annual plan at 20% off."
      },
      %{
        speaker: "Priya",
        start_ms: 9_000,
        end_ms: 14_000,
        text: "Sam, can you update PL-14 by Friday?"
      },
      %{speaker: "Sam", start_ms: 14_000, end_ms: 16_000, text: "Yes, that's mine."}
    ]
  end

  @doc "The same transcript as plain `Name: text` lines."
  def transcript do
    Enum.map_join(lines(), "\n", &"#{&1.speaker}: #{&1.text}")
  end

  @doc "A capture on `board` sent by `owner`, with `lines/0` as its transcript."
  def capture_fixture(board, owner, attrs \\ %{}, opts \\ []) do
    text = Map.get(attrs, :transcript, transcript() <> "\n#{System.unique_integer()}")

    attrs =
      Map.merge(
        %{
          title: "Pricing sync",
          transcript: text,
          transcript_format: "text",
          fingerprint: Meetings.fingerprint(transcript: text),
          started_at: ~U[2026-10-07 10:00:00Z]
        },
        attrs
      )

    {:ok, capture} =
      Meetings.create_capture(board, owner, attrs, Keyword.put_new(opts, :utterances, lines()))

    capture
  end

  @doc "A kept finding on `capture`, quoting `quote` from line `line_id`."
  def finding_fixture(capture, attrs \\ %{}) do
    {quote, attrs} = Map.pop(attrs, :quote)
    {line_id, attrs} = Map.pop(attrs, :line_id, "L2")

    finding =
      %Finding{capture_id: capture.id}
      |> Finding.changeset(Map.merge(%{kind: "decision", title: "Annual plan at 20% off"}, attrs))
      |> Repo.insert!()

    if quote do
      Repo.insert!(%Evidence{finding_id: finding.id, line_id: line_id, quote: quote})
    end

    finding
  end

  @doc "An open blocking question on `capture`."
  def question_fixture(capture, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Question{
          capture_id: capture.id,
          kind: "who_is_meant",
          prompt: "Who is “Sam”?",
          options: [%{"value" => "nobody", "label" => "Nobody yet"}]
        },
        attrs
      )
    )
  end
end
