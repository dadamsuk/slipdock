defmodule Slipdock.Health.Detectors.UnansweredWait do
  @moduledoc """
  A wait open for over `days` (default 2). The fix tells the person it is on
  again — an email to them, or with nobody named to the board's owner — once.
  Still open after another `days`, it is flagged.
  """
  @behaviour Slipdock.Health.Detector

  import Ecto.Query

  alias Slipdock.{Access, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Automations.Notifier
  alias Slipdock.Boards.{Board, Card, Wait, WaitEmail}
  alias Slipdock.Health.{Context, Incident}

  @impl true
  def key, do: "unanswered_wait"
  @impl true
  def label, do: "Question unanswered"
  @impl true
  def defaults, do: %{"days" => 2}

  @impl true
  def detect(%Context{} = ctx, %{"days" => days}) do
    waits =
      from(w in Wait,
        join: c in Card,
        on: c.id == w.card_id,
        where: c.board_id in ^ctx.board_ids and is_nil(w.closed_at) and is_nil(c.archived_at),
        order_by: w.id,
        preload: [:card]
      )
      |> Repo.all()

    reminded = reminded(ctx.board.id, Enum.map(waits, & &1.id))

    for wait <- waits,
        age = div(Context.minutes_since(ctx, wait.inserted_at), 60 * 24),
        age >= days,
        # The first period reminds, once; after another, it is flagged.
        phase = if(age >= 2 * days, do: 2, else: 1),
        phase == 2 or not MapSet.member?(reminded, wait.id) do
      %{
        subject: %{"card" => wait.card_id, "wait" => wait.id},
        card_id: wait.card_id,
        state: {wait.id, phase},
        summary:
          "##{wait.card_id}'s question has waited #{age} days for #{Wait.on_name(wait)}: " <>
            "“#{String.slice(wait.needs, 0, 200)}”.",
        data: %{"wait" => wait.id, "phase" => phase}
      }
    end
  end

  # Waits the monitor has reminded someone about already.
  defp reminded(root_id, wait_ids) do
    from(i in Incident,
      where: i.board_id == ^root_id and i.detector == "unanswered_wait" and i.status == "fixed",
      select: i.subject
    )
    |> Repo.all()
    |> Enum.map(& &1["wait"])
    |> Enum.filter(&(&1 in wait_ids))
    |> MapSet.new()
  end

  @impl true
  def resolve(%{data: %{"phase" => 2}}, _attempt), do: :no_fix

  def resolve(%{data: %{"wait" => id}}, _attempt) do
    with %Wait{closed_at: nil} = wait <-
           Repo.get(Wait, id) |> Repo.preload([:on_user, :opened_by]),
         %Card{} = card <- Repo.get(Card, wait.card_id),
         %User{} = person <- wait.on_user || owner(card),
         true <- person |> Access.card_permission(card) |> Access.can_read?(),
         sent when not is_tuple(sent) or elem(sent, 0) != :error <-
           Notifier.deliver(
             [person.email],
             "Still waiting on you: “#{card.title}”",
             WaitEmail.body(wait, card),
             card: card,
             footer: WaitEmail.footer(wait)
           ) do
      {:fixed, "reminded #{User.display_name(person)} by email"}
    else
      _ -> :no_fix
    end
  end

  defp owner(card) do
    case Repo.get(Board, Slipdock.Boards.root_of_board(card.board_id)) do
      %Board{owner_id: id} when is_integer(id) -> Repo.get(User, id)
      _ -> nil
    end
  end
end
