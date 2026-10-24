defmodule Slipdock.Inbound.WaitReply do
  @moduledoc """
  Reading a reply as the answer to a card's open wait (#1259), as
  `slipdock answer` would give it:

    * **One question, with choices**: a first line that is just a choice's
      number, or exactly one choice's text (case aside), picks it; any lines
      after it are the answer in words. Anything else is a free-text answer.
    * **One question**: the whole reply is the answer.
    * **Several questions**: one paragraph each, in order. Fewer paragraphs
      leave the rest unanswered; more than there are questions can't be
      matched.

  `Slipdock.Inbound.Replies` posts a reply that can't be matched as a plain
  comment and leaves the wait open.
  """

  alias Slipdock.Boards.Wait

  @doc """
  The attributes `Slipdock.Boards.answer_wait/3` takes for `text` as the
  answer to `wait`, or `{:error, why}` when it can't be matched.
  """
  @spec attrs(%Wait{}, String.t()) :: {:ok, map()} | {:error, String.t()}
  def attrs(%Wait{} = wait, text) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:error, "the reply was empty"}

      Wait.series?(wait) ->
        series(wait, text)

      true ->
        single(wait, text)
    end
  end

  defp series(wait, text) do
    paragraphs = text |> String.split(~r/\n\s*\n/) |> Enum.map(&String.trim/1)
    count = length(wait.questions)

    if length(paragraphs) > count,
      do:
        {:error,
         "it has #{length(paragraphs)} paragraphs for #{count} questions: answer each in one paragraph, in order"},
      else: {:ok, %{answers: paragraphs}}
  end

  defp single(%Wait{choices: []}, text), do: {:ok, %{answer: text}}

  defp single(%Wait{choices: choices}, text) do
    [first | rest] = String.split(text, "\n", parts: 2) ++ [""]
    rest = rest |> List.first() |> to_string() |> String.trim()

    case choice(choices, String.trim(first)) do
      nil -> {:ok, %{answer: text}}
      n when rest == "" -> {:ok, %{choice: n}}
      n -> {:ok, %{choice: n, answer: rest}}
    end
  end

  defp choice(choices, line) do
    count = length(choices)

    case Integer.parse(String.trim_trailing(line, ".")) do
      {n, ""} when n in 1..count//1 ->
        n

      _ ->
        wanted = String.downcase(line)

        case Enum.find_index(choices, &(String.downcase(&1) == wanted)) do
          nil -> nil
          i -> i + 1
        end
    end
  end
end
