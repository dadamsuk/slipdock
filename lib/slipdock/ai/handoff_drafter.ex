defmodule Slipdock.AI.HandoffDrafter do
  @moduledoc """
  Drafts a card's handoff (W-1804, #1099): the one next step and a short note
  in the shape `Slipdock.Boards.Handoff.body_template/0` gives, read from what
  has happened on the card lately — its activity, comments, checklist and
  status updates — with the card in full behind it and the handoff before
  this one, if any.

  It only drafts. The person's form is filled in with it, and nothing is
  written until they save, so a model that gets it wrong costs an edit, not a
  record. Runs on the person's own model (`opts[:user]`, see `Slipdock.AI`).
  """

  alias Slipdock.{AI, Boards}
  alias Slipdock.AI.Context
  alias Slipdock.Boards.{Board, Card, Handoff}

  # How far back "lately" reaches, and how much of it the model is shown.
  @recent_days 14
  @activity_limit 40

  # What the model is told to write. A board can put its own in place of
  # this (#1212, `Board.handoff_prompt/1`); the answer's shape below is
  # always added, so a board's own words can't break the form it fills.
  @instructions """
  You write the handoff note for a card on a kanban board: what the next
  person to pick the card up (a colleague, or an AI agent) reads first, so
  they need not read every comment. Write it from what has happened on the
  card recently; the rest of the card is background.

  - next_step: the one concrete next thing to do, as an instruction. Not a
    summary.
  - body: plain text lines in this shape, leaving out a line you have
    nothing true to say for:
    State:     what is done and what is half-done
    Gotchas:   what went wrong, or what not to try again
    Open:      questions waiting on someone, and who
    Pointers:  branches, commits, files, pages (W-…) or cards (#…) mentioned
    Keep it under 120 words. Say only what the card says; never invent
    progress, names, commits or dates.
  """

  @answer """
  Answer with a JSON object and nothing else:
  {"next_step": "...", "body": "..."}

  next_step is at most 200 characters; body is plain text, and may be "".
  """

  @doc "The built-in instructions, which a board's own replace (#1212)."
  def default_instructions, do: String.trim(@instructions)

  @doc false
  # The whole system prompt for `board`: its instructions, then the answer.
  def prompt(board),
    do: (Board.handoff_prompt(board) || default_instructions()) <> "\n\n" <> @answer

  @doc """
  `{:ok, %{next_step: text, body: text | nil}}`, or `{:error, message}` fit to
  show. `card` is loaded as the card panel has it (comments, checklist,
  status updates); `board` is the board it is on.
  """
  def draft(%Card{} = card, board, opts \\ []) do
    messages = [
      %{role: "system", content: prompt(board)},
      %{role: "user", content: context(card, board, opts)}
    ]

    with {:ok, answer} <-
           AI.complete_json(messages, Keyword.merge([max_tokens: 700, temperature: 0.3], opts)) do
      read(answer)
    end
  end

  @doc false
  # What the model is told: recent first, then the card, then the last note.
  def context(%Card{} = card, board, opts \\ []) do
    now = opts[:now] || DateTime.utc_now()
    since = DateTime.add(now, -@recent_days * 86_400)

    recent =
      board.id
      |> Boards.list_activities(@activity_limit, card.id)
      |> Enum.filter(&(DateTime.compare(&1.inserted_at, since) != :lt))

    previous = Boards.current_handoff(card)

    [
      "Today is #{Date.to_iso8601(DateTime.to_date(now))}.",
      "",
      "## What happened on the card in the last #{@recent_days} days (newest first)",
      if(recent == [],
        do: "(nothing logged; go by the latest comments below)",
        else: Enum.map_join(recent, "\n", &"- #{fmt(&1.inserted_at)} #{&1.message}")
      ),
      "",
      "## The card",
      Context.card_text(card, board),
      "",
      "## The handoff before this one",
      previous_text(previous)
    ]
    |> Enum.join("\n")
  end

  # A cleared one is no handoff (`Boards.current_handoff/1` says nil); the
  # activity above says it was cleared.
  defp previous_text(%Handoff{} = h),
    do: String.trim_trailing("Next step: #{h.next_step}\n#{h.body || ""}")

  defp previous_text(_), do: "(none)"

  defp fmt(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp fmt(_), do: ""

  # The model's answer, held to what a handoff takes: a next step, which it
  # must give, and a body that may be empty.
  defp read(answer) do
    next = answer |> Map.get("next_step") |> text() |> String.slice(0, 280)
    body = answer |> Map.get("body") |> text() |> String.slice(0, 8000)

    if next == "",
      do: {:error, "The model didn't suggest a next step. Try again, or write it yourself."},
      else: {:ok, %{next_step: next, body: if(body == "", do: nil, else: body)}}
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  # Some models answer the body as lines in a list.
  defp text(lines) when is_list(lines),
    do: lines |> Enum.map(&to_string/1) |> Enum.join("\n") |> String.trim()

  defp text(_), do: ""
end
