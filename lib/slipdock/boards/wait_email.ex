defmodule Slipdock.Boards.WaitEmail do
  @moduledoc """
  The email a person gets when a card starts waiting on them (#1259): what
  it needs, the questions and choices, a link to the card and, with inbound
  mail on, how to answer by replying (`Slipdock.Inbound.WaitReply` reads the
  reply).

  Sent only to a named person, since a wait on anyone has nobody in
  particular to tell, and not to someone who asked it themselves in person
  (`Slipdock.Boards.WaitAlert.tell?/2`; an agent asking under their token
  is a question for them, #2095). Each person turns it off in account
  settings (`User.waiting_emails`, on by default). The same moment raises
  their alert (`Slipdock.Boards.WaitAlert`).

  It goes through `Slipdock.Notify`, which also shows it as a desktop toast
  in any Slipdock tab the person has open with toasts on (#2101); with their
  email off, only the toast.
  """

  alias Slipdock.{Access, Notify}
  alias Slipdock.Accounts.User
  alias Slipdock.Automations.Runner
  alias Slipdock.Boards.{Card, Wait}

  @doc "Tells the person `wait` is on, if there is one to tell."
  @spec opened(struct(), Card.t()) :: :ok
  def opened(%Wait{on_user: %User{} = person} = wait, %Card{} = card) do
    Slipdock.Boards.WaitAlert.opened(wait, card)

    if Slipdock.Boards.WaitAlert.tell?(wait, card) do
      Notify.person(person, card,
        kind: "wait",
        by: by(wait, person),
        subject: subject(wait, card),
        body: body(wait, card),
        email: [footer: footer(wait)],
        send_email: person.waiting_emails,
        title: "#{who(wait.opened_by)} is waiting on you",
        text: "#{card.title}: #{wait.needs}"
      )
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
      Notify.person(person, card,
        kind: "wait_routed",
        by: wait.opened_by_id,
        subject:
          "#{who(wait.opened_by)} asked #{Wait.on_name(wait)} (#{wait.question}): “#{card.title}”",
        body:
          "You are told about #{wait.question} questions on this board.\n\n" <> body(wait, card),
        title: "#{who(wait.opened_by)} asked #{Wait.on_name(wait)} (#{wait.question})",
        text: "#{card.title}: #{wait.needs}"
      )
    end

    :ok
  end

  # An agent asking under the person's own token is a question for them, so
  # their page mustn't drop its toast as their own doing (#2095).
  defp by(%Wait{kind: kind, opened_by_id: id}, %User{id: id}) when kind != "human", do: nil
  defp by(%Wait{opened_by_id: id}, _person), do: id

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
        do: "\nChoices:\n" <> choices(wait) <> "\n",
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

  @doc """
  Tells the person a wait was on that its proposal stood (#2096,
  `Slipdock.WaitDefaults`): nobody answered within `after_text`, so the
  card went on with the default. A wait on anyone tells the tree's owner.
  """
  def defaulted(%Wait{} = wait, %Card{} = card, after_text) do
    wait = Slipdock.Repo.preload(wait, [:on_user])

    case wait.on_user || tree_owner(card) do
      %User{} = person ->
        if person |> Access.card_permission(card) |> Access.can_read?() do
          choice = Wait.choice_text(wait, wait.choice)

          Notify.person(person, card,
            kind: "wait_defaulted",
            subject: "The proposal stood on “#{card.title}”: #{choice}",
            body: """
            Nobody answered “#{wait.needs}” on card ##{card.id}, “#{card.title}”, within #{after_text}, so its proposal stands: #{choice}.

            The card has gone on with it. If it shouldn't, say so on the card:
            #{Runner.base_url()}/boards/#{card.board_id}/cards/#{card.id}
            """,
            title: "The proposal stood: #{choice}",
            text: "#{card.title}: #{wait.needs}"
          )
        end

      _ ->
        :ok
    end

    :ok
  end

  defp tree_owner(card) do
    root = Slipdock.Boards.root_of_board(card.board_id)

    case Slipdock.Repo.get(Slipdock.Boards.Board, root) do
      %{owner_id: id} when is_integer(id) -> Slipdock.Repo.get(User, id)
      _ -> nil
    end
  end

  # The choices, numbered, the proposed one marked (#2096).
  defp choices(wait) do
    wait.choices
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {t, n} ->
      if n == wait.default_choice, do: "#{n}. #{t} (proposed)", else: "#{n}. #{t}"
    end)
  end

  defp numbered(items),
    do: items |> Enum.with_index(1) |> Enum.map_join("\n", fn {t, n} -> "#{n}. #{t}" end)

  defp who(%User{} = user), do: User.display_name(user)
  defp who(_), do: "Somebody"
end
