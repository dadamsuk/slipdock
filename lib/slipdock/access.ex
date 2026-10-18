defmodule Slipdock.Access do
  @moduledoc """
  Authorization. Boards belong to a user. Other users, and groups of users,
  can be granted read, comment or write access to a board, to a single card,
  to a saved view of a board, or to a single wiki page.

    * Board access covers every card on it (and the sub-boards inside them),
      and every page of its wiki.
    * A card grant gives access to just that card (and its sub-board), and can
      raise a board reader to a writer on that one card.
    * A view grant lets the holder open the board through that saved view
      only: they see the cards the view's filters select, read-only unless
      the view grant is "write".
    * A page grant gives access to just that page, so "share this doc" never
      has to be answered with "move it to another board".
    * A folder grant gives access to everything whose *home* is in that
      folder's subtree: its pages, files and drawings, and the folders
      beneath it, to any depth (#815). Something only *also filed* there
      (a placement) is not shared by it — filing a page into a shared folder
      must never quietly share the page.

  Permission levels, from most to least: `:owner`, `:write`, `:comment`,
  `:read`, `:view` (board reachable only through granted views), `:none`.

  `:comment` (#863) is a reader who may also join the discussion — comment,
  report a status, leave a vote's comment, take back their own comment — but
  changes nothing about the card or page itself: not its title, dates,
  assignees, flags, list, checklist or anything else a writer edits.
  """
  import Ecto.Query, warn: false
  alias Slipdock.Repo
  alias Slipdock.Access.Grant
  alias Slipdock.Accounts
  alias Slipdock.Accounts.{Group, User}
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, SavedView}
  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Wiki.{Folder, Page, WikiFile}

  @pubsub Slipdock.PubSub

  @type level :: :owner | :write | :comment | :read | :view | :none

  @rank %{none: 0, view: 1, read: 2, comment: 3, write: 4, owner: 5}

  # What a grant row may carry, lowest first.
  @grant_levels Grant.levels()

  ## Permissions --------------------------------------------------------------

  @doc "The user's permission on a board (including sub-boards, via their parent card)."
  @spec board_permission(User.t() | nil, Board.t()) :: level
  def board_permission(nil, _board), do: :none

  def board_permission(%User{} = user, %Board{} = board) do
    cond do
      board.owner_id == user.id ->
        :owner

      true ->
        direct = grant_level(user, board_id: board.id)

        inherited =
          case board.parent_card_id do
            nil -> :none
            card_id -> card_permission(user, Repo.get!(Card, card_id))
          end

        via_views = if has_view_grant?(user, board), do: :view, else: :none
        # An open support session reads like a read grant and no more — never
        # write, never owner. Helping somebody is looking, not editing.
        via_support =
          if Accounts.support_access?(user, Board.root_owner_id(board)), do: :read, else: :none

        Enum.max_by([direct, inherited, via_views, via_support], &@rank[&1])
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
  Whether `user` reaches `card` through a saved view granted to them: their
  access to its board is view-only, the card is live, and the filters of one
  of the views they hold select it — the same test the board applies to what
  it shows them (`SlipdockWeb.BoardLive.Items.card_access/5`). Anyone with
  more than view access is answered by `card_permission/2` instead, so this
  is `false` for them.
  """
  @spec view_shows_card?(User.t() | nil, Card.t()) :: boolean
  def view_shows_card?(nil, _card), do: false
  def view_shows_card?(_user, %Card{archived_at: archived}) when not is_nil(archived), do: false

  def view_shows_card?(%User{} = user, %Card{} = card) do
    board = Repo.get!(Board, card.board_id)

    if board_permission(user, board) == :view do
      card = Boards.get_card!(card.id)

      user
      |> accessible_views(board)
      |> Enum.any?(&Swimlanes.matches?(card, Config.from_map(&1.config)))
    else
      false
    end
  end

  @doc """
  The cards in `cards` the user can read, in their order — `card_permission/2`
  for a list, without its queries per card: each distinct board is checked
  once, and the direct card grants come back in one query.
  """
  @spec filter_readable_cards(User.t() | nil, [Card.t()]) :: [Card.t()]
  def filter_readable_cards(nil, _cards), do: []
  def filter_readable_cards(_user, []), do: []

  def filter_readable_cards(%User{} = user, cards) do
    from_board =
      cards
      |> Enum.map(& &1.board_id)
      |> Enum.uniq()
      |> then(&Repo.all(from(b in Board, where: b.id in ^&1)))
      |> Map.new(fn board ->
        level = board_permission(user, board)
        {board.id, if(level == :view, do: :none, else: level)}
      end)

    direct = grant_levels(user, :card_id, Enum.map(cards, & &1.id))

    Enum.filter(cards, fn card ->
      level =
        Enum.max_by(
          [Map.get(from_board, card.board_id, :none), Map.get(direct, card.id, :none)],
          &@rank[&1]
        )

      can_read?(level)
    end)
  end

  @doc """
  Hides the cards at the far end of dependencies that `user` cannot read.

  A dependency can join cards on different boards, and somebody who can see
  one board need not see the other. Each `blocked_by` / `blocks` stub they
  can't read keeps its id and its state — so `Card.blocked?/1` still answers
  truly, and the dependency can still be removed from the side they can
  write — but loses its title and board, and is marked `hidden: true`.

  Takes a card, a list of cards, or a board with its columns' cards loaded.
  `token` is the API token the request came with, if any: a card on a board
  outside its scope is hidden too.
  """
  def hide_unreadable_dependencies(user, subject, token \\ nil)

  def hide_unreadable_dependencies(user, %Board{columns: columns} = board, token)
      when is_list(columns) do
    cards = Enum.flat_map(columns, &List.wrap(cards_of(&1)))
    by_id = user |> hide_unreadable_dependencies(cards, token) |> Map.new(&{&1.id, &1})

    columns =
      Enum.map(columns, fn
        %{cards: cs} = col when is_list(cs) -> %{col | cards: Enum.map(cs, &by_id[&1.id])}
        col -> col
      end)

    %{board | columns: columns}
  end

  def hide_unreadable_dependencies(_user, %Board{} = board, _token), do: board

  def hide_unreadable_dependencies(user, %Card{} = card, token),
    do: user |> hide_unreadable_dependencies([card], token) |> hd()

  def hide_unreadable_dependencies(user, cards, token) when is_list(cards) do
    stubs =
      cards
      |> Enum.flat_map(
        &(loaded_list(Map.get(&1, :blocked_by)) ++ loaded_list(Map.get(&1, :blocks)))
      )
      |> Enum.uniq_by(& &1.id)

    readable =
      user
      |> filter_readable_cards(stubs)
      |> Enum.filter(&(narrow(:read, token, &1.board_id) |> elem(0) |> can_read?()))
      |> MapSet.new(& &1.id)

    hide = fn
      deps when is_list(deps) ->
        Enum.map(deps, fn d -> if d.id in readable, do: d, else: hidden_stub(d) end)

      other ->
        other
    end

    Enum.map(cards, fn
      %Card{} = c -> %{c | blocked_by: hide.(c.blocked_by), blocks: hide.(c.blocks)}
      other -> other
    end)
  end

  defp cards_of(%{cards: cards}) when is_list(cards), do: cards
  defp cards_of(_), do: []

  defp loaded_list(list) when is_list(list), do: list
  defp loaded_list(_), do: []

  defp hidden_stub(%Card{} = d) do
    %Card{
      id: d.id,
      title: "A card you can't see",
      completed: d.completed,
      archived_at: d.archived_at,
      hidden: true
    }
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
    Enum.max_by(
      [wiki_board_level(user, page.board_id), share_permission(user, page)],
      &@rank[&1]
    )
  end

  @doc """
  The user's permission on a wiki folder: the board's, raised by a grant on
  it or on any folder above it (#815). As for pages, `:view` on the board
  reaches no folder.
  """
  @spec folder_permission(User.t() | nil, Folder.t()) :: level
  def folder_permission(nil, _folder), do: :none

  def folder_permission(%User{} = user, %Folder{} = folder) do
    Enum.max_by(
      [wiki_board_level(user, folder.board_id), share_permission(user, folder)],
      &@rank[&1]
    )
  end

  @doc """
  The user's permission on a wiki file (an image, a PDF, a drawing): the
  board's, raised by a grant on a folder its home is in.
  """
  @spec file_permission(User.t() | nil, WikiFile.t()) :: level
  def file_permission(nil, _file), do: :none

  def file_permission(%User{} = user, %WikiFile{} = file) do
    Enum.max_by(
      [wiki_board_level(user, file.board_id), share_permission(user, file)],
      &@rank[&1]
    )
  end

  @doc """
  What sharing alone gives the user on a page, folder or file: its own page
  grant and the grants on the folders of its home ancestry, never the board.
  `Slipdock.Wiki.Sharing` reads it to tell a writer on the board from
  somebody a thing was shared with, whose writes are narrower.
  """
  @spec share_permission(User.t() | nil, Page.t() | Folder.t() | WikiFile.t()) :: level
  def share_permission(nil, _item), do: :none

  def share_permission(%User{} = user, %Page{} = page) do
    Enum.max_by(
      [grant_level(user, page_id: page.id), folder_grant_level(user, page.folder_id)],
      &@rank[&1]
    )
  end

  def share_permission(%User{} = user, %Folder{id: id}), do: folder_grant_level(user, id)

  def share_permission(%User{} = user, %WikiFile{folder_id: id}),
    do: folder_grant_level(user, id)

  # A board's permission as far as its wiki is concerned: a reader through a
  # saved view reaches no page of it.
  defp wiki_board_level(user, board_id) do
    case board_permission(user, Repo.get!(Board, board_id)) do
      :view -> :none
      level -> level
    end
  end

  @doc """
  The highest level a grant on folder `folder_id`, or on any folder above it
  in its home ancestry, gives `user` — directly or through a group. One
  query whatever the depth: the ancestry is a recursive CTE, joined to the
  grants. `nil` (the wiki's top) is in no folder, so nothing.
  """
  @spec folder_grant_level(User.t(), integer | nil) :: :write | :comment | :read | :none
  def folder_grant_level(_user, nil), do: :none

  def folder_grant_level(%User{id: user_id}, folder_id) when is_integer(folder_id) do
    from(g in Grant,
      join: a in "folder_ancestry",
      on: g.folder_id == a.id,
      where:
        g.user_id == ^user_id or
          g.group_id in subquery(
            from(m in "group_members", where: m.user_id == ^user_id, select: m.group_id)
          ),
      select: g.level
    )
    |> recursive_ctes(true)
    |> with_cte("folder_ancestry", as: ^ancestry_cte(folder_id))
    |> Repo.all()
    |> best_level()
  end

  # A folder and every folder above it, by `parent_id` (its home, never a
  # placement). Folders are a tree, so the walk ends at the top.
  defp ancestry_cte(folder_id) do
    start =
      from(f in Folder, where: f.id == ^folder_id, select: %{id: f.id, parent_id: f.parent_id})

    up =
      from(f in Folder,
        join: a in "folder_ancestry",
        on: f.id == a.parent_id,
        select: %{id: f.id, parent_id: f.parent_id}
      )

    union_all(start, ^up)
  end

  # The highest of some grant rows' levels, `:none` for no rows.
  defp best_level(levels),
    do: levels |> Enum.map(&grant_level_atom/1) |> Enum.reduce(:none, &higher/2)

  @doc "A grant row's level as a permission level: `\"comment\"` → `:comment`."
  @spec grant_level_atom(String.t()) :: level
  def grant_level_atom(level) when level in @grant_levels, do: String.to_existing_atom(level)
  def grant_level_atom(_), do: :none

  @doc "The higher of two permission levels (`nil` counts as `:none`)."
  @spec higher(level | nil, level | nil) :: level
  def higher(a, b) do
    a = a || :none
    b = b || :none
    if @rank[a] >= @rank[b], do: a, else: b
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
  def can_comment?(level), do: @rank[level] >= @rank[:comment]
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

    best_level(levels)
  end

  # grant_level/2 for many ids of one kind at once: %{id => level}, the
  # highest grant on each winning.
  defp grant_levels(%User{} = user, field, ids) do
    group_ids = Accounts.group_ids_for(user)

    from(g in Grant,
      where: field(g, ^field) in ^ids,
      where: g.user_id == ^user.id or g.group_id in ^group_ids,
      select: {field(g, ^field), g.level}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {id, level}, acc ->
      Map.update(acc, id, grant_level_atom(level), &higher(&1, grant_level_atom(level)))
    end)
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

  ## Finding a board by what somebody calls it -------------------------------

  @doc """
  Finds a board by id, code or name among the boards `user` can read.

  Looking across the whole server instead would get two things wrong: a name
  somebody else's board also has could shadow the caller's own, and a
  "forbidden" for a board they cannot see would tell them it exists. So
  anything the caller cannot read is simply not there.
  """
  @spec find_board(User.t() | nil, String.t() | integer) ::
          {:ok, Board.t()} | {:error, :not_found}
  def find_board(%User{} = user, ref) do
    scope = from(b in Board, where: coalesce(b.root_id, b.id) in subquery(reachable_roots(user)))

    ref
    |> Boards.matching_boards(scope)
    |> Enum.find(&can_read?(board_permission(user, &1)))
    |> case do
      nil -> {:error, :not_found}
      board -> {:ok, board}
    end
  end

  def find_board(_, _ref), do: {:error, :not_found}

  # The roots of every tree the user could read anything in: what they own,
  # what has been shared with them (a board, a card, a view), and the trees of
  # anybody whose open support session they hold. A superset — `find_board/2`
  # still asks `board_permission/2` of each match — but one confined to the
  # user's own corner of the server, so a name every account shares does not
  # drag in thousands of rows.
  defp reachable_roots(%User{} = user) do
    group_ids = Accounts.group_ids_for(user)
    now = DateTime.utc_now()

    shared =
      from(g in Grant,
        left_join: v in SavedView,
        on: v.id == g.saved_view_id,
        left_join: c in Card,
        on: c.id == g.card_id,
        where: g.user_id == ^user.id or g.group_id in ^group_ids,
        select: coalesce(g.board_id, coalesce(v.board_id, c.board_id))
      )

    supported =
      from(s in Accounts.SupportSession,
        join: a in User,
        on: a.id == s.admin_id and a.admin == true and is_nil(a.disabled_at),
        where: s.admin_id == ^user.id and is_nil(s.ended_at) and s.expires_at > ^now,
        select: s.subject_id
      )

    from(b in Board,
      where:
        b.owner_id == ^user.id or b.id in subquery(shared) or
          (is_nil(b.parent_card_id) and b.owner_id in subquery(supported)),
      select: coalesce(b.root_id, b.id)
    )
  end

  @doc """
  The root boards whose changes `user`'s cross-board pages should hear about:
  every tree they reach (`reachable_roots/1`) and the trees of pages shared
  with them on their own. Archived boards are in it — they still show on the
  index's archived list. See `Slipdock.Boards.subscribe_all/1`.
  """
  @spec notice_root_ids(User.t()) :: [integer()]
  def notice_root_ids(%User{} = user) do
    group_ids = Accounts.group_ids_for(user)

    pages =
      from(g in Grant,
        join: p in Page,
        on: p.id == g.page_id,
        join: b in Board,
        on: b.id == p.board_id,
        where: g.user_id == ^user.id or g.group_id in ^group_ids,
        select: coalesce(b.root_id, b.id)
      )

    folders =
      from(g in Grant,
        join: f in Folder,
        on: f.id == g.folder_id,
        join: b in Board,
        on: b.id == f.board_id,
        where: g.user_id == ^user.id or g.group_id in ^group_ids,
        select: coalesce(b.root_id, b.id)
      )

    user |> reachable_roots() |> union(^pages) |> union(^folders) |> Repo.all()
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
      where: b.owner_id == ^user.id or b.id in ^granted_board_ids,
      order_by: [asc: b.inserted_at, asc: b.id]
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
  Where an admin's support sessions let them in: one entry per session they
  hold, with the person's own boards (top level, not archived, by name).

  `list_boards/2` leaves these out on purpose — they are somebody else's, for
  a few hours — so without this the access is granted and nowhere to be found.
  """
  @spec supported_boards(User.t() | nil) :: [
          %{session: Accounts.SupportSession.t(), subject: User.t(), boards: [Board.t()]}
        ]
  def supported_boards(%User{} = admin) do
    admin
    |> Accounts.held_support_sessions()
    |> Enum.map(&%{session: &1, subject: &1.subject, boards: support_boards(&1.subject_id)})
  end

  def supported_boards(_), do: []

  defp support_boards(owner_id) do
    from(b in Board,
      where: b.owner_id == ^owner_id and is_nil(b.parent_card_id),
      order_by: [asc: b.name, asc: b.id]
    )
    |> Boards.filter_archived(false)
    |> Repo.all()
  end

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
  The people visible to work that has no signed-in reader: an automation rule
  firing, the scheduler, a prompt assembled in the background.

  The board's owner stands in. They are whose server this work is being done
  on, and scoping to them is what stops a rule — or a model prompt built from
  one — naming people the board's owner has never shared anything with.

  A board with no owner names nobody.
  """
  @spec visible_users_for(Board.t()) :: [User.t()]
  def visible_users_for(%Board{owner_id: nil}), do: []

  def visible_users_for(%Board{owner_id: owner_id}) do
    case Repo.get(User, owner_id) do
      %User{} = owner -> visible_users(owner)
      nil -> []
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
          left_join: f in Folder,
          on: f.id == g.folder_id,
          left_join: v in SavedView,
          on: v.id == g.saved_view_id,
          where:
            g.board_id in ^board_ids or c.board_id in ^board_ids or p.board_id in ^board_ids or
              f.board_id in ^board_ids or v.board_id in ^board_ids,
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
          left_join: f in Folder,
          on: f.id == g.folder_id,
          left_join: v in SavedView,
          on: v.id == g.saved_view_id,
          where:
            not is_nil(g.group_id) and
              (g.board_id in ^board_ids or c.board_id in ^board_ids or
                 p.board_id in ^board_ids or f.board_id in ^board_ids or
                 v.board_id in ^board_ids),
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
  def grant(resource, subject, level, %User{} = granted_by) when level in @grant_levels do
    with {:ok, subject} <- resolve_subject(subject, granted_by, resource) do
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
        # They are not listening on this tree yet.
        Boards.notify_users_boards_changed(subject_user_ids(subject))
        notify_shares(resource, subject_user_ids(subject))
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
        :folder -> Repo.get!(Folder, grant.folder_id)
        :view -> Repo.get!(SavedView, grant.saved_view_id)
        :tool -> Repo.get!(Slipdock.Tools.Tool, grant.tool_id)
      end

    Repo.delete(grant)
    |> tap(fn _ ->
      # What the share let somebody file in their own folders goes too (#818).
      Slipdock.Wiki.SharedPlacements.cleanup(grant)
      broadcast_resource(resource)
      Boards.notify_users_boards_changed(subject_user_ids(grant))
      notify_shares(resource, subject_user_ids(grant))
    end)
  end

  def get_grant!(id), do: Repo.get!(Grant, id)

  @doc """
  The grants that make `board` reachable for `user` — their own, and the ones
  that arrive through a group they are in. Saved-view grants count: a view
  grant is how somebody reaches a board they were never given outright.

  This is what the Shared page shows somebody about a board that is not
  theirs: who handed it over, and on what terms.
  """
  def incoming_grants(%User{} = user, %Board{} = board) do
    group_ids = Accounts.group_ids_for(user)

    from(g in Grant,
      left_join: v in SavedView,
      on: v.id == g.saved_view_id,
      where: g.board_id == ^board.id or v.board_id == ^board.id,
      where: g.user_id == ^user.id or g.group_id in ^group_ids,
      order_by: [asc: g.inserted_at, asc: g.id]
    )
    |> Repo.all()
    |> Repo.preload([:user, :group, :granted_by, :saved_view])
  end

  def incoming_grants(_user, _board), do: []

  @doc """
  Gives up `user`'s own access to a board somebody else shared with them: the
  grants naming them personally, on the board and on its saved views, go.

  What it cannot take away it leaves: a grant held by a group is that group's,
  not this person's, and support access belongs to the session. So the answer
  is the permission that is *left* — `:none` when the board has gone off their
  list for good, anything else when something still reaches them and they need
  telling why. Owners get `{:error, :owner}`: a board of your own is deleted or
  archived, never discarded.
  """
  @spec discard_board(User.t(), Board.t()) :: {:ok, level} | {:error, :owner}
  def discard_board(%User{} = user, %Board{} = board) do
    if board.owner_id == user.id do
      {:error, :owner}
    else
      user
      |> incoming_grants(board)
      |> Enum.filter(&(&1.user_id == user.id))
      |> Enum.each(&Repo.delete!/1)

      broadcast(board.id)
      {:ok, board_permission(user, board)}
    end
  end

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

    folder_ids = shared_folder_subtree_ids(user)

    from(p in Page,
      where: p.id in ^page_ids or p.folder_id in ^folder_ids,
      where: is_nil(p.archived_at),
      order_by: [asc: p.title]
    )
    |> Repo.all()
    |> Repo.preload(:board)
  end

  def shared_pages(_), do: []

  @doc """
  Folders shared with the user directly (or with one of their groups): the
  tops of the shares, each with its board. What is beneath them comes with
  them (`shared_folder_subtree_ids/1`).
  """
  def shared_folders(%User{} = user) do
    group_ids = Accounts.group_ids_for(user)

    from(f in Folder,
      join: g in Grant,
      on: g.folder_id == f.id,
      where: g.user_id == ^user.id or g.group_id in ^group_ids,
      distinct: true,
      order_by: [asc: f.name, asc: f.id]
    )
    |> Repo.all()
    |> Repo.preload(:board)
  end

  def shared_folders(_), do: []

  @doc """
  The ids of every folder shared with the user: the ones granted and every
  folder at home beneath them, to any depth. One query.
  """
  @spec shared_folder_subtree_ids(User.t() | nil) :: [integer]
  def shared_folder_subtree_ids(%User{id: user_id}) do
    start =
      from(f in Folder,
        join: g in Grant,
        on: g.folder_id == f.id,
        where:
          g.user_id == ^user_id or
            g.group_id in subquery(
              from(m in "group_members", where: m.user_id == ^user_id, select: m.group_id)
            ),
        select: %{id: f.id}
      )

    down =
      from(f in Folder, join: s in "shared_subtree", on: f.parent_id == s.id, select: %{id: f.id})

    from(s in "shared_subtree", distinct: true, select: s.id)
    |> recursive_ctes(true)
    |> with_cte("shared_subtree", as: ^union(start, ^down))
    |> Repo.all()
  end

  def shared_folder_subtree_ids(_), do: []

  @doc "Wiki files at home in a folder shared with the user, with their boards."
  def shared_files(%User{} = user) do
    folder_ids = shared_folder_subtree_ids(user)

    from(f in WikiFile,
      where: f.folder_id in ^folder_ids and is_nil(f.archived_at),
      order_by: [asc: f.name]
    )
    |> Repo.all()
    |> Repo.preload(:board)
  end

  def shared_files(_), do: []

  @doc "Which of these folders carry a grant of their own: their tree marks them."
  @spec shared_folder_ids([integer]) :: MapSet.t()
  def shared_folder_ids([]), do: MapSet.new()

  def shared_folder_ids(ids) do
    from(g in Grant, where: g.folder_id in ^ids, distinct: true, select: g.folder_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Which of these pages have been shared with anybody: the ones in `ids` that
  carry a page grant. Their owner's tree marks them, so a share is never
  forgotten about.
  """
  @spec shared_page_ids([integer]) :: MapSet.t()
  def shared_page_ids([]), do: MapSet.new()

  def shared_page_ids(ids) do
    from(g in Grant, where: g.page_id in ^ids, distinct: true, select: g.page_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp resolve_subject(%User{} = u, _by, _resource), do: {:ok, u}
  defp resolve_subject(%Group{} = g, _by, _resource), do: {:ok, g}

  # An address nobody here uses goes through `Accounts.invite_user/3`, which is
  # the one place allowed to bring a new account into existence — and the one
  # place that tells the person it happened. Before that existed this called
  # `get_or_create_user_by_email/1` and quietly made accounts in every
  # registration mode, which made the modes decorative.
  defp resolve_subject(email, %User{} = granted_by, resource) when is_binary(email) do
    case Accounts.invite_user(email, granted_by, to: describe_resource(resource)) do
      {:ok, user} ->
        {:ok, user}

      {:error, :invites_disabled} ->
        {:error,
         "No account here uses that address, and this server does not make one " <>
           "for people you share things with. An admin can invite them."}

      {:error, _} ->
        {:error, "That doesn't look like an email address."}
    end
  end

  defp describe_resource(%Board{name: name}), do: "the board “#{name}”"
  defp describe_resource(%Card{title: title}), do: "the card “#{title}”"
  defp describe_resource(%Page{title: title}), do: "the page “#{title}”"
  defp describe_resource(%Folder{name: name}), do: "the folder “#{name}”"
  defp describe_resource(%SavedView{name: name}), do: "the view “#{name}”"
  defp describe_resource(%Slipdock.Tools.Tool{name: name}), do: "the Tool “#{name}”"
  defp describe_resource(_), do: nil

  defp subject_attrs(%User{id: id}), do: %{user_id: id}
  defp subject_attrs(%Group{id: id}), do: %{group_id: id}
  defp subject_clause(%User{id: id}), do: dynamic([g], g.user_id == ^id)
  defp subject_clause(%Group{id: id}), do: dynamic([g], g.group_id == ^id)

  defp resource_attrs(%Board{id: id}), do: %{board_id: id}
  defp resource_attrs(%Card{id: id}), do: %{card_id: id}
  defp resource_attrs(%SavedView{id: id}), do: %{saved_view_id: id}
  defp resource_attrs(%Page{id: id}), do: %{page_id: id}
  defp resource_attrs(%Folder{id: id}), do: %{folder_id: id}
  defp resource_attrs(%Slipdock.Tools.Tool{id: id}), do: %{tool_id: id}
  defp resource_clause(%Board{id: id}), do: dynamic([g], g.board_id == ^id)
  defp resource_clause(%Card{id: id}), do: dynamic([g], g.card_id == ^id)
  defp resource_clause(%SavedView{id: id}), do: dynamic([g], g.saved_view_id == ^id)
  defp resource_clause(%Page{id: id}), do: dynamic([g], g.page_id == ^id)
  defp resource_clause(%Folder{id: id}), do: dynamic([g], g.folder_id == ^id)
  defp resource_clause(%Slipdock.Tools.Tool{id: id}), do: dynamic([g], g.tool_id == ^id)

  defp broadcast_resource(%Board{id: id}), do: broadcast(id)
  defp broadcast_resource(%Card{board_id: id}), do: broadcast(id)
  defp broadcast_resource(%SavedView{board_id: id}), do: broadcast(id)
  defp broadcast_resource(%Page{board_id: id}), do: broadcast(id)
  defp broadcast_resource(%Folder{board_id: id}), do: broadcast(id)
  # A Tool is on no board; its page reloads as the share changes.
  defp broadcast_resource(%Slipdock.Tools.Tool{}), do: :ok

  defp broadcast(board_id) do
    Phoenix.PubSub.broadcast(@pubsub, "board:#{board_id}", {:board_changed, board_id})
    Boards.notify_boards_changed(Boards.root_of_board(board_id))
  end

  @doc """
  Listens for what is shared with `user_id` changing: a page or folder grant
  given or taken back. The message is `{:shares_changed}` (#817).
  """
  def subscribe_shares(user_id), do: Phoenix.PubSub.subscribe(@pubsub, shares_topic(user_id))

  defp shares_topic(user_id), do: "shares:user:#{user_id}"

  defp notify_shares(%resource{}, user_ids) when resource in [Page, Folder] do
    Enum.each(user_ids, &Phoenix.PubSub.broadcast(@pubsub, shares_topic(&1), {:shares_changed}))
  end

  defp notify_shares(_resource, _user_ids), do: :ok

  # The people a grant reaches: its user, or everybody in its group.
  defp subject_user_ids(%User{id: id}), do: [id]
  defp subject_user_ids(%Group{id: id}), do: group_member_ids(id)
  defp subject_user_ids(%Grant{user_id: nil, group_id: id}), do: group_member_ids(id)
  defp subject_user_ids(%Grant{user_id: id}), do: [id]

  defp group_member_ids(group_id),
    do: Repo.all(from(m in "group_members", where: m.group_id == ^group_id, select: m.user_id))
end
