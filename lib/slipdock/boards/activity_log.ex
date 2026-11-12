defmodule Slipdock.Boards.ActivityLog do
  @moduledoc """
  The activity log: the lines written as boards, cards and pages change, who
  did it, and reading them back for a board, a card or a page over a span.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards
  alias Slipdock.Boards.Activity
  alias Slipdock.Boards.Comment
  alias Slipdock.Boards.StatusUpdate
  alias Slipdock.Repo

  @doc false
  def actor_user(%{user_id: id}) when is_integer(id), do: Repo.get(User, id)
  def actor_user(_), do: nil

  @doc false
  def actor_name(actor) do
    case actor_user(actor) do
      nil -> if actor[:kind] == "automation", do: "An automation", else: "Someone"
      user -> person_name(user)
    end
  end

  @doc false
  def person_name(%User{} = u), do: User.display_name(u)
  def person_name(_), do: "someone"

  @doc false
  def log_activity(board_id, card_id, kind, message),
    do: log(Repo, board_id, card_id, kind, message)

  @doc "An activity line about a card or a wiki page, whichever it is given."
  def log_activity_for(owner, kind, message), do: Boards.Shared.log_owned(owner, kind, message)

  ## Activity

  @doc "The comments on any of the cards in the date range, oldest first."
  def list_comments_between(card_ids, %Date{} = from, %Date{} = to) when is_list(card_ids) do
    from_dt = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.new!(Date.add(to, 1), ~T[00:00:00], "Etc/UTC")

    from(c in Comment,
      where: c.card_id in ^card_ids and c.inserted_at >= ^from_dt and c.inserted_at < ^to_dt,
      order_by: [asc: c.inserted_at, asc: c.id]
    )
    |> Repo.all()
  end

  @doc "The status updates on any of the cards in the date range, oldest first."
  def list_status_updates_between(card_ids, %Date{} = from, %Date{} = to)
      when is_list(card_ids) do
    from_dt = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.new!(Date.add(to, 1), ~T[00:00:00], "Etc/UTC")

    from(s in StatusUpdate,
      where: s.card_id in ^card_ids and s.inserted_at >= ^from_dt and s.inserted_at < ^to_dt,
      order_by: [asc: s.inserted_at, asc: s.id]
    )
    |> Repo.all()
  end

  @doc "Activity on the given boards between two dates (inclusive), oldest first."
  def list_activities_between(board_ids, %Date{} = from, %Date{} = to) when is_list(board_ids) do
    from_dt = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.new!(Date.add(to, 1), ~T[00:00:00], "Etc/UTC")

    from(a in Activity,
      where: a.board_id in ^board_ids and a.inserted_at >= ^from_dt and a.inserted_at < ^to_dt,
      order_by: [asc: a.inserted_at, asc: a.id]
    )
    |> Repo.all()
  end

  @doc """
  A board's activity, newest first. `card_id` narrows it to the entries about
  that one card.
  """
  def list_activities(board_id, limit \\ 50, card_id \\ nil) do
    from(a in Activity,
      where: a.board_id == ^board_id,
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: ^limit
    )
    |> then(fn q -> if card_id, do: where(q, [a], a.card_id == ^card_id), else: q end)
    |> Repo.all()
  end

  @doc """
  One page of a board's activity for the Activity panel, newest first, with
  each entry's user loaded, and whether there is more: `{entries, more?}`.

    * `limit:` — how many (50 by default);
    * `before:` — an `%Activity{}` from the last page: the entries older
      than it, so the panel can load more as it scrolls;
    * `down_to:` — an `%Activity{}`: everything from the newest down to it
      and no further (`limit` aside), so a panel that has loaded several
      pages can be brought up to date without losing its place.
  """
  def page_activities(board_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1)
    query = from(a in Activity, where: a.board_id == ^board_id)
    newest = order_by(query, [a], desc: a.inserted_at, desc: a.id)

    case opts[:down_to] do
      %Activity{} = oldest ->
        entries =
          newest
          |> where(^down_to(oldest))
          |> preload(:user)
          |> Repo.all()

        {entries, Repo.exists?(where(query, ^older_than(oldest)))}

      _ ->
        entries =
          newest
          |> activities_before(opts[:before])
          |> limit(^(limit + 1))
          |> preload(:user)
          |> Repo.all()

        {Enum.take(entries, limit), length(entries) > limit}
    end
  end

  defp activities_before(q, %Activity{} = a), do: where(q, ^older_than(a))
  defp activities_before(q, _), do: q

  defp older_than(%Activity{inserted_at: at, id: id}),
    do: dynamic([a], a.inserted_at < ^at or (a.inserted_at == ^at and a.id < ^id))

  defp down_to(%Activity{inserted_at: at, id: id}),
    do: dynamic([a], a.inserted_at > ^at or (a.inserted_at == ^at and a.id >= ^id))

  # Who did it is this process's actor (`Slipdock.Actor.current/0`): see
  # `Activity.stamp/2`.
  @doc false
  def log(repo, board_id, card_id, kind, message) do
    repo.insert(
      Activity.stamp(%Activity{
        board_id: board_id,
        card_id: card_id,
        kind: kind,
        message: message
      })
    )
  end

  ## Lookups (#2791): plain reads the web layer makes through this context

  @doc "The activity on the trees of `roots` since `since`, newest first, at most `limit`."
  def activity_since(roots, %DateTime{} = since, limit) do
    from(a in Activity,
      join: b in Board,
      on: b.id == a.board_id,
      where: coalesce(b.root_id, b.id) in ^roots and a.inserted_at >= ^since,
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: ^limit,
      preload: [board: b]
    )
    |> Repo.all()
  end
end
