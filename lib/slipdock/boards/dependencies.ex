defmodule Slipdock.Boards.Dependencies do
  @moduledoc """
  Dependencies between cards: a card blocked by another, and unblocking its
  dependents when that card is done.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Card
  alias Slipdock.Repo

  ## Dependencies

  @doc """
  Records that `blocked` can't proceed until `blocker` is done. The cards must
  be distinct and the link must not create a cycle. They may be on different
  boards — a subcard waiting on another epic's subcard, say; who may link
  what is the caller's to check (write on the blocked card's board, read on
  the blocker's), as for links.
  """
  def add_dependency(%Card{} = blocked, %Card{} = blocker) do
    cond do
      blocked.id == blocker.id ->
        {:error, "A card can't depend on itself."}

      dependency_exists?(blocked.id, blocker.id) ->
        {:error, "That dependency already exists."}

      reachable?(blocked.id, blocker.id) ->
        {:error,
         "That would create a circular dependency: “#{blocker.title}” already depends on “#{blocked.title}”."}

      true ->
        Repo.insert_all("card_dependencies", [%{blocked_id: blocked.id, blocker_id: blocker.id}])

        log_dependency(blocked, blocker, &"made #{&1} depend on #{&2}")

        {:ok, Boards.Cards.get_card!(blocked.id)}
    end
  end

  @doc "Removes the dependency between two cards, whichever direction it runs."
  def remove_dependency(%Card{} = a, %Card{} = b) do
    {n, _} =
      Repo.delete_all(
        from(d in "card_dependencies",
          where:
            (d.blocked_id == ^a.id and d.blocker_id == ^b.id) or
              (d.blocked_id == ^b.id and d.blocker_id == ^a.id)
        )
      )

    if n > 0 do
      log_dependency(a, b, &"removed the dependency between #{&1} and #{&2}")
    end

    {:ok, Boards.Cards.get_card!(a.id)}
  end

  # The cards `blocker` was the last open blocker of, now that it is done or
  # put away. Each runs the `card_unblocked` rules, and one flagged `blocked`
  # loses the flag, with a comment saying why: whoever made it wait (a runner
  # handing a card back, most often) flagged it for this dependency, and a
  # flag left on keeps it out of the ready list — runners, `list_top` and the
  # loop all skip it — after the reason has gone.
  @doc false
  # Also run by `Slipdock.Verified.saved/3` when a card goes pending on a
  # board that ships by push: it counts as finished for its dependents (#1661).
  def unblock_dependents(%Card{} = blocker, opts) do
    from(c in Card,
      join: d in "card_dependencies",
      on: d.blocked_id == c.id,
      where: d.blocker_id == ^blocker.id and not c.completed and is_nil(c.archived_at),
      preload: [blocked_by: ^Boards.dependency_query()]
    )
    |> Repo.all()
    |> Enum.reject(&Card.blocked?/1)
    |> Enum.each(&unblock(&1, blocker, opts))
  end

  defp unblock(%Card{} = card, blocker, opts) do
    if Enum.member?(card.flags, "blocked") do
      flags = List.delete(card.flags, "blocked")

      with {:ok, _} <-
             Boards.Cards.update_card(
               card,
               %{"flags" => flags},
               Keyword.take(opts, [:by, :actor])
             ) do
        Boards.Comments.add_comment(
          card,
          "Unblocked: #{unblocked_by(card, blocker)}, and nothing else it depends on is " <>
            "open, so the blocked flag came off. Flag it again if it is still waiting on something."
        )
      end
    end

    Boards.CardEvents.automate(%{
      type: "card_unblocked",
      card: Repo.get!(Card, card.id),
      blocker: blocker
    })
  end

  # Named only by number from another board, as in the log (see log_dependency/3).
  defp unblocked_by(card, blocker) do
    name =
      if blocker.board_id == card.board_id,
        do: "##{blocker.id} “#{blocker.title}”",
        else: "card ##{blocker.id} on another board"

    state =
      cond do
        blocker.completed -> "done"
        blocker.archived_at -> "archived"
        true -> "awaiting verification with its work already shipped"
      end

    "#{name} is #{state}"
  end

  # A dependency shows on both cards, so when they are on different boards
  # each board's log records it and each board's open pages hear of it.
  # `message` gets the two cards as each board's log should name them: its
  # own card by title, the other board's only by number, since somebody
  # reading this board's log need not be able to read that one.
  defp log_dependency(%Card{} = a, %Card{} = b, message) do
    if b.board_id == a.board_id do
      Boards.ActivityLog.log(
        Repo,
        a.board_id,
        a.id,
        "card",
        message.("“#{a.title}”", "“#{b.title}”")
      )
    else
      Boards.ActivityLog.log(
        Repo,
        a.board_id,
        a.id,
        "card",
        message.("“#{a.title}”", "card ##{b.id} on another board")
      )

      Boards.ActivityLog.log(
        Repo,
        b.board_id,
        b.id,
        "card",
        message.("card ##{a.id} on another board", "“#{b.title}”")
      )

      Boards.PubSub.broadcast(b.board_id)
    end

    Boards.PubSub.broadcast(a.board_id)
  end

  defp dependency_exists?(blocked_id, blocker_id) do
    Repo.exists?(
      from(d in "card_dependencies",
        where: d.blocked_id == ^blocked_id and d.blocker_id == ^blocker_id
      )
    )
  end

  # Is `target` downstream of `from`, following "blocks" edges? Adding
  # from -> blocked-by -> target would then close a cycle. Walked in the
  # database: UNION (not UNION ALL) drops ids already seen, so an existing
  # cycle still ends.
  defp reachable?(from_id, target_id) do
    initial =
      from(d in "card_dependencies", where: d.blocker_id == ^from_id, select: %{id: d.blocked_id})

    step =
      from(d in "card_dependencies",
        join: r in "downstream",
        on: d.blocker_id == r.id,
        select: %{id: d.blocked_id}
      )

    "downstream"
    |> recursive_ctes(true)
    |> with_cte("downstream", as: ^union(initial, ^step))
    |> where([r], r.id == ^target_id)
    |> Repo.exists?()
  end
end
