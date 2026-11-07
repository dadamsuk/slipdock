defmodule Slipdock.Boards.WaitEmail do
  @moduledoc """
  The email a person gets when a card starts waiting on them (#1259): what
  it needs, the questions and choices, a link to the card and, with inbound
  mail on, how to answer by replying (`Slipdock.Inbound.WaitReply` reads the
  reply).

  Sent only to a named person who isn't the one asking, since a wait on
  anyone has nobody in particular to tell and nobody needs telling what
  they asked themselves.
  """

  alias Slipdock.Access
  alias Slipdock.Accounts.User
  alias Slipdock.Automations.{Notifier, Runner}
  alias Slipdock.Boards.{Card, Wait}

  @doc "Tells the person `wait` is on, if there is one to tell."
  @spec opened(struct(), Card.t()) :: :ok
  def opened(%Wait{on_user: %User{} = person} = wait, %Card{} = card) do
    if person.id != wait.opened_by_id and
         person |> Access.card_permission(card) |> Access.can_read?() do
      Slipdock.Deferred.defer(fn ->
        Notifier.deliver([person.email], subject(wait, card), body(wait, card),
          card: card,
          footer: footer(wait)
        )
      end)
    end

    :ok
  end

  def opened(_wait, _card), do: :ok

  @doc """
  Tells the others a wait's route names (#1949, `Slipdock.WaitRoutes`) that
  it was asked, and of whom: they may answer it too. Nobody is told twice,
  nor the person it is on, nor the asker.
  """
  def told(_wait, _card, []), do: :ok

  def told(%Wait{} = wait, %Card{} = card, people) do
    for %User{} = person <- Enum.uniq_by(people, & &1.id),
        person.id != wait.on_user_id and person.id != wait.opened_by_id,
        person |> Access.card_permission(card) |> Access.can_read?() do
      Slipdock.Deferred.defer(fn ->
        Notifier.deliver(
          [person.email],
          "#{who(wait.opened_by)} asked #{Wait.on_name(wait)} (#{wait.question}): “#{card.title}”",
          "You are told about #{wait.question} questions on this board.\n\n" <> body(wait, card),
          card: card
        )
      end)
    end

    :ok
  end

  defp subject(wait, card),
    do: "#{who(wait.opened_by)} is waiting on you: “#{card.title}”"

  @doc "The body: who asks, what, and where to answer."
  def body(wait, card) do
    questions =
      if Wait.series?(wait),
        do: "\n" <> numbered(wait.questions) <> "\n",
        else: ""

    choices =
      if wait.choices != [],
        do: "\nChoices:\n" <> numbered(wait.choices) <> "\n",
        else: ""

    """
    #{who(wait.opened_by)} is waiting on you on card ##{card.id}, “#{card.title}”:

    #{wait.needs}
    #{questions}#{choices}
    Answer on the card:
    #{Runner.base_url()}/boards/#{card.board_id}/cards/#{card.id}
    """
  end

  @doc "How to answer by reply, for the footer."
  def footer(wait) do
    cond do
      Wait.series?(wait) ->
        "Reply to this email to answer: one paragraph per question, in order."

      wait.choices != [] ->
        "Reply to this email to answer: start with a choice's number or its text to pick it, or just write your answer."

      true ->
        "Reply to this email to answer."
    end
  end

  defp numbered(items),
    do: items |> Enum.with_index(1) |> Enum.map_join("\n", fn {t, n} -> "#{n}. #{t}" end)

  defp who(%User{} = user), do: User.display_name(user)
  defp who(_), do: "Somebody"
end
