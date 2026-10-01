defmodule Slipdock.AI.Narrator do
  @moduledoc """
  The narrative generator: turns everything the narrative view shows (see
  `Slipdock.Narrative.build/3`) into prose at a chosen level of detail.
  """

  alias Slipdock.AI
  alias Slipdock.AI.Context

  @levels [
    %{
      key: "one_liner",
      label: "One-liner",
      hint: "A single sentence",
      max_tokens: 150,
      instructions:
        "Write exactly one sentence (at most 35 words) that captures the most important thing that happened and the current state. Plain text, no Markdown."
    },
    %{
      key: "three_liner",
      label: "Three-liner",
      hint: "What moved, what's at risk, what's next",
      max_tokens: 300,
      instructions:
        "Write exactly three sentences on three lines: the first on what was accomplished, the second on what is late, blocked or at risk (or that nothing is), the third on what comes next or is due soon. Plain text, no bullets or Markdown."
    },
    %{
      key: "summary",
      label: "Summary",
      hint: "A short paragraph or two",
      max_tokens: 700,
      instructions:
        "Write one or two short paragraphs (120–220 words) summarising the period: the headline, what was completed or moved forward, what slipped or is at risk, and what is coming up. Flowing prose, no bullets, no headings."
    },
    %{
      key: "stakeholder",
      label: "Stakeholder update",
      hint: "Headline, progress, risks, next steps",
      max_tokens: 1000,
      instructions:
        "Write a stakeholder update in Markdown with these bold lead-ins on separate paragraphs: **Headline** (one sentence), **Progress** (what was done or moved forward), **Risks** (what is overdue, blocked or reported at risk, and why if the account says), **Next** (what is due or planned next, and upcoming milestones). Use short bullet lists under Progress and Risks when there are several items. No other headings. Under 300 words."
    },
    %{
      key: "detailed",
      label: "Detailed",
      hint: "Every card and event, group by group",
      max_tokens: 3000,
      instructions:
        "Write a full narrative account in Markdown that covers every card and every event in the account, following the grouping of the account (use a bold lead-in for each group). Tell each card's story in a sentence or a few, in chronological order, weaving in comments and status updates when they are quoted; mention unchanged cards briefly at the end of their group. Finish with a short paragraph on the current state and what is coming up. Prose over bullets."
    }
  ]

  @prompt """
  You write narrative status prose for a project team from a structured account of what happened on a planning board over a period. The account lists the period, a summary, milestones, then each group of cards with the card's current facets and its dated events; quoted comments and status updates appear after their event.

  Write in plain, confident English: past tense for events, present tense for the current state. Cover only what the account contains — never invent events, reasons or dates; when the account gives a reason (in a comment or status update), use it. Refer to cards by title, never by their # id. Give dates as "26 Sep" style unless the year differs from today. Don't preface your answer or explain what you did.
  """

  def levels, do: @levels

  def level(key), do: Enum.find(@levels, &(&1.key == key))

  @doc """
  Generates prose at `level_key` for a narrative source
  (`%{board: board, narrative: narrative, view_name: name}`).
  """
  def generate(source, level_key, opts \\ []) do
    case level(level_key) do
      nil ->
        {:error, "Unknown level."}

      level ->
        account = Context.narrative_text(source)

        messages = [
          %{role: "system", content: @prompt},
          %{
            role: "user",
            content: "Format: #{level.instructions}\n\nThe account:\n\n" <> account
          }
        ]

        AI.complete(
          messages,
          Keyword.merge([max_tokens: level.max_tokens, temperature: 0.5], opts)
        )
    end
  end
end
