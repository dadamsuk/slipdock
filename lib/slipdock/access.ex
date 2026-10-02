defmodule Slipdock.Access do
  @moduledoc """
  Authorization. Boards belong to a user. Other users, and groups of users,
  can be granted read or write access to a board, to a single card, to a
  saved view of a board, or to a single wiki page.

    * Board access covers every card on it (and the sub-boards inside them),
      and every page of its wiki.
    * A card grant gives access to just that card (and its sub-board), and can
      raise a board reader to a writer on that one card.
    * A view grant lets the holder open the board through that saved view
      only: they see the cards the view's filters select, read-only unless
      the view grant is "write".
    * A page grant gives access to just that page, so "share this doc" never
      has to be answered with "move it to another board".

  Permission levels, from most to least: `:owner`, `:write`, `:read`, `:view`
  (board reachable only through granted views), `:none`.
  """
  import Ecto.Query, warn: false
  alias Slipdock.Repo
  alias Slipdock.Access.Grant
  alias Slipdock.Accounts
  alias Slipdock.Accounts.{Group, User}
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, SavedView}
  alias Slipdock.Wiki.Page

  @pubsub Slipdock.PubSub

  @type level :: :owner | :write | :read | :view | :none

  @rank %{none: 0, view: 1, read: 2, write: 3, owner: 4}

  ## Permissions --------------------------------------------------------------

  @doc "The user's permission on a board (including sub-boards, via their parent card)."
  @spec board_permission(User.t() | nil, Board.t()) :: level
  def board_permission(nil, _board), do: :none

  def board_permission(%User{} = user, %Board{} = board) do
    cond do
      board.owner_id == user.id ->
        :owner

      is_nil(board.owner_id) ->
        # Legacy boards created before accounts existed: open until claimed.
        :owner

      true ->
        direct = grant_level(user, board_id: board.id)

        inherited =
          case board.parent_card_id do
            nil -> :none
            card_id -> card_permission(user, Repo.get!(Card, card_id))
          end

        via_views = if has_view_grant?(user, board), do: :view, else: :none
        Enum.max_by([direct, inherited, via_views], &@rank[&1])
    end
  end

  @doc "The user's permission on a card: the board's, raised by any direct card grant."
  @spec card_permission(User.t() | nil, Card.t()) :: level
  def card_permission(nil, _card), do: :none

  def card_permission(%User{} = user, %Card{} = card) do
    board = Repo.get!(Board, card.board_id)
    from_board = board_permission(user, board)
    # A view-only board permission doesn't reach cards by itself; the caller
    # decides which cards a view exposes.
    from_board = if from_board == :view, do: :none, else: from_board
    direct = grant_level(user, card_id: card.id)
    Enum.max_by([from_board, direct], &@rank[&1])
  end

  @doc """
  The user's permission on a wiki page: the board's, raised by any direct
  page grant.

  A board permission of `:view` — someone who reaches the board only through
  a granted saved view — does not reach pages at all. A shared view is a
  window onto cards; it must not leak the documents beside them.
  """
  @spec page_permission(User.t() | nil, Page.t()) :: level
  def page_permission(nil, _page), do: :none

  def page_permission(%User{} = user, %Page{} = page) do
    board = Repo.get!(Board, page.board_id)
    from_board = board_permission(user, board)
    from_board = if from_board == :view, do: :none, else: from_board
    direct = grant_level(user, page_id: page.id)
    Enum.max_by([from_board, direct], &@rank[&1])
  end

  @doc "The user's permission on a saved view: board write/owner, or a direct view grant."
  @spec view_permission(User.t() | nil, SavedView.t()) :: level
  def view_permission(nil, _), do: :none

  def view_permission(%User{} = user, %SavedView{} = view) do
    board = Repo.get!(Board, view.board_id)
    from_board = board_permission(user, board)
    from_board = if from_board == :view, do: :none, else: from_board
    direct = grant_level(user, saved_view_id: view.id)
    Enum.max_by([from_board, direct], &@rank[&1])
  end

  @doc "Saved views on `board` this user may open (all of them with real board access)."
  def accessible_views(%User{} = user, %Board{} = board) do
    views = Boards.list_saved_views(board.id)

    case board_permission(user, board) do
      :view -> Enum.filter(views, &(grant_level(user, saved_view_id: &1.id) != :none))
      :none -> []
      _ -> views
    end
  end

  def can_read?(level), do: @rank[level] >= @rank[:read]
  def can_write?(level), do: @rank[level] >= @rank[:write]
  def owner?(level), do: level == :owner

  ## API token scope ----------------------------------------------------------

  @doc """
  Narrows a permission level by the scope of the API token the request came
  with. A scope only ever *narrows*: it can never grant access the user does
  not already have, so a read-only token on a board you own still only reads.

  `token` is nil for a browser session, which has no scope and is unchanged.
  `board_id` is the board the thing being reached belongs to, and may be nil
  for checks that are not about one board.

  Returns `{level, reason}` — `reason` is `:scope` when the token is what
  lowered the level, so a refusal can say so instead of pretending the thing
  does not exist.
  """
  @spec narrow(level, map | nil, integer | nil) :: {level, :scope | nil}
  def narrow(level, nil, _board_id), do: {level, nil}

  def narrow(level, token, board_id) do
    cond do
      not board_in_scope?(token, board_id) -> {:none, :scope}
      Map.get(token, :scope) == "read" and @rank[level] > @rank[:read] -> {:read, :scope}
      true -> {level, nil}
    end
  end

  # An empty board list means the whole account. A non-empty one lists root
  # boards: a token scoped to a board reaches the sub-boards inside its cards,
  # because that is where the work on that board actually lives.
  defp board_in_scope?(token, board_id) do
    case Map.get(token, :scope_boards) || [] do
      [] -> true
      _ids when is_nil(board_id) -> false
      ids -> board_id in ids or root_of(board_id) in ids
    end
  end

  defp root_of(board_id) do
    case Repo.one(from(b in Board, where: b.id == ^board_id, select: b.root_id)) do
      nil -> board_id
      root_id -> root_id
    end
  end

  defp grant_level(%User{} = user, [{field, id}]) do
    group_ids = Accounts.group_ids_for(user)

    levels =
      from(g in Grant,
        where: field(g, ^field) == ^id,
        where: g.user_id == ^user.id or g.group_id in ^group_ids,
        select: g.level
      )
      |> Repo.all()

    cond do
      "write" in levels -> :write
      "read" in levels -> :read
      true -> :none
    end
  end

  defp has_view_grant?(%User{} = user, %Board{} = board) do
    group_ids = Accounts.group_ids_for(user)

    Repo.exists?(
      from(g in Grant,
        join: v in SavedView,
        on: v.id == g.saved_view_id,
        where: v.board_id == ^board.id,
        where: g.user_id == ^user.id or g.group_id in ^group_ids
      )
    )
  end

  ## Listing what a user can see -----------------------------------------------

  @doc """
  Root boards the user can open: owned, granted (directly or via a group),
  reachable through a granted view, plus unclaimed legacy boards.

  Archived boards are left out unless `:archived` says otherwise — `false`
  (the default) for the boards in play, `true` for the archived ones alone,
  `:all` for both. Archiving is only about what gets listed: it takes nobody's
  access away, so a link to an archived board still opens it.

  Each board's `position` is where this user has put it on their own index
  (nil until they have placed it); pass `activity: true` to also fill
  `last_activity_at` with the last time anything happened anywhere in its
  tree. `Slipdock.Boards.sort_boards/2` reads both.
  """
  def list_boards(user, opts \\ [])

  def list_boards(%User{} = user, opts) do
    group_ids = Accounts.group_ids_for(user)

    granted_board_ids =
      from(g in Grant,
        left_join: v in SavedView,
        on: v.id == g.saved_view_id,
        where: g.user_id == ^user.id or g.group_id in ^group_ids,
        where: not is_nil(g.board_id) or not is_nil(g.saved_view_id),
        select: coalesce(g.board_id, v.board_id)
      )
      |> Repo.all()

    from(b in Board,
      where: is_nil(b.parent_card_id),
      where: b.owner_id == ^user.id or is_nil(b.owner_id) or b.id in ^granted_board_ids,
      order_by: [asc: b.inserted_at]
    )
    |> scope_to_token(opts[:token])
    |> Boards.filter_archived(Keyword.get(opts, :archived, false))
    |> Repo.all()
    |> Repo.preload(
      owner: [],
      cards: from(c in Card, where: is_nil(c.archived_at), select: [:id, :completed, :board_id]),
      columns: from(c in Boards.Column, select: [:id, :board_id])
    )
    |> with_positions(user)
    |> with_activity(opts[:activity])
  end

  def list_boards(_, _opts), do: []

  # A board-scoped API token must not be able to *list* what it cannot reach.
  # Blocking the fetch is not enough on its own: an index that still names
  # every board leaks the shape of the account to a token that was confined
  # to one corner of it.
  defp scope_to_token(query, nil), do: query

  defp scope_to_token(query, token) do
    case Map.get(token, :scope_boards) || [] do
      [] -> query
      ids -> from(b in query, where: b.id in ^ids)
    end
  end

  defp with_positions(boards, user) do
    placed = Boards.board_order(user)
    Enum.map(boards, &%{&1 | position: placed[&1.id]})
  end

  defp with_activity(boards, true) do
    last = Boards.last_activity_at(boards)
    Enum.map(boards, &%{&1 | last_activity_at: last[&1.id]})
  end

  defp with_activity(boards, _), do: boards

  @doc """
  The ids of every board the user can read, sub-boards included. Used where
  something board-scoped has to be filtered for one reader, such as the
  alerts in the header bar.
  """
  def readable_board_ids(%User{} = user) do
    # Archived boards are still readable — archiving only takes them off the
    # lists people browse.
    root_ids = user |> list_boards(archived: :all) |> Enum.map(& &1.id)

    card_board_ids =
      user
      |> shared_cards()
      |> Enum.map(& &1.board_id)

    from(b in Board,
      where: b.id in ^root_ids or b.root_id in ^root_ids or b.id in ^card_board_ids,
      select: b.id
    )
    |> Repo.all()
  end

  def readable_board_ids(_), do: []

  @doc """
  The people this user may see: who can be assigned a card, mentioned, offered
  in a share box, or named in a prompt sent to a model.

  Which it is depends on `user_directory` (see `Slipdock.Settings`):

    * `:instance` — everybody with an account here. Right for one person, and
      right for a team who all work together; it is what this did before any of
      this existed, and it is the default so that no existing install changes.
    * `:shared_only` — only people reachable through something you can both
      get at: a board, card, page or saved view you share, or a group you are
      both in. Right when strangers share a server, which is the whole premise
      of hosting it for other people.

  `Accounts.list_users/0` is the unscoped version and is now the **admin's**
  view. Reaching for it in a page, a prompt or an API response is how every
  customer ends up seeing every other customer's email address.

  Ordered by email, like `Accounts.list_users/0`, so call sites can swap.
  """
  @spec visible_users(User.t() | nil) :: [User.t()]
  def visible_users(nil), do: []

  def visible_users(%User{} = user) do
    case Slipdock.Settings.user_directory() do
      :shared_only ->
        ids = visible_user_ids(user)
        Repo.all(from(u in User, where: u.id in ^ids, order_by: [asc: u.email]))

      _ ->
        Accounts.list_users()
    end
  end

  @doc """
  The ids behind `visible_users/1`, for the places that only need to ask
  "can this one person see that one person?" without loading everybody.
  """
  @spec visible_user_ids(User.t() | nil) :: [integer()]
  def visible_user_ids(nil), do: []

  def visible_user_ids(%User{} = user) do
    board_ids = readable_board_ids(user)
    group_ids = shared_group_ids(user, board_ids)

    [
      # Yourself, always — a picker you cannot assign yourself in is broken.
      [user.id],
      # Whoever owns a board you can reach.
      Repo.all(from(b in Board, where: b.id in ^board_ids, select: b.owner_id)),
      # Whoever else has been granted something on a board you can reach —
      # directly, or on one of its cards, pages or saved views.
      Repo.all(
        from(g in Grant,
          left_join: c in Card,
          on: c.id == g.card_id,
          left_join: p in Page,
          on: p.id == g.page_id,
          left_join: v in SavedView,
          on: v.id == g.saved_view_id,
          where:
            g.board_id in ^board_ids or c.board_id in ^board_ids or p.board_id in ^board_ids or
              v.board_id in ^board_ids,
          select: g.user_id
        )
      ),
      # Everybody in a group that reaches you, and whoever owns it.
      Repo.all(from(m in "group_members", where: m.group_id in ^group_ids, select: m.user_id)),
      Repo.all(from(gr in Group, where: gr.id in ^group_ids, select: gr.owner_id))
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Groups that put you and somebody else in the same room: the ones you are in,
  # and the ones holding a grant on something you can reach.
  defp shared_group_ids(%User{} = user, board_ids) do
    own = Accounts.group_ids_for(user)
    owned = Repo.all(from(g in Group, where: g.owner_id == ^user.id, select: g.id))

    granted =
      Repo.all(
        from(g in Grant,
          left_join: c in Card,
          on: c.id == g.card_id,
          left_join: p in Page,
          on: p.id == g.page_id,
          left_join: v in SavedView,
          on: v.id == g.saved_view_id,
          where:
            not is_nil(g.group_id) and
              (g.board_id in ^board_ids or c.board_id in ^board_ids or
                 p.board_id in ^board_ids or v.board_id in ^board_ids),
          select: g.group_id
        )
      )

    Enum.uniq(own ++ owned ++ granted)
  end

  @doc """
  Everything a user may read, as ids: `%{board_ids: [...], card_ids: [...]}`.

  This is the filter semantic search runs against, and it is deliberately
  tighter than `readable_board_ids/1`. Two differences matter:

    * A board reachable only through a granted saved view (`:view`) is left
      out entirely. Such a reader is meant to see the cards that view
      selects and nothing else, and a search index has no view to apply —
      so it gets nothing from that board rather than all of it.
    * A card shared on its own does **not** bring its board with it.
      `readable_board_ids/1` returns the whole board for the alerts bar,
      which is fine there; here it would hand over every other card on it.
      Instead the card comes back in `card_ids`, along with the boards of
      any sub-board tree hanging beneath it, which that grant does reach.

  Callers filter with `board_id in board_ids or card_id in card_ids`.
  """
  @spec readable_scope(User.t() | nil) :: %{board_ids: [integer], card_ids: [integer]}
  def readable_scope(%User{} = user) do
    root_ids =
      user
      |> list_boards(archived: :all)
      |> Enum.filter(&can_read?(board_permission(user, &1)))
      |> Enum.map(& &1.id)

    board_ids =
      from(b in Board, where: b.id in ^root_ids or b.root_id in ^root_ids, select: b.id)
      |> Repo.all()

    # Cards shared on their own, minus any that sit on a board already in reach.
    card_ids =
      user
      |> shared_cards()
      |> Enum.reject(&(&1.board_id in board_ids))
      |> Enum.map(& &1.id)

    %{board_ids: board_ids ++ boards_beneath(card_ids), card_ids: card_ids}
  end

  def readable_scope(_), do: %{board_ids: [], card_ids: []}

  # Every board in the sub-board trees hanging off these cards. A sub-board's
  # `root_id` is the tree's top, not the shared card, so this walks down a
  # level at a time; the nesting is shallow and the loop ends when it runs out.
  defp boards_beneath([]), do: []

  defp boards_beneath(card_ids) do
    board_ids =
      from(b in Board, where: b.parent_card_id in ^card_ids, select: b.id) |> Repo.all()

    case board_ids do
      [] ->
        []

      ids ->
        next = from(c in Card, where: c.board_id in ^ids, select: c.id) |> Repo.all()
        ids ++ boards_beneath(next)
    end
  end

  @doc "Cards shared directly with the user (or their groups), with their boards."
  def shared_cards(%User{} = user) do
    group_ids = Accounts.group_ids_for(user)

    card_ids =
      from(g in Grant,
        where: not is_nil(g.card_id),
        where: g.user_id == ^user.id or g.group_id in ^group_ids,
        select: g.card_id
      )
      |> Repo.all()

    from(c in Card, where: c.id in ^card_ids and is_nil(c.archived_at), order_by: [asc: c.title])
    |> Repo.all()
    |> Repo.preload([:board, :column, :tags])
  end

  @doc "Claims boards that predate accounts for `user` (the first person to sign in)."
  def claim_unowned_boards(%User{} = user) do
    {n, _} =
      from(b in Board, where: is_nil(b.owner_id) and is_nil(b.parent_card_id))
      |> Repo.update_all(set: [owner_id: user.id])

    # Sub-boards follow their root.
    from(b in Board, where: is_nil(b.owner_id) and not is_nil(b.root_id))
    |> Repo.update_all(set: [owner_id: user.id])

    n
  end

  ## Grants -------------------------------------------------------------------

  @doc "Grants on a resource, with subjects preloaded."
  def list_grants(resource) do
    from(g in Grant, where: ^resource_clause(resource), order_by: [asc: g.inserted_at])
    |> Repo.all()
    |> Repo.preload([:user, :group, :granted_by])
  end

  @doc """
  Grants `level` on `resource` to `subject` (a `%User{}`, a `%Group{}`, or an
  email address, which creates the user if needed). Re-granting updates the level.
  """
  def grant(resource, subject, level, %User{} = granted_by) when level in ["read", "write"] do
    with {:ok, subject} <- resolve_subject(subject) do
      subject_clause = subject_clause(subject)
      attrs = Map.merge(resource_attrs(resource), subject_attrs(subject))

      result =
        case Repo.one(from(g in Grant, where: ^resource_clause(resource), where: ^subject_clause)) do
          nil ->
            %Grant{granted_by_id: granted_by.id}
            |> Grant.changeset(Map.put(attrs, :level, level))
            |> Repo.insert()

          grant ->
            grant |> Grant.changeset(%{level: level}) |> Repo.update()
        end

      with {:ok, grant} <- result do
        broadcast_resource(resource)
        {:ok, Repo.preload(grant, [:user, :group, :granted_by])}
      end
    end
  end

  def revoke(%Grant{} = grant) do
    resource =
      case Grant.resource_type(grant) do
        :board -> Repo.get!(Board, grant.board_id)
        :card -> Repo.get!(Card, grant.card_id)
        :page -> Repo.get!(Page, grant.page_id)
        :view -> Repo.get!(SavedView, grant.saved_view_id)
      end

    Repo.delete(grant) |> tap(fn _ -> broadcast_resource(resource) end)
  end

  def get_grant!(id), do: Repo.get!(Grant, id)

  @doc """
  Pages shared with the user on their own (or with one of their groups),
  regardless of whether they can see the board the page sits on.
  """
  def shared_pages(%User{} = user) do
    group_ids = Accounts.group_ids_for(user)

    page_ids =
      from(g in Grant,
        where: not is_nil(g.page_id),
        where: g.user_id == ^user.id or g.group_id in ^group_ids,
        select: g.page_id
      )
      |> Repo.all()

    from(p in Page, where: p.id in ^page_ids and is_nil(p.archived_at), order_by: [asc: p.title])
    |> Repo.all()
    |> Repo.preload(:board)
  end

  def shared_pages(_), do: []

  defp resolve_subject(%User{} = u), do: {:ok, u}
  defp resolve_subject(%Group{} = g), do: {:ok, g}

  defp resolve_subject(email) when is_binary(email) do
    case Accounts.get_or_create_user_by_email(email) do
      {:ok, user} -> {:ok, user}
      {:error, _} -> {:error, "That doesn't look like an email address."}
    end
  end

  defp subject_attrs(%User{id: id}), do: %{user_id: id}
  defp subject_attrs(%Group{id: id}), do: %{group_id: id}
  defp subject_clause(%User{id: id}), do: dynamic([g], g.user_id == ^id)
  defp subject_clause(%Group{id: id}), do: dynamic([g], g.group_id == ^id)

  defp resource_attrs(%Board{id: id}), do: %{board_id: id}
  defp resource_attrs(%Card{id: id}), do: %{card_id: id}
  defp resource_attrs(%SavedView{id: id}), do: %{saved_view_id: id}
  defp resource_attrs(%Page{id: id}), do: %{page_id: id}
  defp resource_clause(%Board{id: id}), do: dynamic([g], g.board_id == ^id)
  defp resource_clause(%Card{id: id}), do: dynamic([g], g.card_id == ^id)
  defp resource_clause(%SavedView{id: id}), do: dynamic([g], g.saved_view_id == ^id)
  defp resource_clause(%Page{id: id}), do: dynamic([g], g.page_id == ^id)

  defp broadcast_resource(%Board{id: id}), do: broadcast(id)
  defp broadcast_resource(%Card{board_id: id}), do: broadcast(id)
  defp broadcast_resource(%SavedView{board_id: id}), do: broadcast(id)
  defp broadcast_resource(%Page{board_id: id}), do: broadcast(id)

  defp broadcast(board_id) do
    Phoenix.PubSub.broadcast(@pubsub, "board:#{board_id}", {:board_changed, board_id})
    Phoenix.PubSub.broadcast(@pubsub, "boards", {:boards_changed})
  end
end
