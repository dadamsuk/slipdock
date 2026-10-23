defmodule Slipdock.AI.WaitAnswerer do
  @moduledoc """
  Suggests an answer to one of a wait's questions (#1220), from the card's
  context: the card in full (description, checklist, comments), the
  question in front of it and any already answered beside it.

  It only suggests. The answer box is filled in with it, and nothing is
  written until the person sends the answers, so a model that gets it wrong
  costs an edit. Runs on the person's own model (`opts[:user]`, see
  `Slipdock.AI`).
  """

  alias Slipdock.AI
  alias Slipdock.AI.Context
  alias Slipdock.Boards.{Card, Wait}

  @instructions """
  You help a person answer a question that was asked on a card of their
  kanban board, often by an AI agent working the card. Suggest the answer
  they would most likely give, from what the card says: its description,
  checklist and comments. Keep it short and concrete, written as the
  person's answer (not as advice to them). Where the card doesn't settle
  it, give the most sensible default and say in a few words that it is an
  assumption. Never invent facts, names, numbers or dates the card doesn't
  give.

  Answer with a JSON object and nothing else:
  {"answer": "..."}

  answer is plain text, at most 600 characters.
  """

  @doc """
  `{:ok, text}` or `{:error, message}` fit to show, for question `n`
  (counted from 1) of `wait`. `answers` are what the person has typed so
  far, by question number, which the model is shown as context. `card` is
  loaded as the card panel has it; `board` is the board it is on.
  """
  def suggest(%Card{} = card, board, %Wait{} = wait, n, answers \\ %{}, opts \\ []) do
    questions = Wait.questions(wait)

    if n in 1..length(questions)//1 do
      messages = [
        %{role: "system", content: String.trim(@instructions)},
        %{role: "user", content: context(card, board, wait, n, answers)}
      ]

      with {:ok, answer} <-
             AI.complete_json(messages, Keyword.merge([max_tokens: 400, temperature: 0.3], opts)) do
        read(answer)
      end
    else
      {:error, "There is no question #{n} to answer."}
    end
  end

  @doc false
  # The card, then the questions, the one to answer marked.
  def context(%Card{} = card, board, %Wait{} = wait, n, answers \\ %{}) do
    questions =
      wait
      |> Wait.questions()
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {q, i} ->
        mark = if i == n, do: " ← answer this one", else: ""
        typed = to_string(answers[i] || answers[to_string(i)] || "")
        given = if typed == "" or i == n, do: "", else: "\n   (answered: #{typed})"
        "#{i}. #{q}#{mark}#{given}"
      end)

    choices =
      if wait.choices == [],
        do: "",
        else: "\n\nThe asker offered these choices: " <> Enum.join(wait.choices, "; ")

    [
      "## The card",
      Context.card_text(card, board),
      "",
      "## What was asked",
      if(Wait.series?(wait), do: wait.needs <> "\n", else: ""),
      questions <> choices
    ]
    |> Enum.join("\n")
  end

  defp read(%{"answer" => answer}) when is_binary(answer) do
    case String.trim(answer) do
      "" -> {:error, "The model didn't suggest an answer. Try again, or write it yourself."}
      text -> {:ok, String.slice(text, 0, 2000)}
    end
  end

  defp read(_),
    do: {:error, "The model didn't suggest an answer. Try again, or write it yourself."}
end
