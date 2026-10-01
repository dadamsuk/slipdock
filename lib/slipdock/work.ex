defmodule Slipdock.Work do
  @moduledoc """
  One person's work: every card assigned to them, across every board and
  every level, grouped by when it is due.

  This is what the My work page shows (`SlipdockWeb.WorkLive.Index`) and what
  the assistant's `assigned_cards` tool answers from, so the two cannot drift
  apart: the same sections, in the same order, with the same idea of what
  "overdue" means.

  Each card comes with the `path` of names above it — the root board, then
  every card the sub-boards hang from — because "Fix the retry" means nothing
  without "QVM V1 Remediation › Broker integrations" in front of it.
  """

  alias Slipdock.{Access, Boards}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Card

  @sections [
    {:overdue, "Overdue", "text-error"},
    {:today, "Due today", "text-primary"},
    {:week, "Next 7 days", nil},
    {:later, "Later", nil},
    {:none, "No due date", nil},
    {:done, "Completed", "text-success"}
  ]

  @doc "The sections, in display order, as `{key, label, tone}`."
  def sections, do: @sections

  @doc """
  Every card assigned to `user` that `viewer` may read, as
  `%{card:, path:, section:}`, due soonest first.

  `viewer` defaults to `user` — one person looking at their own work. When
  someone asks about another person's work it is the asker's permissions that
  decide what comes back, never the assignee's.

  Options: `:today` for the date the sections are reckoned from, `:board_id`
  to keep only the cards in one board's tree.
  """
  def assigned(%User{} = user, viewer \\ nil, opts \\ []) do
    viewer = viewer || user
    today = opts[:today] || Date.utc_today()

    user
    |> Boards.list_assigned_cards()
    |> Enum.filter(&Access.can_read?(Access.card_permission(viewer, &1)))
    |> then(fn cards ->
      case opts[:board_id] do
        nil -> cards
        id -> Enum.filter(cards, &in_tree?(&1, id))
      end
    end)
    |> Enum.map(&%{card: &1, path: path(&1), section: section(&1, today)})
  end

  @doc """
  `assigned/3` gathered into sections: `%{key, label, tone, items}`, empty
  sections left out. Pass `done: true` to include completed cards.
  """
  def grouped(%User{} = user, viewer \\ nil, opts \\ []) do
    user |> assigned(viewer, opts) |> group(opts[:done] == true)
  end

  @doc "Gathers items from `assigned/3` into sections, completed ones last."
  def group(items, done? \\ true) do
    items = if done?, do: items, else: Enum.reject(items, &(&1.section == :done))

    for {key, label, tone} <- @sections,
        in_section = Enum.filter(items, &(&1.section == key)),
        in_section != [],
        do: %{key: key, label: label, tone: tone, items: in_section}
  end

  @doc ~S'"Root › Epic › Story": the root board, then each card the sub-boards hang from.'
  def path(%Card{} = card) do
    case Boards.ancestry(card.board) do
      [] -> [card.board.name]
      [%{board: root} | _] = chain -> [root.name | Enum.map(chain, & &1.card.title)]
    end
  end

  @doc """
  Which section a card belongs in, from its effective due date — the card's
  own, or the one rolled up from its subcards.
  """
  def section(card, today \\ Date.utc_today())
  def section(%Card{completed: true}, _today), do: :done

  def section(%Card{} = card, today) do
    case Card.effective_due(card) do
      nil ->
        :none

      due ->
        case Date.diff(due, today) do
          n when n < 0 -> :overdue
          0 -> :today
          n when n <= 7 -> :week
          _ -> :later
        end
    end
  end

  # A card is in a board's tree when that board is its own or one of its
  # ancestors' — the same test the board page's rollup makes.
  defp in_tree?(%Card{board: board}, board_id) do
    board.id == board_id or Enum.any?(Boards.ancestry(board), &(&1.board.id == board_id))
  end
end
