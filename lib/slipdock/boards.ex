defmodule Slipdock.Boards do
  @moduledoc """
  The Boards context: boards, columns, cards, tags, checklists, comments and
  the activity log. Every mutation broadcasts `{:board_changed, board_id}` on
  the board's PubSub topic so open LiveViews refresh.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Slipdock.Quota
  alias Slipdock.Repo
  alias Slipdock.Rollup

  alias Slipdock.Boards.{BoardOrder, CardLink, CardUrl, FieldDefinition, FieldValue, Milestone}
  alias Slipdock.Boards.StatusUpdate
  alias Slipdock.Boards.Owned

  alias Slipdock.Boards.{
    Activity,
    Attachment,
    Board,
    Card,
    ChecklistItem,
    Column,
    Comment,
    SavedView,
    Tag,
    Template
  }

  alias Slipdock.Accounts.User
  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config
  # Semantic search keeps its own index of everything people write on a card
  # (see `Slipdock.Search`). Every write below that changes such text, or the
  # facets a chunk names, queues the card; the queue embeds it a moment later
  # so no save ever waits on the model.
  alias Slipdock.Search.Indexer

  @pubsub Slipdock.PubSub

  # Card fields a "card_updated" automation trigger can name.
  @automatable_fields ~w(title description priority start_date due_date percent_complete flags completed color)a

  ## PubSub

  def subscribe(board_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(board_id))
  def subscribe_all, do: Phoenix.PubSub.subscribe(@pubsub, "boards")
  def subscribe_templates, do: Phoenix.PubSub.subscribe(@pubsub, "templates")

  # A change inside a sub-board is also a change to every board above it
  # (the parent card's subcard progress), so notify the whole ancestor chain.
  defp broadcast(board_id) do
    Enum.each(ancestor_board_ids(board_id), fn id ->
      Phoenix.PubSub.broadcast(@pubsub, topic(id), {:board_changed, id})
    end)

    Phoenix.PubSub.broadcast(@pubsub, "boards", {:boards_changed})
    :ok
  end

  # Tags are shared by a whole board tree, so tag changes notify every board in it.
  @doc false
  def broadcast_tree(root_id), do: do_broadcast_tree(root_id)

  defp do_broadcast_tree(root_id) do
    from(b in Board, where: b.id == ^root_id or b.root_id == ^root_id, select: b.id)
    |> Repo.all()
    |> Enum.each(&Phoenix.PubSub.broadcast(@pubsub, topic(&1), {:board_changed, &1}))

    Phoenix.PubSub.broadcast(@pubsub, "boards", {:boards_changed})
    :ok
  end

  defp broadcast_templates do
    Phoenix.PubSub.broadcast(@pubsub, "templates", {:templates_changed})
    :ok
  end

  defp ancestor_board_ids(board_id) do
    case Repo.one(
           from(b in Board,
             left_join: c in Card,
             on: c.id == b.parent_card_id,
             where: b.id == ^board_id,
             select: c.board_id
           )
         ) do
      nil -> [board_id]
      parent_board_id -> [board_id | ancestor_board_ids(parent_board_id)]
    end
  end

  defp topic(board_id), do: "board:#{board_id}"

  ## Boards

  @doc """
  Top-level boards (sub-boards are reached through their parent card).

  Archived boards are left out unless `:archived` says otherwise: `false`
  (the default) for the boards in play, `true` for the archived ones alone,
  `:all` for both.
  """
  def list_boards(opts \\ []) do
    from(b in Board, where: is_nil(b.parent_card_id))
    |> filter_archived(Keyword.get(opts, :archived, false))
    |> order_by([b], asc: b.inserted_at)
    |> Repo.all()
    |> Repo.preload(
      cards: from(c in Card, where: is_nil(c.archived_at), select: [:id, :completed, :board_id]),
      columns: from(c in Column, select: [:id, :board_id])
    )
  end

  @doc """
  Narrows a board query by whether the board is archived: `false` for the
  boards in play, `true` for the archived ones, `:all` for both.
  """
  def filter_archived(query, :all), do: query
  def filter_archived(query, true), do: where(query, [b], not is_nil(b.archived_at))
  def filter_archived(query, _false), do: where(query, [b], is_nil(b.archived_at))

  @doc """
  Finds a board by numeric id, code, or (case-insensitive) name, among every
  board on the server. Anything acting for a person should go through
  `Slipdock.Access.find_board/2` instead, which only looks among the boards
  they can read.
  """
  def find_board(ref) do
    case matching_boards(ref, Board, 1) do
      [board | _] -> {:ok, board}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  The boards in `scope` (a `Board` query) that `ref` could mean, best first.

  A numeric ref is an id; if no board in scope has it, it is tried as a code
  or name like any other. Root boards win over sub-boards, and a code match
  wins over a name match, so an explicit handle beats a name someone else
  happens to share. `limit` caps the code-and-name lookup.
  """
  def matching_boards(ref, scope \\ Board, limit \\ nil)

  def matching_boards(ref, scope, _limit) when is_integer(ref),
    do: Repo.all(from(b in scope, where: b.id == ^ref))

  def matching_boards(ref, scope, limit) when is_binary(ref) do
    with {id, ""} <- Integer.parse(ref),
         [_ | _] = found <- matching_boards(id, scope, limit) do
      found
    else
      _ -> by_code_or_name(ref, scope, limit)
    end
  end

  defp by_code_or_name(ref, scope, limit) do
    code = Board.sanitize_code(ref)
    name = String.downcase(String.trim(ref))

    query =
      from(b in scope,
        where: b.code == ^code or fragment("lower(?)", b.name) == ^name,
        order_by: [
          asc: fragment("? IS NOT NULL", b.parent_card_id),
          # IS DISTINCT FROM, not IS NOT: null-safe inequality, so an exact
          # code match sorts first. SQLite spelled the same thing IS NOT.
          asc: fragment("? IS DISTINCT FROM ?", b.code, ^code),
          asc: b.id
        ]
      )

    query = if limit, do: limit(query, ^limit), else: query
    Repo.all(query)
  end

  @doc "Finds a column on `board` by id or (case-insensitive) name."
  def find_column(%Board{id: board_id}, ref) do
    ref = to_string(ref)

    query =
      case Integer.parse(ref) do
        {id, ""} ->
          from(c in Column, where: c.board_id == ^board_id and c.id == ^id)

        _ ->
          name = String.downcase(String.trim(ref))

          from(c in Column,
            where: c.board_id == ^board_id and fragment("lower(?)", c.name) == ^name
          )
      end

    case Repo.one(from(q in query, limit: 1)) do
      nil -> {:error, :not_found}
      column -> {:ok, column}
    end
  end

  @doc "Finds a tag on `board` by id or name (case-insensitive)."
  def find_tag(%Board{} = board, ref) do
    board_id = Board.root_id(board)
    ref = to_string(ref)

    query =
      case Integer.parse(ref) do
        {id, ""} ->
          from(t in Tag, where: t.board_id == ^board_id and t.id == ^id)

        _ ->
          name = String.downcase(String.trim(ref))
          from(t in Tag, where: t.board_id == ^board_id and fragment("lower(?)", t.name) == ^name)
      end

    case Repo.one(from(q in query, limit: 1)) do
      nil -> {:error, :not_found}
      tag -> {:ok, tag}
    end
  end

  def get_board(id) do
    case Repo.get(Board, id) do
      nil -> nil
      board -> load_board(board)
    end
  end

  def get_board!(id), do: Board |> Repo.get!(id) |> load_board()

  defp load_board(%Board{} = board) do
    board
    |> Repo.preload(
      columns: [cards: {active_cards_query(), card_preloads()}],
      saved_views: [],
      parent_card: [],
      template: [],
      owner: []
    )
    |> Map.put(:tags, list_tags(Board.root_id(board)))
    |> Map.put(:milestones, list_milestones(Board.root_id(board)))
    |> Map.put(:fields, Slipdock.Fields.list_fields(Board.root_id(board)))
    |> put_rollup(Rollup.build(Board.root_id(board)))
    |> put_computed()
    |> put_placed_pages()
  end

  # Wiki pages placed in this board's lists. Loaded with the board rather than
  # per list, and left unfiltered by reader — drafts are dropped by whoever
  # renders them, the same way a card's permissions are checked there.
  defp put_placed_pages(%Board{} = board) do
    by_column = Slipdock.Wiki.placed_on(board)
    %{board | columns: Enum.map(board.columns, &%{&1 | pages: Map.get(by_column, &1.id, [])})}
  end

  # Formula fields are computed across the board's cards at once.
  defp put_computed(%Board{fields: fields, columns: columns} = board) do
    cards = columns |> Enum.flat_map(& &1.cards) |> Slipdock.Fields.decorate(fields)
    by_id = Map.new(cards, &{&1.id, &1})

    columns = Enum.map(columns, fn col -> %{col | cards: Enum.map(col.cards, &by_id[&1.id])} end)
    %{board | columns: columns}
  end

  defp put_rollup(board, rollup), do: board |> Rollup.decorate(rollup) |> Map.put(:rollup, rollup)

  @doc "The rollup of the tree `board` belongs to (see `Slipdock.Rollup`)."
  def rollup(%Board{} = board), do: Rollup.build(Board.root_id(board))

  defp active_cards_query do
    from(c in Card, where: is_nil(c.archived_at), order_by: [asc: c.position])
  end

  # Dependencies are loaded as light "stubs" (no nested preloads).
  defp dependency_query do
    from(c in Card,
      select: [
        :id,
        :title,
        :completed,
        :archived_at,
        :column_id,
        :board_id,
        :priority,
        :start_date,
        :due_date
      ]
    )
  end

  defp link_query, do: from(l in CardLink, order_by: [asc: l.kind, asc: l.id])

  defp link_stub_query do
    from(c in Card,
      select: [:id, :title, :completed, :archived_at, :board_id, :column_id, :priority, :due_date]
    )
  end

  defp board_stub_query,
    do: from(b in Board, select: [:id, :name, :root_id, :parent_card_id, :color])

  # A card's sub-board is loaded as a summary: its lists and the state of its cards.
  defp sub_board_query do
    from(b in Board, select: [:id, :name, :parent_card_id, :root_id, :template_id])
  end

  defp sub_board_preloads do
    [
      columns:
        from(c in Column,
          order_by: c.position,
          select: [:id, :name, :position, :color, :board_id]
        ),
      cards:
        from(c in Card,
          where: is_nil(c.archived_at),
          select: [:id, :title, :completed, :archived_at, :board_id, :column_id]
        )
    ]
  end

  defp card_preloads do
    [
      :tags,
      :assignee,
      :assignees,
      :checklist_items,
      :comments,
      :attachments,
      :urls,
      :status_updates,
      :votes,
      field_values: [:field],
      links_out: {link_query(), to: {link_stub_query(), [board: board_stub_query()]}},
      links_in: {link_query(), from: {link_stub_query(), [board: board_stub_query()]}},
      blocked_by: dependency_query(),
      blocks: dependency_query(),
      sub_board: {sub_board_query(), sub_board_preloads()}
    ]
  end

  @doc """
  The chain of `%{board: board, card: card}` pairs above `board`, root first:
  each entry is a board and the card on it that owns the next level down.
  Empty for a root board.
  """
  def ancestry(%Board{parent_card_id: nil}), do: []

  def ancestry(%Board{parent_card_id: card_id}) do
    card = Repo.get!(Card, card_id)
    parent = Repo.get!(Board, card.board_id)
    ancestry(parent) ++ [%{board: parent, card: card}]
  end

  @default_columns [
    %{"name" => "Backlog", "category" => "todo"},
    %{"name" => "To Do", "category" => "todo"},
    %{"name" => "In Progress", "category" => "doing"},
    %{"name" => "Done", "category" => "done"}
  ]

  @doc """
  Creates a board. Pass `template: %Template{}` to take its lists; otherwise
  the default four lists are created. `owner_id:` says whose it is, and a
  root board must have one — an `"owner_id"` in `attrs` is ignored, since
  attributes are what forms send.
  """
  def create_board(attrs, opts \\ []) do
    template = opts[:template]
    columns = if template, do: template.columns, else: @default_columns
    attrs = attrs |> put_code() |> put_shortcut(nil, opts)

    result =
      Multi.new()
      |> Multi.insert(
        :board,
        %Board{template_id: template && template.id, kind: template_kind(template, opts)}
        |> Board.changeset(attrs)
        |> Ecto.Changeset.change(Keyword.take(opts, [:parent_card_id, :root_id, :owner_id]))
        |> enforce_board_limit()
      )
      |> Multi.run(:columns, fn repo, %{board: board} -> insert_columns(repo, board, columns) end)
      |> Multi.run(:activity, fn repo, %{board: board} ->
        log(repo, board.id, nil, "board", "created board “#{board.name}”")
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{board: board}} ->
        # A template may carry a documentation skeleton as well as lists, so
        # a new board can arrive with somewhere to write rather than an empty
        # wiki (see `Slipdock.Wiki.install_template_pages/3`).
        if template, do: Slipdock.Wiki.install_template_pages(board, template, opts[:owner_id])
        broadcast(board.id)
        {:ok, board}

      {:error, :board, changeset, _} ->
        {:error, changeset}
    end
  end

  # A template's kind goes to the boards made from it — but not to the
  # sub-boards inside their cards: a sprint's own lists are ordinary lists.
  defp template_kind(nil, _opts), do: nil

  defp template_kind(%Template{kind: kind}, opts),
    do: if(opts[:parent_card_id], do: nil, else: kind)

  # The guardrail on how many boards one person may own. Only root boards count
  # (see `Slipdock.Quota`): a sub-board exists because a card has subcards, and
  # refusing those would turn the board limit into a limit on subcards.
  #
  # A root board with nobody owning it would be nobody's to open, and would
  # count against nobody's quota, so it is refused rather than made.
  defp enforce_board_limit(changeset) do
    get = &Ecto.Changeset.get_field(changeset, &1)

    cond do
      get.(:root_id) || get.(:parent_card_id) -> changeset
      is_nil(get.(:owner_id)) -> Ecto.Changeset.add_error(changeset, :owner_id, "can't be blank")
      true -> Quota.enforce_owner(changeset, get.(:owner_id), :boards)
    end
  end

  defp insert_columns(repo, board, columns) do
    columns
    |> Template.normalize_columns()
    |> Enum.with_index()
    |> Enum.each(fn {col, i} ->
      repo.insert!(%Column{
        board_id: board.id,
        name: col["name"],
        position: i,
        wip_limit: col["wip_limit"],
        color: col["color"],
        category: col["category"]
      })
    end)

    {:ok, :ok}
  end

  ## Sub-boards

  @doc """
  Gives `card` a board of its own (for subcards), with lists taken from
  `template`. The sub-board is named after the card, shares the parent
  board's colour, and shares tags with the root board.
  """
  def create_sub_board(%Card{} = card, %Template{} = template) do
    parent = Repo.get!(Board, card.board_id)

    if Repo.exists?(from(b in Board, where: b.parent_card_id == ^card.id)) do
      {:error, "This card already has subcards."}
    else
      case create_board(
             # A simple board's subcards are as simple as it is.
             %{"name" => card.title, "color" => parent.color, "simple" => parent.simple},
             template: template,
             parent_card_id: card.id,
             root_id: Board.root_id(parent),
             owner_id: parent.owner_id
           ) do
        {:ok, board} ->
          log(
            Repo,
            card.board_id,
            card.id,
            "card",
            "added subcards to “#{card.title}” (#{template.name} template)"
          )

          broadcast(card.board_id)
          {:ok, board}

        {:error, changeset} ->
          {:error, "Couldn't create the sub-board: " <> inspect(changeset.errors)}
      end
    end
  end

  @doc "Removes a card's sub-board and everything on it."
  def delete_sub_board(%Card{} = card) do
    case Repo.one(from(b in Board, where: b.parent_card_id == ^card.id)) do
      nil ->
        {:error, "This card has no subcards."}

      board ->
        Repo.delete!(board)
        log(Repo, card.board_id, card.id, "card", "removed the subcards of “#{card.title}”")
        broadcast(card.board_id)
        {:ok, get_card!(card.id)}
    end
  end

  ## Templates

  def list_templates, do: Repo.all(from(t in Template, order_by: [asc: t.name]))

  def get_template!(id), do: Repo.get!(Template, id)

  @doc "Finds a template by id or (case-insensitive) name."
  def find_template(ref) do
    ref = to_string(ref)

    query =
      case Integer.parse(ref) do
        {id, ""} ->
          from(t in Template, where: t.id == ^id)

        _ ->
          name = String.downcase(String.trim(ref))
          from(t in Template, where: fragment("lower(?)", t.name) == ^name)
      end

    case Repo.one(from(q in query, limit: 1)) do
      nil -> {:error, :not_found}
      template -> {:ok, template}
    end
  end

  def create_template(attrs) do
    %Template{}
    |> Template.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn _ -> broadcast_templates() end)
  end

  def update_template(%Template{} = template, attrs) do
    template
    |> Template.changeset(attrs)
    |> Repo.update()
    |> tap_ok(fn _ -> broadcast_templates() end)
  end

  def delete_template(%Template{} = template) do
    Repo.delete(template) |> tap_ok(fn _ -> broadcast_templates() end)
  end

  def change_template(%Template{} = template, attrs \\ %{}),
    do: Template.changeset(template, attrs)

  @doc "Template attributes describing `board`'s current lists."
  def template_attrs_from_board(%Board{} = board) do
    columns =
      from(c in Column, where: c.board_id == ^board.id, order_by: c.position)
      |> Repo.all()
      |> Enum.map(
        &%{
          "name" => &1.name,
          "wip_limit" => &1.wip_limit,
          "color" => &1.color,
          "category" => &1.category
        }
      )

    %{
      "name" => board.name,
      "description" => board.description,
      "columns" => columns,
      "kind" => board.kind
    }
  end

  def update_board(%Board{} = board, attrs) do
    board
    |> Board.changeset(attrs |> put_code(board) |> put_shortcut(board))
    |> Repo.update()
    |> tap_ok(&broadcast(&1.id))
  end

  def delete_board(%Board{} = board) do
    keys = file_keys(from(b in Board, where: b.id == ^board.id or b.root_id == ^board.id))

    Repo.delete(board)
    |> tap_ok(fn b ->
      remove_files(keys)
      broadcast(b.id)
    end)
  end

  def change_board(%Board{} = board, attrs \\ %{}), do: Board.changeset(board, attrs)

  ## Archiving and ordering boards ---------------------------------------------

  @doc """
  Puts a board away. It drops off the board index, the switcher, quick add and
  the list of boards a card can move to, but nothing on it is deleted: the
  link still opens it, and its cards still turn up in search.

  Only root boards can be archived — a sub-board belongs to the card it hangs
  off, and goes away with it.
  """
  def archive_board(%Board{} = board) do
    cond do
      Board.sub_board?(board) -> {:error, :sub_board}
      Board.archived?(board) -> {:ok, board}
      true -> set_archived(board, DateTime.utc_now(:second), "archived")
    end
  end

  @doc """
  Brings an archived board back to the index it came off — if its owner has
  room for another board, since an archived one is not counted.
  """
  def unarchive_board(%Board{} = board) do
    if Board.archived?(board), do: set_archived(board, nil, "restored"), else: {:ok, board}
  end

  defp set_archived(%Board{} = board, at, verb) do
    board
    |> Ecto.Changeset.change(archived_at: at)
    |> then(&if(is_nil(at), do: Quota.enforce_owner(&1, board.owner_id, :boards), else: &1))
    |> Repo.update()
    |> tap_ok(fn b ->
      log(Repo, b.id, nil, "board", "#{verb} board “#{b.name}”")
      broadcast(b.id)
    end)
  end

  @doc """
  Where `user` has put each board on their own index, as a map of board id to
  position. Boards they have never placed are not in it.
  """
  def board_order(%User{} = user) do
    from(o in BoardOrder, where: o.user_id == ^user.id, select: {o.board_id, o.position})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Sets the order `user` lists boards in: `ids` is every board they can see, in
  the order they want them. The order is theirs alone — nobody else's index
  moves — and a board left out of `ids` loses its place and falls back to the
  end, where a board nobody has placed sits.

  Ids of boards the user cannot see are ignored.
  """
  def reorder_boards(%User{} = user, ids) do
    ids = Enum.map(ids, &to_id/1)

    visible =
      from(b in Board, where: b.id in ^ids, select: b.id)
      |> Repo.all()
      |> MapSet.new()

    rows =
      ids
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(visible, &1))
      |> Enum.with_index()
      |> Enum.map(fn {id, i} ->
        %{
          user_id: user.id,
          board_id: id,
          position: i,
          inserted_at: DateTime.utc_now(:second),
          updated_at: DateTime.utc_now(:second)
        }
      end)

    Repo.delete_all(from(o in BoardOrder, where: o.user_id == ^user.id))
    Repo.insert_all(BoardOrder, rows)

    Phoenix.PubSub.broadcast(@pubsub, "boards", {:boards_changed})
    :ok
  end

  defp to_id(%Board{id: id}), do: id
  defp to_id(id) when is_integer(id), do: id

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_id(_), do: nil

  @doc """
  Moves one board a place up or down `among` the boards it is listed with,
  for `user` alone. `direction` is `:up` or `:down`; a board already at the
  end it is asked to move towards stays where it is.
  """
  def nudge_board(%User{} = user, %Board{} = board, direction, among) do
    ids = Enum.map(among, & &1.id)
    index = Enum.find_index(ids, &(&1 == board.id))
    target = if direction == :up, do: index && index - 1, else: index && index + 1

    if (index && target >= 0) and target < length(ids) do
      ids
      |> List.delete_at(index)
      |> List.insert_at(target, board.id)
      |> then(&reorder_boards(user, &1))
    else
      :ok
    end
  end

  @doc """
  Puts `board` where `before_id` is, for `user` alone — the move a drag makes.
  `among` is the boards as they are listed now, and `before_id` the board the
  dragged one was dropped in front of, or nil for the end of the list.
  """
  def place_board(%User{} = user, %Board{} = board, before_id, among) do
    before_id = to_id(before_id)
    ids = among |> Enum.map(& &1.id) |> List.delete(board.id)
    at = Enum.find_index(ids, &(&1 == before_id)) || length(ids)
    reorder_boards(user, List.insert_at(ids, at, board.id))
  end

  @doc """
  The last time anything was logged anywhere in each of `boards`' trees, as a
  map of root board id to `DateTime`. Boards nothing has happened on yet are
  left out.
  """
  def last_activity_at(boards) do
    ids = Enum.map(boards, & &1.id)

    from(a in Activity,
      join: b in Board,
      on: b.id == a.board_id,
      where: b.id in ^ids or b.root_id in ^ids,
      group_by: coalesce(b.root_id, b.id),
      select: {coalesce(b.root_id, b.id), max(a.inserted_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Puts boards in the order `sort` asks for — one of the orders
  `Slipdock.Accounts.User.board_sorts/0` lists.

    * `"manual"` — where the reader put them (see `reorder_boards/2`), with
      boards they have never placed at the end, oldest first
    * `"name"` — by name, case-insensitively
    * `"newest"` / `"oldest"` — when the board was created
    * `"active"` — the most recently touched first (see `last_activity_at/1`)
    * `"cards"` — the busiest first, by how many cards are on the board

  The manual order is the tie-break for every other one, so boards that look
  the same to a sort keep a place that doesn't move about.
  """
  def sort_boards(boards, sort) do
    # The manual order first: every sort below is stable, so boards a sort
    # cannot tell apart fall back on where the reader put them.
    boards = Enum.sort_by(boards, &manual_key/1)

    case sort do
      "name" -> Enum.sort_by(boards, &String.downcase(&1.name || ""))
      "newest" -> Enum.sort_by(boards, &made_key/1, :desc)
      "oldest" -> Enum.sort_by(boards, &made_key/1, :asc)
      "active" -> Enum.sort_by(boards, &touched_at/1, {:desc, DateTime})
      "cards" -> Enum.sort_by(boards, &length(&1.cards), :desc)
      _manual -> boards
    end
  end

  # Placed boards first, in the order they were placed; the rest behind them,
  # oldest first. The timestamp goes in as a number: `DateTime`s compared as
  # plain terms sort by day before month before year, which is not a date.
  defp manual_key(%Board{position: nil} = b), do: {1, 0, made_key(b)}
  defp manual_key(%Board{position: pos} = b), do: {0, pos, made_key(b)}

  defp touched_at(%Board{} = board), do: board.last_activity_at || board.inserted_at

  # Timestamps are only accurate to the second, so boards made in the same one
  # fall back on the order they were made in rather than on a coin toss.
  defp made_key(%Board{} = board), do: {DateTime.to_unix(board.inserted_at), board.id}

  @doc """
  A board code that is free to use: `name`'s code, or a variation of it when
  that one is taken. Pass `except` to ignore a board's own code, so re-saving a
  board keeps the code it already has.
  """
  def suggest_code(name, except \\ nil) do
    Board.code_from_name(name, &code_taken?(&1, except))
  end

  defp code_taken?(code, except) do
    query = from(b in Board, where: b.code == ^code)
    query = if except, do: from(b in query, where: b.id != ^except), else: query
    Repo.exists?(query)
  end

  @doc """
  A board shortcut key that is free to use: `name`'s key, or the next one
  along when that is taken. Pass `except` to ignore a board's own key, so
  re-saving a board keeps the key it already has.
  """
  def suggest_shortcut(name, except \\ nil) do
    Board.shortcut_from_name(name, &shortcut_taken?(&1, except))
  end

  defp shortcut_taken?(shortcut, except) do
    query = from(b in Board, where: b.shortcut == ^shortcut)
    query = if except, do: from(b in query, where: b.id != ^except), else: query
    Repo.exists?(query)
  end

  # Top-level boards always have a shortcut, on the same terms as the code: one
  # left out of an update keeps the key the board has, and one that is blank is
  # taken from the name, so clearing the field in a form asks for a fresh key.
  # Sub-boards never get one — the switcher only lists boards.
  defp put_shortcut(attrs, board, opts \\ []) do
    {key, given} = fetch_attr(attrs, :shortcut)
    sub_board? = not is_nil(opts[:parent_card_id]) or (board && Board.sub_board?(board))

    cond do
      sub_board? ->
        attrs

      is_nil(key) and not is_nil(board) ->
        attrs

      Board.sanitize_shortcut(given) == "" ->
        {_, name} = fetch_attr(attrs, :name)
        name = if to_string(name) == "", do: board && board.name, else: name

        put_attr(
          attrs,
          key || attr_key(attrs, "shortcut"),
          suggest_shortcut(name, board && board.id)
        )

      true ->
        attrs
    end
  end

  # Boards always have a code. One left out of an update keeps the code the
  # board has; one that is missing or blank otherwise is generated from the
  # name, so clearing the field in a form asks for a fresh code.
  defp put_code(attrs, board \\ nil) do
    {key, given} = fetch_attr(attrs, :code)

    cond do
      is_nil(key) and not is_nil(board) ->
        attrs

      Board.sanitize_code(given) == "" ->
        {_, name} = fetch_attr(attrs, :name)
        name = if to_string(name) == "", do: board && board.name, else: name
        put_attr(attrs, key || attr_key(attrs, "code"), suggest_code(name, board && board.id))

      true ->
        attrs
    end
  end

  defp fetch_attr(attrs, field) do
    cond do
      Map.has_key?(attrs, field) ->
        {field, Map.get(attrs, field)}

      Map.has_key?(attrs, to_string(field)) ->
        {to_string(field), Map.get(attrs, to_string(field))}

      true ->
        {nil, nil}
    end
  end

  # Match the key style the rest of the attrs use, so a map isn't left mixed.
  defp attr_key(attrs, field) do
    if Enum.any?(attrs, fn {k, _} -> is_atom(k) end), do: String.to_atom(field), else: field
  end

  defp put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  ## Columns

  def get_column!(id), do: Repo.get!(Column, id)

  @doc "The list `id` if it is on `board_id`, or nil: for ids a client sent."
  def get_board_column(board_id, id) do
    case to_id(id) do
      nil -> nil
      id -> Repo.one(from(c in Column, where: c.id == ^id and c.board_id == ^board_id))
    end
  end

  def create_column(%Board{} = board, attrs) do
    position = next_position(from(c in Column, where: c.board_id == ^board.id))

    %Column{board_id: board.id, position: position}
    |> Column.changeset(Map.put(attrs, "board_id", board.id))
    |> Repo.insert()
    |> tap_ok(fn col ->
      log(Repo, board.id, nil, "column", "added list “#{col.name}”")
      broadcast(board.id)
    end)
  end

  def update_column(%Column{} = column, attrs) do
    column
    |> Column.changeset(attrs)
    |> Repo.update()
    |> tap_ok(&broadcast(&1.board_id))
  end

  def delete_column(%Column{} = column) do
    Repo.delete(column)
    |> tap_ok(fn col ->
      log(Repo, col.board_id, nil, "column", "deleted list “#{col.name}”")
      broadcast(col.board_id)
    end)
  end

  def change_column(%Column{} = column, attrs \\ %{}), do: Column.changeset(column, attrs)

  @doc """
  Moves a column so that it sits directly before `before_id`, or at the end
  of the board when `before_id` is nil.
  """
  def move_column(board_id, column_id, before_id) do
    ids =
      Repo.all(
        from(c in Column, where: c.board_id == ^board_id, order_by: c.position, select: c.id)
      )

    if column_id in ids do
      reordered = insert_before(List.delete(ids, column_id), column_id, before_id)

      Repo.transaction(fn ->
        reordered
        |> Enum.with_index()
        |> Enum.each(fn {id, i} ->
          from(c in Column, where: c.id == ^id and c.position != ^i)
          |> Repo.update_all(set: [position: i])
        end)
      end)

      broadcast(board_id)
      :ok
    else
      {:error, :not_found}
    end
  end

  defp insert_before(ids, moving, nil), do: ids ++ [moving]

  defp insert_before(ids, moving, before_id) do
    case Enum.find_index(ids, &(&1 == before_id)) do
      nil -> ids ++ [moving]
      i -> List.insert_at(ids, i, moving)
    end
  end

  ## Cards

  @doc """
  Active cards assigned to `user`, across every board, with their board,
  list, tags and rollup, ordered by due date then title.
  """
  def list_assigned_cards(%Slipdock.Accounts.User{} = user) do
    cards =
      from(c in Card,
        where: is_nil(c.archived_at),
        where:
          c.id in subquery(
            from(a in "card_assignees", where: a.user_id == ^user.id, select: a.card_id)
          ),
        order_by: [asc_nulls_last: c.due_date, asc: c.title]
      )
      |> Repo.all()
      |> Repo.preload([:board, :column, :tags, :assignee, :assignees])

    rollups =
      cards
      |> Enum.map(&Board.root_id(&1.board))
      |> Enum.uniq()
      |> Map.new(&{&1, Rollup.build(&1)})

    Enum.map(cards, &Rollup.put_stats(&1, rollups[Board.root_id(&1.board)]))
  end

  def get_card!(id) do
    Card
    |> Repo.get!(id)
    |> Repo.preload([:column | card_preloads()])
    |> with_rollup()
  end

  def get_card(nil), do: nil

  def get_card(id) do
    case Repo.get(Card, id) do
      nil -> nil
      card -> card |> Repo.preload([:column | card_preloads()]) |> with_rollup()
    end
  end

  defp with_rollup(%Card{} = card) do
    root_id =
      Repo.one!(
        from(b in Board, where: b.id == ^card.board_id, select: coalesce(b.root_id, b.id))
      )

    card
    |> Rollup.put_stats(Rollup.build(root_id))
    |> Slipdock.Fields.decorate_one(Slipdock.Fields.list_fields(root_id))
  end

  @doc """
  Lists cards on a board, filtered by a map of string keys:
  `"column"`, `"tag"`, `"priority"`, `"flag"`, `"q"`, `"completed"`,
  `"archived"`, `"assignee"`, `"due"`, `"deps"` and `"kind"`.

  `"kind"` is `"card"` or `"document"` (a card whose whole content is the file
  on it — see `Slipdock.Kinds`). Wiki pages are the third kind of thing in a
  list and are not cards: `Slipdock.Wiki.list_pages/2` lists those.

  `"due"` and `"deps"` take the buckets the board's views use
  (`Slipdock.Swimlanes.Config.dues/0` and `deps/0`): `"overdue"`, `"today"`,
  `"week"`, `"month"`, `"has"`, `"none"`, and `"blocked"`, `"ready"`,
  `"blocking"`, `"violated"`, `"free"`. A value that is not one of them is
  ignored rather than raising, because these arrive from query strings.

  `"assignee"` matches a person's email exactly or their name loosely, takes
  an id, and takes `"none"` (or `"unassigned"`) for the cards nobody owns.
  """
  def list_cards(%Board{} = board, filters \\ %{}) do
    query =
      from(c in Card,
        where: c.board_id == ^board.id,
        join: col in assoc(c, :column),
        order_by: [asc: col.position, asc: c.position],
        preload: [column: col]
      )

    query =
      if filters["archived"] in [true, "true"],
        do: where(query, [c], not is_nil(c.archived_at)),
        else: where(query, [c], is_nil(c.archived_at))

    query =
      case filters["column"] do
        nil ->
          query

        ref ->
          case find_column(board, ref) do
            {:ok, col} -> where(query, [c], c.column_id == ^col.id)
            _ -> where(query, [c], false)
          end
      end

    query =
      case filters["priority"] do
        nil -> query
        p -> where(query, [c], c.priority == ^p)
      end

    query =
      case filters["completed"] do
        nil -> query
        v -> where(query, [c], c.completed == ^(v in [true, "true"]))
      end

    query =
      case filters["q"] do
        nil ->
          query

        q ->
          like = "%" <> String.downcase(q) <> "%"

          where(
            query,
            [c],
            like(fragment("lower(?)", c.title), ^like) or
              like(fragment("lower(?)", c.description), ^like)
          )
      end

    cards = query |> Repo.all() |> Repo.preload(card_preloads())

    cards
    |> then(fn cards ->
      case filters["flag"] do
        nil -> cards
        flag -> Enum.filter(cards, &(flag in &1.flags))
      end
    end)
    |> then(fn cards ->
      case filters["tag"] do
        nil ->
          cards

        ref ->
          case find_tag(board, ref) do
            {:ok, tag} -> Enum.filter(cards, fn c -> Enum.any?(c.tags, &(&1.id == tag.id)) end)
            _ -> []
          end
      end
    end)
    |> filter_due(filters["due"])
    |> filter_deps(filters["deps"])
    |> filter_assignee(filters["assignee"])
    |> filter_kind(filters["kind"])
  end

  # Documents are recognised from what a card holds rather than stored, so
  # this one filters in memory over the loaded cards (see `Slipdock.Kinds`).
  defp filter_kind(cards, kind) when is_binary(kind) and kind != "" do
    if kind in Slipdock.Kinds.keys(),
      do: Enum.filter(cards, &Slipdock.Kinds.matches?(&1, [kind])),
      else: cards
  end

  defp filter_kind(cards, _), do: cards

  # The date and dependency buckets are the board views' own (see
  # `Slipdock.Swimlanes`), so "overdue" means the same thing in a swimlane, in
  # the API and to the assistant.
  defp filter_due(cards, bucket) when is_binary(bucket) do
    if bucket in Enum.map(Config.dues(), &elem(&1, 0)) and bucket != "",
      do: Enum.filter(cards, &Swimlanes.due_matches?(bucket, &1)),
      else: cards
  end

  defp filter_due(cards, _), do: cards

  defp filter_deps(cards, bucket) when is_binary(bucket) do
    if bucket in Enum.map(Config.deps(), &elem(&1, 0)) and bucket != "",
      do: Enum.filter(cards, &Swimlanes.deps_matches?(bucket, &1)),
      else: cards
  end

  defp filter_deps(cards, _), do: cards

  @unassigned ~w(none nobody unassigned)

  defp filter_assignee(cards, ref) when is_binary(ref) do
    case String.downcase(String.trim(ref)) do
      "" -> cards
      wanted when wanted in @unassigned -> Enum.filter(cards, &(Card.assignees(&1) == []))
      wanted -> Enum.filter(cards, &assignee_matches?(&1, wanted))
    end
  end

  defp filter_assignee(cards, _), do: cards

  # A card matches if any of the people on it does.
  defp assignee_matches?(%Card{} = card, wanted) do
    Enum.any?(Card.assignees(card), fn user ->
      String.downcase(user.email) == wanted or
        String.contains?(String.downcase(user.name || ""), wanted) or
        to_string(user.id) == wanted
    end)
  end

  @doc "Replaces the card's tags with the given list of `%Tag{}`s."
  def set_card_tags(%Card{} = card, tags) when is_list(tags) do
    card = Repo.preload(card, :tags)

    card
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:tags, tags)
    |> Repo.update()
    |> tap_ok(fn updated ->
      broadcast(updated.board_id)
      Indexer.enqueue(updated)
      automate_tags_added(updated, card.tags, tags)
    end)
  end

  @doc """
  Moves a card into a column at a 0-based `index` (`:top`, `:bottom`, or an
  integer). Convenience wrapper over `move_card/3`.
  """
  def move_card_to_index(%Card{} = card, %Column{} = column, index) do
    # The index counts everything in the list, wiki pages included: "second
    # from the top" means what a reader sees, not what the cards table says.
    items = active_items(column.id) |> List.delete({:card, card.id})

    before_ref =
      case index do
        :top -> List.first(items)
        :bottom -> nil
        i when is_integer(i) and i >= 0 -> Enum.at(items, i)
        _ -> nil
      end

    move_card(card.id, column.id, before_ref)
  end

  @doc """
  Adds a card to `column`. `opts[:by]` is the person writing it, when known:
  it is who anybody `@mentioned` in the description is told mentioned them
  (see `Slipdock.Mentions`).
  """
  def create_card(%Column{} = column, attrs, opts \\ []) do
    position = next_position(from(c in Card, where: c.column_id == ^column.id))
    card = %Card{board_id: column.board_id, column_id: column.id, position: position}
    {assignees, attrs} = assignee_change(card, attrs)
    attrs = Slipdock.TimeTracking.normalize_attrs(card, attrs)

    card
    |> Card.changeset(
      attrs
      |> Map.put("board_id", column.board_id)
      |> Map.put("column_id", column.id)
    )
    # The free tier's limit, enforced here rather than in the board UI: the
    # same card can be made from quick add, the CLI, the JSON API, an
    # automation rule and the model, and all of them come through this
    # function. See `Slipdock.Quota`.
    |> Quota.enforce(column)
    |> save_with_assignees(&Repo.insert/1, assignees)
    |> tap_ok(fn card ->
      log(Repo, card.board_id, card.id, "card", "added “#{card.title}” to #{column.name}")
      broadcast(card.board_id)
      Indexer.enqueue(card)
      Slipdock.Mentions.description_changed(card, nil, card.description, opts[:by])
      automate(%{type: "card_created", card: card, column: column})
    end)
  end

  @doc "Changes a card. `opts[:by]` as for `create_card/3`."
  def update_card(%Card{} = card, attrs, opts \\ []) do
    {assignees, attrs} = assignee_change(card, attrs)
    attrs = Slipdock.TimeTracking.normalize_attrs(card, attrs)
    # Who was on it, read only when this write changes that.
    before = if assignees, do: assignee_ids(card), else: []
    changeset = Card.changeset(card, attrs)

    changeset
    |> save_with_assignees(&Repo.update/1, assignees)
    |> tap_ok(fn updated ->
      (describe_card_changes(card, changeset) ++ describe_assignees(card, before, assignees))
      |> Enum.each(&log(Repo, updated.board_id, updated.id, "card", &1))

      # A sub-board is named after its card.
      if Map.has_key?(changeset.changes, :title) do
        from(b in Board, where: b.parent_card_id == ^updated.id)
        |> Repo.update_all(set: [name: updated.title])
      end

      broadcast(updated.board_id)
      Indexer.enqueue(updated)

      if Map.has_key?(changeset.changes, :description),
        do:
          Slipdock.Mentions.description_changed(
            updated,
            card.description,
            updated.description,
            opts[:by]
          )

      automate_card_changes(card, updated, changeset, {before, assignees || before})
    end)
  end

  @doc """
  The ids of the people `card` is assigned to, lead first — read from the
  database, so it is right whether or not the set was preloaded.
  """
  def assignee_ids(%Card{id: nil}), do: []

  def assignee_ids(%Card{id: id, assignee_id: lead}) do
    ids = Repo.all(from(a in "card_assignees", where: a.card_id == ^id, select: a.user_id))
    if lead in ids, do: [lead | List.delete(ids, lead)], else: Enum.sort(ids)
  end

  # Who a write assigns the card to. "assignee_ids" replaces the set, lead
  # first; "add_assignee_ids" and "remove_assignee_ids" edit it, keeping the
  # lead while they are still on it; and a bare "assignee_id" — what every
  # single-person caller sends — replaces it with that one person, which is
  # what it always meant. Returns the new set (nil when the write leaves it
  # alone) and the attrs with the lead in "assignee_id".
  defp assignee_change(card, attrs) do
    ids =
      cond do
        Map.has_key?(attrs, "assignee_ids") ->
          user_ids(attrs["assignee_ids"])

        Map.has_key?(attrs, "add_assignee_ids") or Map.has_key?(attrs, "remove_assignee_ids") ->
          Enum.uniq(assignee_ids(card) ++ user_ids(attrs["add_assignee_ids"])) --
            user_ids(attrs["remove_assignee_ids"])

        Map.has_key?(attrs, "assignee_id") ->
          user_ids(attrs["assignee_id"])

        true ->
          nil
      end

    attrs = Map.drop(attrs, ~w(assignee_ids add_assignee_ids remove_assignee_ids))
    ids = readable_assignees(card, ids)

    case ids do
      nil -> {nil, attrs}
      ids -> {ids, Map.put(attrs, "assignee_id", List.first(ids))}
    end
  end

  defp user_ids(nil), do: []
  defp user_ids(""), do: []

  defp user_ids(ids) when is_list(ids),
    do: ids |> Enum.flat_map(&user_ids/1) |> Enum.uniq()

  defp user_ids(id) when is_integer(id), do: [id]

  defp user_ids(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> [n]
      _ -> []
    end
  end

  defp user_ids(_), do: []

  # The card and who is on it are one write: an assignee row that cannot be
  # written takes the card change back with it, rather than leaving half of it.
  defp save_with_assignees(changeset, save, assignees) do
    Repo.transaction(fn ->
      case changeset |> save.() |> put_assignees(assignees) do
        {:ok, card} -> card
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  The people `refs` name, as ids, if `by` may put every one of them on
  `target` — a card, a page, or the board a new card is going onto. A ref is
  a user id, an email address, or "me".

  Somebody qualifies when `by` can see them (`Slipdock.Access.visible_user_ids/1`)
  and they can read `target` themselves: a card assigned to a person who cannot
  open it tells them nothing and tells whoever assigned it who has an account.
  Anybody else is `{:error, {:not_found, ref}}`, worded the same whether the
  address belongs to nobody or to somebody out of sight, so the answer is not a
  way of finding out who is on the server.
  """
  @spec resolve_assignees(Card.t() | Board.t() | Slipdock.Wiki.Page.t(), User.t() | nil, [term]) ::
          {:ok, [integer]} | {:error, {:not_found, term}}
  def resolve_assignees(target, by, refs) do
    visible = by |> Slipdock.Access.visible_user_ids() |> MapSet.new()

    refs
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, ids} ->
      with %User{} = user <- assignee_ref(ref, by),
           true <- MapSet.member?(visible, user.id),
           true <- can_read_target?(user, target) do
        {:cont, {:ok, ids ++ [user.id]}}
      else
        _ -> {:halt, {:error, {:not_found, ref}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      error -> error
    end
  end

  defp assignee_ref(me, %User{} = by) when me in ~w(me myself mine), do: by
  defp assignee_ref(id, _by) when is_integer(id), do: Repo.get(User, id)

  defp assignee_ref(ref, _by) when is_binary(ref) do
    case Integer.parse(ref) do
      {id, ""} -> Repo.get(User, id)
      _ -> Slipdock.Accounts.get_user_by_email(ref)
    end
  end

  defp assignee_ref(_, _), do: nil

  defp can_read_target?(user, %Card{id: nil, board_id: board_id}),
    do: can_read_target?(user, Repo.get!(Board, board_id))

  defp can_read_target?(user, %Card{} = card),
    do: Slipdock.Access.can_read?(Slipdock.Access.card_permission(user, card))

  defp can_read_target?(user, %Board{} = board),
    do: Slipdock.Access.can_read?(Slipdock.Access.board_permission(user, board))

  defp can_read_target?(user, %Slipdock.Wiki.Page{} = page),
    do: Slipdock.Access.can_read?(Slipdock.Access.page_permission(user, page))

  # The backstop under every caller — the API, the board, a swimlane drop, an
  # automation, the model: whoever is newly put on a card has to exist and be
  # able to read it. The callers that answer a person resolve first, with
  # `resolve_assignees/3`, so they can say no; this one drops quietly.
  defp readable_assignees(_card, nil), do: nil

  defp readable_assignees(card, ids) do
    already = assignee_ids(card)
    {kept, added} = Enum.split_with(ids, &(&1 in already))
    users = Repo.all(from(u in User, where: u.id in ^added))
    readable = users |> Enum.filter(&can_read_target?(&1, card)) |> MapSet.new(& &1.id)
    Enum.filter(ids, &(&1 in kept or MapSet.member?(readable, &1)))
  end

  defp put_assignees({:ok, %Card{} = card}, ids) when is_list(ids) do
    from(a in "card_assignees", where: a.card_id == ^card.id) |> Repo.delete_all()
    Repo.insert_all("card_assignees", Enum.map(ids, &%{card_id: card.id, user_id: &1}))
    {:ok, Repo.preload(card, :assignees, force: true)}
  end

  defp put_assignees(result, _ids), do: result

  defp describe_assignees(_card, _before, nil), do: []

  defp describe_assignees(card, before, ids) do
    cond do
      Enum.sort(before) == Enum.sort(ids) -> []
      ids == [] -> ["unassigned “#{card.title}”"]
      true -> ["assigned “#{card.title}” to #{Enum.map_join(ids, ", ", &assignee_name/1)}"]
    end
  end

  defp describe_card_changes(card, changeset) do
    Enum.flat_map(changeset.changes, fn
      {:title, t} -> ["renamed “#{card.title}” to “#{t}”"]
      {:completed, true} -> ["completed “#{card.title}”"]
      {:completed, false} -> ["reopened “#{card.title}”"]
      {:priority, p} -> ["set priority of “#{card.title}” to #{p}"]
      {:start_date, nil} -> ["cleared start date on “#{card.title}”"]
      {:start_date, d} -> ["set start date on “#{card.title}” to #{d}"]
      {:due_date, nil} -> ["cleared due date on “#{card.title}”"]
      {:due_date, d} -> ["set due date on “#{card.title}” to #{d}"]
      {:percent_complete, nil} -> ["cleared % complete on “#{card.title}”"]
      {:percent_complete, p} -> ["set “#{card.title}” to #{p}% complete"]
      {:column_id, id} -> ["moved “#{card.title}” to #{Repo.get!(Column, id).name}"]
      {:flags, flags} -> ["set flags on “#{card.title}” to #{flags_text(flags)}"]
      {:time_spent, m} -> [time_text("time spent", card, m, changeset)]
      {:time_estimate, m} -> [time_text("estimate", card, m, changeset)]
      _ -> []
    end)
  end

  defp time_text(what, card, nil, _changeset), do: "cleared #{what} on “#{card.title}”"

  defp time_text(what, card, minutes, changeset) do
    unit = Ecto.Changeset.get_field(changeset, :time_unit)
    "set #{what} on “#{card.title}” to #{Slipdock.TimeTracking.format(minutes, unit)}"
  end

  @doc """
  Starts the card's timer. Starting one that is already running leaves it
  alone, so two people pressing start do not lose the first one's time.
  """
  def start_timer(%Card{timer_started_at: %DateTime{}} = card), do: {:ok, card}

  def start_timer(%Card{} = card) do
    # Conditional on the timer still being stopped, so two starts racing each
    # other leave the first one's start time in place.
    {count, _} =
      from(c in Card, where: c.id == ^card.id and is_nil(c.timer_started_at))
      |> Repo.update_all(set: [timer_started_at: DateTime.utc_now(:second)])

    updated = Repo.get!(Card, card.id)

    if count == 1 do
      log(Repo, updated.board_id, updated.id, "card", "started the timer on “#{card.title}”")
      broadcast(updated.board_id)
    end

    {:ok, updated}
  end

  @doc """
  Stops the card's timer and adds the minutes it ran to the time spent.
  Stopping one that isn't running does nothing.
  """
  def stop_timer(%Card{timer_started_at: nil} = card), do: {:ok, card}

  def stop_timer(%Card{timer_started_at: since} = card) do
    minutes = Slipdock.TimeTracking.running(card)
    cap = Slipdock.TimeTracking.max_minutes()

    # Conditional on the timer being the one this card was read with: a stop
    # racing another stop (the API and the board at once) finds it already
    # cleared and adds nothing, rather than counting the minutes twice.
    {count, _} =
      from(c in Card,
        where: c.id == ^card.id and c.timer_started_at == ^since,
        update: [
          set: [
            timer_started_at: nil,
            time_spent: fragment("LEAST(COALESCE(?, 0) + ?, ?)", c.time_spent, ^minutes, ^cap)
          ]
        ]
      )
      |> Repo.update_all([])

    updated = Repo.get!(Card, card.id)

    if count == 1 do
      log(
        Repo,
        updated.board_id,
        updated.id,
        "card",
        "logged #{Slipdock.TimeTracking.format(minutes, updated.time_unit)} on “#{card.title}” with the timer"
      )

      broadcast(updated.board_id)
    end

    {:ok, updated}
  end

  defp assignee_name(id) do
    case Repo.get(Slipdock.Accounts.User, id) do
      nil -> "nobody"
      user -> Slipdock.Accounts.User.display_name(user)
    end
  end

  defp flags_text([]), do: "none"
  defp flags_text(flags), do: Enum.join(flags, ", ")

  def toggle_flag(%Card{} = card, flag) when is_binary(flag) do
    flags =
      if flag in card.flags, do: List.delete(card.flags, flag), else: card.flags ++ [flag]

    update_card(card, %{"flags" => flags})
  end

  def toggle_completed(%Card{} = card) do
    update_card(card, %{"completed" => !card.completed})
  end

  def archive_card(%Card{} = card) do
    card
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Repo.update()
    |> tap_ok(fn c ->
      log(Repo, c.board_id, c.id, "card", "archived “#{c.title}”")
      broadcast(c.board_id)
      Indexer.enqueue(c)
      automate(%{type: "card_archived", card: c})
    end)
  end

  # An archived card does not count against its owner's allowance, so bringing
  # one back is asking for one more — otherwise "archive, add, restore" would
  # go on for ever, trial or no trial.
  def unarchive_card(%Card{} = card) do
    position = next_position(from(c in Card, where: c.column_id == ^card.column_id))

    card
    |> Ecto.Changeset.change(archived_at: nil, position: position)
    |> then(&if(is_nil(card.archived_at), do: &1, else: Quota.enforce(&1, card.board_id)))
    |> Repo.update()
    |> tap_ok(fn c ->
      log(Repo, c.board_id, c.id, "card", "restored “#{c.title}”")
      broadcast(c.board_id)
      Indexer.enqueue(c)
    end)
  end

  def delete_card(%Card{} = card) do
    keys = attachment_keys(from(a in Attachment, where: a.card_id == ^card.id))

    Repo.delete(card)
    |> tap_ok(fn c ->
      remove_files(keys)
      Indexer.forget(c.id)
      log(Repo, c.board_id, nil, "card", "deleted “#{c.title}”")
      broadcast(c.board_id)
    end)
  end

  def list_archived_cards(board_id) do
    from(c in Card,
      where: c.board_id == ^board_id and not is_nil(c.archived_at),
      order_by: [desc: c.archived_at]
    )
    |> Repo.all()
    |> Repo.preload([:tags, :column])
  end

  @doc """
  An archived card on `board_id`, or nil. The id came from a client, so a
  card on anybody else's board is the same as no card at all.
  """
  def get_archived_card(board_id, id) do
    case to_id(id) do
      nil ->
        nil

      id ->
        Repo.one(
          from(c in Card,
            where: c.id == ^id and c.board_id == ^board_id and not is_nil(c.archived_at)
          )
        )
    end
  end

  def change_card(%Card{} = card, attrs \\ %{}), do: Card.changeset(card, attrs)

  @doc """
  Moves a card into `to_column_id`, placing it directly before the card
  `before_id` (or at the end when nil), re-packing positions in both the
  source and destination columns.
  """
  def move_card(card_id, to_column_id, before_id \\ nil) do
    card = Repo.get!(Card, card_id)
    to_column = Repo.get!(Column, to_column_id)

    # A list on another board would pull the card off its own board without
    # any of what `move_card_to_board/2` carries across — and, from a client
    # that sent somebody else's card, onto the sender's board.
    if to_column.board_id == card.board_id,
      do: do_move_card(card, to_column, before_id),
      else: {:error, :wrong_board}
  end

  defp do_move_card(%Card{} = card, %Column{} = to_column, before_id) do
    same_column? = to_column.id == card.column_id

    reorder({:card, card.id}, card.column_id, to_column.id, before_id)

    unless same_column? do
      log(Repo, card.board_id, card.id, "card", "moved “#{card.title}” to #{to_column.name}")
      from_column = Repo.get!(Column, card.column_id)
      apply_column_semantics(Repo.get!(Card, card.id), from_column, to_column)

      automate(%{
        type: "card_moved",
        card: Repo.get!(Card, card.id),
        from: from_column,
        to: to_column,
        column: to_column
      })
    end

    # The list a card sits in is part of what was embedded about it.
    unless same_column?, do: Indexer.enqueue(card.id)

    broadcast(card.board_id)
    :ok
  end

  # What landing in a list means: a "done" list completes the card, leaving
  # one for a to-do or in-progress list reopens it, and a horizon list
  # schedules a card that isn't already inside its range.
  defp apply_column_semantics(%Card{} = card, %Column{} = from, %Column{} = to) do
    attrs =
      %{}
      |> Map.merge(
        cond do
          Column.done?(to) and not card.completed ->
            %{"completed" => true}

          Column.done?(from) and to.category in ~w(todo doing) and card.completed ->
            %{"completed" => false}

          true ->
            %{}
        end
      )
      |> Map.merge(horizon_attrs(card, to))

    if attrs == %{}, do: {:ok, card}, else: update_card(card, attrs)
  end

  defp horizon_attrs(%Card{} = card, %Column{} = to) do
    target = to.horizon_to || to.horizon_from

    cond do
      is_nil(target) ->
        %{}

      Column.drifted?(to, card.due_date) or is_nil(card.due_date) ->
        start =
          if card.start_date && Date.compare(card.start_date, target) == :gt,
            do: nil,
            else: card.start_date

        %{
          "due_date" => target,
          "start_date" => start,
          "date_precision" => to.horizon_unit || card.date_precision
        }

      true ->
        %{}
    end
  end

  ## Moving a card to another board -------------------------------------------

  @doc """
  Moves `card` to a list on a different board, with everything beneath it.

  A card is not only a row in a list: it may hold subcards on a board of its
  own, tags, values for the board's custom fields and a pinned milestone —
  and all of those belong to the *root* board of a tree, not to the board the
  card sits on. Which is why this is not `move_card/3` with a wider `where`:

    * the boards under the card are re-rooted, so their tags and fields keep
      resolving after the move;
    * tags travel by name — matched on the destination tree, created there
      when they are new — for the card and everything under it, because a
      subcard's tags came from the old root too;
    * custom field values travel where the destination tree has a field with
      the same key *and* kind, and are dropped where it does not, because a
      number cannot be stored in a date;
    * a milestone pinned to a moved card is unpinned: it is a date on the old
      tree's roadmap and stays there.

  Moving inside one tree (a subcard promoted to its root board, say) skips
  all of that: the tree already shares its tags, fields and milestones.

  Returns `{:ok, summary}` — the moved card and what it cost on the way — or
  `{:error, message}`.
  """
  def move_card_to_board(%Card{} = card, %Column{} = to_column) do
    cond do
      not is_nil(card.archived_at) ->
        {:error, "Restore the card before moving it."}

      to_column.board_id == card.board_id ->
        move_card(card.id, to_column.id)
        {:ok, empty_move_summary(Repo.get!(Card, card.id))}

      to_column.board_id in subtree_board_ids(card.id) ->
        {:error, "A card can't be moved into its own subcards."}

      true ->
        with :ok <- room_for_move(card, to_column), do: do_move_card_to_board(card, to_column)
    end
  end

  # A card that changes owner takes everything under it into the new owner's
  # count: its live subcards, the pages on its sub-boards and the files on
  # both. Checked against the destination, or a free account could make cards
  # on somebody's paid board and carry them home. Within one owner's boards
  # nothing changes hands, so nothing is checked.
  defp room_for_move(%Card{} = card, %Column{} = to_column) do
    if Quota.owner_id_of(card.board_id) == Quota.owner_id_of(to_column.board_id) do
      :ok
    else
      board_ids = subtree_board_ids(card.id)
      card_ids = [card.id | subtree_card_ids(board_ids)]

      cards =
        Repo.aggregate(
          from(c in Card, where: c.id in ^card_ids and is_nil(c.archived_at)),
          :count
        )

      pages =
        Repo.aggregate(
          from(p in Slipdock.Wiki.Page,
            where: p.board_id in ^board_ids and is_nil(p.archived_at)
          ),
          :count
        )

      {files, bytes} =
        Repo.one(
          from(a in Attachment,
            left_join: p in Slipdock.Wiki.Page,
            on: p.id == a.page_id,
            where: a.card_id in ^card_ids or p.board_id in ^board_ids,
            select: {count(a.id), coalesce(sum(a.size), 0)}
          )
        )

      Quota.refusal(to_column, items: cards + pages + files, storage: bytes)
    end
  end

  defp do_move_card_to_board(%Card{} = card, %Column{} = to_column) do
    from_column = Repo.get!(Column, card.column_id)
    from_board = Repo.get!(Board, card.board_id)
    to_board = Repo.get!(Board, to_column.board_id)
    from_root = Board.root_id(from_board)
    to_root = Board.root_id(to_board)
    to_owner = Repo.one(from(b in Board, where: b.id == ^to_root, select: b.owner_id))
    board_ids = subtree_board_ids(card.id)

    {:ok, summary} =
      Repo.transaction(fn ->
        repack(List.delete(active_items(card.column_id), {:card, card.id}), card.column_id)

        moved =
          card
          |> Ecto.Changeset.change(
            board_id: to_board.id,
            column_id: to_column.id,
            position: next_position(from(c in Card, where: c.column_id == ^to_column.id))
          )
          |> Repo.update!()

        if board_ids != [] and from_root != to_root do
          from(b in Board, where: b.id in ^board_ids)
          # The owner too: a sub-board's own `owner_id` is what makes somebody
          # its owner, and the mover keeping that after the destination's
          # owner has revoked their access would be a door left open.
          |> Repo.update_all(set: [root_id: to_root, owner_id: to_owner])
        end

        if from_root == to_root do
          empty_move_summary(moved)
        else
          card_ids = [moved.id | subtree_card_ids(board_ids)]

          %{
            card: moved,
            tags_created: remap_tags(card_ids, to_root),
            fields_dropped: remap_field_values(card_ids, to_root),
            milestones_unpinned: unpin_milestones(card_ids)
          }
        end
      end)

    moved = Repo.get!(Card, card.id)

    log(
      Repo,
      from_board.id,
      nil,
      "card",
      "moved “#{card.title}” to #{to_board.name} › #{to_column.name}"
    )

    log(
      Repo,
      to_board.id,
      moved.id,
      "card",
      "moved “#{card.title}” in from #{from_board.name} › #{from_column.name}"
    )

    apply_column_semantics(moved, from_column, to_column)

    # The board a chunk records is what decides who may search it up, so the
    # moved card and everything beneath it are corrected inline rather than
    # waiting in the queue — then queued, to catch up the text as well.
    Slipdock.Search.relocate_card(moved.id)
    Indexer.enqueue_all(Slipdock.Search.subtree_card_ids(moved.id))

    automate(%{
      type: "card_moved",
      card: Repo.get!(Card, moved.id),
      from: from_column,
      to: to_column,
      column: to_column
    })

    broadcast(from_board.id)
    broadcast(to_board.id)
    {:ok, %{summary | card: Repo.get!(Card, moved.id)}}
  end

  defp empty_move_summary(card),
    do: %{card: card, tags_created: 0, fields_dropped: 0, milestones_unpinned: 0}

  @doc "The ids of every board beneath `card_id`, however deep."
  def subtree_board_ids(card_id) do
    case Repo.all(from(b in Board, where: b.parent_card_id == ^card_id, select: b.id)) do
      [] ->
        []

      ids ->
        deeper = ids |> subtree_card_ids() |> Enum.flat_map(&subtree_board_ids/1)
        ids ++ deeper
    end
  end

  defp subtree_card_ids([]), do: []

  defp subtree_card_ids(board_ids),
    do: Repo.all(from(c in Card, where: c.board_id in ^board_ids, select: c.id))

  # Tags belong to a tree, so a moved card's tags are the wrong rows on the
  # far side. Match on the name, case aside; make the ones that are new.
  defp remap_tags(card_ids, to_root) do
    joins =
      Repo.all(
        from(ct in "card_tags", where: ct.card_id in ^card_ids, select: {ct.card_id, ct.tag_id})
      )

    if joins == [] do
      0
    else
      old = Repo.all(from(t in Tag, where: t.id in ^Enum.map(joins, &elem(&1, 1))))
      by_id = Map.new(old, &{&1.id, &1})
      existing = to_root |> list_tags() |> Map.new(&{String.downcase(&1.name), &1})

      {created, by_name} =
        Enum.reduce(old, {0, existing}, fn tag, {n, acc} ->
          key = String.downcase(tag.name)

          case acc[key] do
            nil ->
              {:ok, made} =
                %Tag{}
                |> Tag.changeset(%{
                  "name" => tag.name,
                  "color" => tag.color,
                  "board_id" => to_root
                })
                |> Repo.insert()

              {n + 1, Map.put(acc, key, made)}

            _ ->
              {n, acc}
          end
        end)

      Repo.delete_all(from(ct in "card_tags", where: ct.card_id in ^card_ids))

      rows =
        for {card_id, tag_id} <- joins,
            tag = by_id[tag_id],
            replacement = by_name[String.downcase(tag.name)],
            uniq: true,
            do: %{card_id: card_id, tag_id: replacement.id}

      Repo.insert_all("card_tags", rows)
      created
    end
  end

  # Field definitions belong to a tree too. A value survives where the
  # destination has a field with the same key and kind; anything else would
  # be putting a number in a date.
  defp remap_field_values(card_ids, to_root) do
    values =
      Repo.all(
        from(v in FieldValue,
          join: f in FieldDefinition,
          on: f.id == v.field_id,
          where: v.card_id in ^card_ids,
          select: {v, f.key, f.kind}
        )
      )

    targets =
      to_root
      |> Slipdock.Fields.list_fields()
      |> Map.new(&{{&1.key, &1.kind}, &1})

    Enum.reduce(values, 0, fn {value, key, kind}, dropped ->
      case targets[{key, kind}] do
        nil ->
          Repo.delete(value)
          dropped + 1

        field ->
          value |> Ecto.Changeset.change(field_id: field.id) |> Repo.update!()
          dropped
      end
    end)
  end

  # A milestone is a date on the old tree's roadmap; the card is leaving it.
  defp unpin_milestones(card_ids) do
    {n, _} =
      from(m in Milestone, where: m.card_id in ^card_ids) |> Repo.update_all(set: [card_id: nil])

    n
  end

  ## Ordering a list ----------------------------------------------------------
  #
  # A list holds cards and, sometimes, wiki pages placed on the board (see
  # `Slipdock.Wiki.place/3`). They share one position sequence so the two
  # interleave: a document that had to sit after every card would not really
  # be on the board. Everything below therefore works on **refs** —
  # `{:card, id}` or `{:page, id}` — rather than bare card ids.

  @typedoc "A thing that can sit in a list: a card, or a wiki page placed on the board."
  @type item_ref :: {:card, integer} | {:page, integer}

  @doc """
  Moves one item into a list, before another item (or to the end), repacking
  both the list it left and the one it joined.

  `before` may be a ref, a bare card id, or the `"page-7"` form the board's
  drag-and-drop sends back.
  """
  @spec reorder(item_ref, integer | nil, integer, term) :: :ok
  def reorder(ref, from_column_id, to_column_id, before \\ nil) do
    same_column? = from_column_id == to_column_id
    before_ref = item_ref(before)

    Repo.transaction(fn ->
      from_items = if from_column_id, do: active_items(from_column_id), else: []
      to_items = if same_column?, do: from_items, else: active_items(to_column_id)

      from_items = List.delete(from_items, ref)
      to_items = insert_before(List.delete(to_items, ref), ref, before_ref)

      unless same_column?, do: repack(from_items, from_column_id)
      repack(to_items, to_column_id)
    end)

    :ok
  end

  @doc """
  Reads the `id` a board's drag-and-drop sends back. Cards send their number
  as they always have; a placed page sends `"page-7"`, so an older client can
  never accidentally move a page.
  """
  @spec item_ref(term) :: item_ref | nil
  def item_ref(nil), do: nil
  def item_ref(""), do: nil
  def item_ref({kind, id}) when kind in [:card, :page] and is_integer(id), do: {kind, id}
  def item_ref(id) when is_integer(id), do: {:card, id}

  def item_ref("page-" <> id) do
    case Integer.parse(id) do
      {id, ""} -> {:page, id}
      _ -> nil
    end
  end

  def item_ref(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> {:card, id}
      _ -> nil
    end
  end

  def item_ref(_), do: nil

  @doc """
  Closes a list's order up after something has left it, so positions stay a
  dense 0..n rather than developing gaps.
  """
  @spec repack_column(integer | nil) :: :ok
  def repack_column(nil), do: :ok

  def repack_column(column_id) do
    repack(active_items(column_id), column_id)
    :ok
  end

  @doc "What a list holds, in order: its cards and any wiki pages placed in it."
  @spec active_items(integer) :: [item_ref]
  def active_items(column_id) do
    cards =
      from(c in Card,
        where: c.column_id == ^column_id and is_nil(c.archived_at),
        select: {c.position, c.id, 0}
      )
      |> Repo.all()
      |> Enum.map(fn {position, id, _} -> {position, 0, {:card, id}} end)

    pages =
      from(p in Slipdock.Wiki.Page,
        where: p.column_id == ^column_id and is_nil(p.archived_at),
        select: {p.board_position, p.id}
      )
      |> Repo.all()
      |> Enum.map(fn {position, id} -> {position, 1, {:page, id}} end)

    # Ties break cards-first, then by id, so the order is stable whatever
    # order the two queries came back in.
    (cards ++ pages) |> Enum.sort() |> Enum.map(&elem(&1, 2))
  end

  defp repack(refs, column_id) do
    refs
    |> Enum.with_index()
    |> Enum.each(fn
      {{:card, id}, i} ->
        from(c in Card, where: c.id == ^id)
        |> Repo.update_all(set: [position: i, column_id: column_id])

      {{:page, id}, i} ->
        from(p in Slipdock.Wiki.Page, where: p.id == ^id)
        |> Repo.update_all(set: [board_position: i, column_id: column_id])
    end)
  end

  ## Dependencies

  @doc """
  Records that `blocked` can't proceed until `blocker` is done. Both cards
  must be on the same board, distinct, and the link must not create a cycle.
  """
  def add_dependency(%Card{} = blocked, %Card{} = blocker) do
    cond do
      blocked.id == blocker.id ->
        {:error, "A card can't depend on itself."}

      blocked.board_id != blocker.board_id ->
        {:error, "Both cards must be on the same board."}

      dependency_exists?(blocked.id, blocker.id) ->
        {:error, "That dependency already exists."}

      reachable?(blocked.id, blocker.id) ->
        {:error,
         "That would create a circular dependency: “#{blocker.title}” already depends on “#{blocked.title}”."}

      true ->
        Repo.insert_all("card_dependencies", [%{blocked_id: blocked.id, blocker_id: blocker.id}])

        log(
          Repo,
          blocked.board_id,
          blocked.id,
          "card",
          "made “#{blocked.title}” depend on “#{blocker.title}”"
        )

        broadcast(blocked.board_id)
        {:ok, get_card!(blocked.id)}
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
      log(
        Repo,
        a.board_id,
        a.id,
        "card",
        "removed the dependency between “#{a.title}” and “#{b.title}”"
      )

      broadcast(a.board_id)
    end

    {:ok, get_card!(a.id)}
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

  ## Links

  @doc """
  Links `from` to `to` with `kind` (see `Slipdock.Boards.CardLink`). Cards may
  be on any boards. A "relates" link is symmetric, so one in either
  direction is enough.
  """
  def add_link(%Card{} = from, %Card{} = to, kind) when is_binary(kind) do
    cond do
      from.id == to.id ->
        {:error, "A card can't link to itself."}

      kind not in CardLink.kind_keys() ->
        {:error, "Unknown link kind."}

      kind == "relates" and link_exists?(to.id, from.id, kind) ->
        {:error, "Those cards are already related."}

      link_exists?(from.id, to.id, kind) ->
        {:error, "That link already exists."}

      true ->
        %CardLink{from_id: from.id, to_id: to.id}
        |> CardLink.changeset(%{"kind" => kind})
        |> Repo.insert()
        |> case do
          {:ok, link} ->
            log(
              Repo,
              from.board_id,
              from.id,
              "link",
              "linked “#{from.title}” — #{String.downcase(CardLink.label(kind, :out))} “#{to.title}”"
            )

            broadcast(from.board_id)
            if to.board_id != from.board_id, do: broadcast(to.board_id)
            {:ok, link}

          {:error, _} ->
            {:error, "Couldn't add that link."}
        end
    end
  end

  defp link_exists?(from_id, to_id, kind) do
    Repo.exists?(
      from(l in CardLink, where: l.from_id == ^from_id and l.to_id == ^to_id and l.kind == ^kind)
    )
  end

  def get_link!(id), do: CardLink |> Repo.get!(id) |> Repo.preload([:from, :to])

  def remove_link(%CardLink{} = link) do
    link = Repo.preload(link, [:from, :to])

    Repo.delete(link)
    |> tap_ok(fn _ ->
      log(
        Repo,
        link.from.board_id,
        link.from_id,
        "link",
        "unlinked “#{link.from.title}” from “#{link.to.title}”"
      )

      broadcast(link.from.board_id)
      if link.to.board_id != link.from.board_id, do: broadcast(link.to.board_id)
    end)
  end

  @doc """
  Active cards whose title matches `q` on any board of the trees rooted at
  `root_ids`, excluding `except` ids, with their board.
  """
  def search_cards_across(root_ids, q, except \\ [], limit \\ 8) when is_list(root_ids) do
    like = "%#{String.replace(q, ["%", "_"], &"\\#{&1}")}%"

    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where: (b.id in ^root_ids or b.root_id in ^root_ids) and is_nil(c.archived_at),
      where: ilike(c.title, ^like) and c.id not in ^except,
      order_by: [asc: c.title],
      limit: ^limit,
      preload: [board: b]
    )
    |> Repo.all()
  end

  @doc "Active cards on the board whose title matches `q`, excluding `except` ids."
  def search_cards(board_id, q, except \\ [], limit \\ 8) do
    like = "%" <> String.downcase(String.trim(q)) <> "%"

    from(c in Card,
      where: c.board_id == ^board_id and is_nil(c.archived_at) and c.id not in ^except,
      where: like(fragment("lower(?)", c.title), ^like),
      order_by: [asc: c.completed, asc: c.title],
      limit: ^limit,
      select: [:id, :title, :completed, :column_id]
    )
    |> Repo.all()
  end

  ## Tags

  def list_tags(root_id) do
    Repo.all(from(t in Tag, where: t.board_id == ^root_id, order_by: [asc: t.name]))
  end

  # Tags belong to the root of the board tree so sub-boards share them.
  def create_tag(%Board{} = board, attrs) do
    root_id = Board.root_id(board)

    %Tag{board_id: root_id}
    |> Tag.changeset(Map.put(attrs, "board_id", root_id))
    |> Repo.insert()
    |> tap_ok(&broadcast_tree(&1.board_id))
  end

  def update_tag(%Tag{} = tag, attrs) do
    tag |> Tag.changeset(attrs) |> Repo.update() |> tap_ok(&broadcast_tree(&1.board_id))
  end

  def delete_tag(%Tag{} = tag) do
    Repo.delete(tag) |> tap_ok(&broadcast_tree(&1.board_id))
  end

  def get_tag!(id), do: Repo.get!(Tag, id)

  def toggle_card_tag(%Card{} = card, %Tag{} = tag) do
    card = Repo.preload(card, :tags)

    tags =
      if Enum.any?(card.tags, &(&1.id == tag.id)),
        do: Enum.reject(card.tags, &(&1.id == tag.id)),
        else: card.tags ++ [tag]

    card
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:tags, tags)
    |> Repo.update()
    |> tap_ok(&automate_tags_added(&1, card.tags, tags))
    |> tap_ok(&broadcast(&1.board_id))
  end

  ## Saved views

  def get_saved_view!(id), do: Repo.get!(SavedView, id)

  @doc "Finds a saved view on `board` by id or (case-insensitive) name."
  def find_saved_view(%Board{id: board_id}, ref) do
    ref = to_string(ref)

    query =
      case Integer.parse(ref) do
        {id, ""} ->
          from(v in SavedView, where: v.board_id == ^board_id and v.id == ^id)

        _ ->
          name = String.downcase(String.trim(ref))

          from(v in SavedView,
            where: v.board_id == ^board_id and fragment("lower(?)", v.name) == ^name
          )
      end

    case Repo.one(from(q in query, limit: 1)) do
      nil -> {:error, :not_found}
      view -> {:ok, view}
    end
  end

  def list_saved_views(board_id) do
    Repo.all(from(v in SavedView, where: v.board_id == ^board_id, order_by: [asc: v.name]))
  end

  def create_saved_view(%Board{} = board, attrs) do
    %SavedView{board_id: board.id}
    |> SavedView.changeset(Map.put(attrs, "board_id", board.id))
    |> Repo.insert()
    |> tap_ok(fn v ->
      log(Repo, board.id, nil, "view", "saved view “#{v.name}”")
      broadcast(board.id)
    end)
  end

  def update_saved_view(%SavedView{} = view, attrs) do
    view
    |> SavedView.changeset(attrs)
    |> Repo.update()
    |> tap_ok(&broadcast(&1.board_id))
  end

  def delete_saved_view(%SavedView{} = view) do
    Repo.delete(view)
    |> tap_ok(fn v ->
      log(Repo, v.board_id, nil, "view", "deleted view “#{v.name}”")
      broadcast(v.board_id)
    end)
  end

  def change_saved_view(%SavedView{} = view, attrs \\ %{}), do: SavedView.changeset(view, attrs)

  @doc "Gives the view a public token so anyone with the link can read it."
  def publish_saved_view(%SavedView{} = view) do
    token = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

    view
    |> Ecto.Changeset.change(public_token: token)
    |> Repo.update()
    |> tap_ok(&broadcast(&1.board_id))
  end

  @doc "Withdraws the view's public link."
  def unpublish_saved_view(%SavedView{} = view) do
    view
    |> Ecto.Changeset.change(public_token: nil)
    |> Repo.update()
    |> tap_ok(&broadcast(&1.board_id))
  end

  @doc "The published view with that token, with its board, or nil."
  def get_published_view(token) when is_binary(token) do
    case Repo.get_by(SavedView, public_token: token) do
      nil -> nil
      view -> %{view | board: get_board!(view.board_id)}
    end
  end

  def get_published_view(_), do: nil

  ## Milestones

  @doc "The milestones of the tree rooted at `root_id`, by date."
  def list_milestones(root_id) do
    Repo.all(
      from(m in Milestone, where: m.board_id == ^root_id, order_by: [asc: m.date, asc: m.id])
    )
  end

  def get_milestone!(id), do: Repo.get!(Milestone, id)

  @doc "Adds a milestone to the tree `board` belongs to."
  def create_milestone(%Board{} = board, attrs) do
    root_id = Board.root_id(board)

    %Milestone{board_id: root_id}
    |> Milestone.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn m ->
      log(Repo, root_id, m.card_id, "milestone", "added milestone “#{m.name}” on #{m.date}")
      broadcast_tree(root_id)
    end)
  end

  def update_milestone(%Milestone{} = milestone, attrs) do
    milestone
    |> Milestone.changeset(attrs)
    |> Repo.update()
    |> tap_ok(fn m ->
      log(Repo, m.board_id, m.card_id, "milestone", "updated milestone “#{m.name}” (#{m.date})")
      broadcast_tree(m.board_id)
    end)
  end

  def delete_milestone(%Milestone{} = milestone) do
    Repo.delete(milestone)
    |> tap_ok(fn m ->
      log(Repo, m.board_id, nil, "milestone", "removed milestone “#{m.name}”")
      broadcast_tree(m.board_id)
    end)
  end

  def change_milestone(%Milestone{} = m, attrs \\ %{}), do: Milestone.changeset(m, attrs)

  ## Status updates

  @doc """
  Records what `user` believes about the health of a card or a wiki page,
  with an optional note. A spec can be off track as surely as the work can.
  """
  def add_status_update(owner, user, attrs) do
    %StatusUpdate{user_id: user && user.id}
    |> struct!(owned_by(owner))
    |> StatusUpdate.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn u ->
      Slipdock.Wiki.Links.reconcile_status(u)
      note = if u.body, do: ": #{String.slice(u.body, 0, 120)}", else: ""

      log_owned(
        owner,
        "status",
        "reported “#{owner.title}” #{String.downcase(StatusUpdate.health_label(u.health))}#{note}"
      )

      broadcast_tree(root_of(owner.board_id))
      notify_owned(owner)
    end)
  end

  def delete_status_update(id) do
    update = Repo.get!(StatusUpdate, id)
    owner = owner_of(update)

    Repo.delete(update)
    |> tap_ok(fn _ ->
      broadcast_tree(root_of(owner.board_id))
      notify_owned(owner)
    end)
  end

  @doc "The latest stated health per card id, for the given cards."
  def latest_stated_health(card_ids) when is_list(card_ids) do
    from(u in StatusUpdate,
      where: u.card_id in ^card_ids,
      order_by: [desc: u.inserted_at, desc: u.id],
      select: {u.card_id, u.health}
    )
    |> Repo.all()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Map.new()
  end

  @doc "The latest stated health per page id, for the given pages."
  def latest_stated_health_for_pages(page_ids) when is_list(page_ids) do
    from(u in StatusUpdate,
      where: u.page_id in ^page_ids,
      order_by: [desc: u.inserted_at, desc: u.id],
      select: {u.page_id, u.health}
    )
    |> Repo.all()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Map.new()
  end

  @doc "The root board id of the tree `board_id` belongs to."
  def root_of_board(board_id), do: root_of(board_id)

  @doc false
  def log_activity(board_id, card_id, kind, message),
    do: log(Repo, board_id, card_id, kind, message)

  @doc "An activity line about a card or a wiki page, whichever it is given."
  def log_activity_for(owner, kind, message), do: log_owned(owner, kind, message)

  defp root_of(board_id) do
    case Repo.get!(Board, board_id) do
      %Board{root_id: nil, id: id} -> id
      %Board{root_id: root_id} -> root_id
    end
  end

  ## Automations

  # Every change this context makes is offered to `Slipdock.Automations`, which
  # runs the rules whose trigger matches. Rules change cards in turn, so this
  # is re-entrant by design; the guard against rules chasing each other round
  # in circles lives there.
  defp automate(event), do: Slipdock.Automations.dispatch(event)

  # One update can be several events: the fields that changed, plus the ones
  # worth a trigger of their own (completing, reopening, assigning, flagging).
  defp automate_card_changes(before, card, changeset, {was_assigned, now_assigned}) do
    changes = changeset.changes
    newly_assigned = now_assigned -- was_assigned
    fields = changed_fields(changes)

    fields =
      if Enum.sort(was_assigned) != Enum.sort(now_assigned) and "assignee" not in fields,
        do: fields ++ ["assignee"],
        else: fields

    automate(%{type: "card_updated", card: card, fields: fields})

    case changes[:completed] do
      true -> automate(%{type: "card_completed", card: card})
      false -> automate(%{type: "card_reopened", card: card})
      _ -> :ok
    end

    # Once for each person newly on the card, so a rule waiting for "assigned
    # to Sam" fires when Sam joins, whoever else is already there.
    for id <- newly_assigned, user = Repo.get(User, id) do
      automate(%{type: "card_assigned", card: card, assignee: user})
    end

    for flag <- List.wrap(changes[:flags]) -- before.flags do
      automate(%{type: "flag_added", card: card, flag: flag})
    end
  end

  # The names a rule's "card_updated" trigger uses for the fields.
  defp changed_fields(changes) do
    Enum.flat_map(changes, fn
      {:assignee_id, _} -> ["assignee"]
      {:column_id, _} -> ["column"]
      {field, _} when field in @automatable_fields -> [Atom.to_string(field)]
      _ -> []
    end)
  end

  defp automate_tags_added(card, before, now) do
    previous = MapSet.new(before, & &1.id)

    for tag <- now, not MapSet.member?(previous, tag.id) do
      automate(%{type: "tag_added", card: card, tag: tag.name})
    end
  end

  ## Checklist

  @doc "Adds a tick box to a card or to a wiki page."
  def add_checklist_item(owner, text) do
    position = next_position(where(ChecklistItem, ^owned_clause(owner)))

    %ChecklistItem{position: position}
    |> struct!(owned_by(owner))
    |> ChecklistItem.changeset(%{"text" => text})
    |> Repo.insert()
    |> tap_ok(fn _ -> notify_owned(owner) end)
  end

  @doc "A tick box on `owner` (a card or a page), or nil if it is not one of its own."
  def get_checklist_item(owner, id), do: get_owned(ChecklistItem, owner, id)

  def toggle_checklist_item(%ChecklistItem{} = item) do
    item
    |> Ecto.Changeset.change(done: !item.done)
    |> Repo.update()
    |> tap_ok(fn _ -> notify_owned(owner_of(item)) end)
  end

  def toggle_checklist_item(id), do: toggle_checklist_item(Repo.get!(ChecklistItem, id))

  def delete_checklist_item(%ChecklistItem{} = item) do
    Repo.delete(item)
    |> tap_ok(fn _ -> notify_owned(owner_of(item)) end)
  end

  def delete_checklist_item(id), do: delete_checklist_item(Repo.get!(ChecklistItem, id))

  ## Comments

  @doc """
  Comments on a card or on a wiki page. `opts[:by]` is who wrote it, when
  known; anybody it `@mentions` on a card is told (see `Slipdock.Mentions`).
  """
  def add_comment(owner, body, opts \\ []) do
    %Comment{}
    |> struct!(owned_by(owner))
    |> Comment.changeset(%{"body" => body})
    |> Repo.insert()
    |> tap_ok(fn comment ->
      log_owned(owner, "comment", "commented on “#{owner.title}”")
      # A comment is writing too: "see [[Retry policy]]" belongs in that
      # page's backlinks (see `Slipdock.Wiki.Links`).
      Slipdock.Wiki.Links.reconcile_comment(comment)
      notify_owned(owner)
      # Automations are about work, so a comment on a page does not run them.
      if match?(%Card{}, owner) do
        Slipdock.Mentions.comment_added(owner, comment.body, opts[:by])
        automate(%{type: "comment_added", card: owner, comment: comment.body})
      end
    end)
  end

  @doc "A comment on `owner` (a card or a page), or nil if it is not one of its own."
  def get_comment(owner, id), do: get_owned(Comment, owner, id)

  def delete_comment(%Comment{} = comment) do
    Repo.delete(comment)
    |> tap_ok(fn _ -> notify_owned(owner_of(comment)) end)
  end

  def delete_comment(id), do: delete_comment(Repo.get!(Comment, id))

  ## Attachments

  @doc "The directory uploaded files are stored in (see `:uploads_dir` in config)."
  def uploads_dir do
    Application.get_env(:slipdock, :uploads_dir) ||
      Path.join(:code.priv_dir(:slipdock), "uploads")
  end

  @doc "The absolute path of an attachment's file on disk."
  def attachment_path(%Attachment{key: key}), do: Path.join(uploads_dir(), key)

  def get_attachment!(id), do: Attachment |> Repo.get!(id) |> Repo.preload([:card, :page])

  @doc """
  Attaches a file to the card. `meta` names the file (`:filename`,
  `:content_type`, and optionally `:size`); `source` is the path of the
  uploaded bytes, which are copied into the uploads directory.
  """
  def add_attachment(%Card{} = card, meta, source) do
    with {:ok, attachment} <-
           store_attachment(%{card_id: card.id}, Integer.to_string(card.id), meta, source) do
      log(
        Repo,
        card.board_id,
        card.id,
        "attachment",
        "attached #{attachment.filename} to “#{card.title}”"
      )

      broadcast(card.board_id)
      {:ok, attachment}
    end
  end

  @doc """
  Puts an uploaded file on disk and records it, whatever it hangs off.

  `owner` is `%{card_id: id}` or `%{page_id: id}`; `folder` is the directory
  under the uploads root the bytes go in. Shared so the wiki's paste-an-image
  is the same code path as a card's, rather than a second one to keep honest.
  """
  def store_attachment(owner, folder, meta, source) when is_map(owner) do
    ext = meta |> Map.get(:filename, "") |> Path.extname() |> String.downcase() |> safe_ext()
    key = Path.join(folder, Ecto.UUID.generate() <> ext)
    size = Map.get(meta, :size) || File.stat!(source).size
    scope = attachment_scope(owner)

    changeset =
      Attachment.changeset(
        struct(Attachment, owner),
        Map.merge(owner, %{
          filename: meta[:filename],
          content_type: meta[:content_type],
          size: size,
          key: key
        })
      )
      # An upload is both a thing stored and bytes on a disk, so it is checked
      # against both limits before a single byte is copied anywhere.
      |> Quota.enforce(scope, :items)
      |> Quota.enforce(scope, :storage, want: size)

    with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- store_file(source, key),
         {:ok, attachment} <- Repo.insert(changeset) do
      {:ok, attachment}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}

      {:error, reason} ->
        {:error,
         Ecto.Changeset.add_error(changeset, :key, "could not be stored: #{inspect(reason)}")}
    end
  end

  # Which board's owner pays for this file: the card's, or the page's.
  defp attachment_scope(%{card_id: card_id}) when not is_nil(card_id),
    do: Repo.one(from(c in Card, where: c.id == ^card_id, select: c.board_id))

  defp attachment_scope(%{page_id: page_id}) when not is_nil(page_id),
    do: Repo.one(from(p in Slipdock.Wiki.Page, where: p.id == ^page_id, select: p.board_id))

  defp attachment_scope(_owner), do: nil

  def delete_attachment(%Attachment{} = attachment) do
    attachment = Repo.preload(attachment, [:card, :page])

    Repo.delete(attachment)
    |> tap_ok(fn a ->
      remove_files([a.key])

      case attachment do
        %Attachment{card: %Card{board_id: board_id}} -> broadcast(board_id)
        %Attachment{page: %{board_id: board_id}} -> broadcast(board_id)
        _ -> :ok
      end
    end)
  end

  ## External links ----------------------------------------------------------

  @doc """
  Puts a link to somewhere outside the system on a card. `attrs` carries the
  `url` and an optional `title`; the datestamp is the row's own `inserted_at`.
  """
  def add_card_url(owner, attrs) do
    %CardUrl{}
    |> struct!(owned_by(owner))
    |> CardUrl.changeset(stringify(attrs))
    |> Repo.insert()
    |> tap_ok(fn url ->
      log_owned(owner, "link", "linked “#{owner.title}” to #{url.url}")
      broadcast(owner.board_id)
    end)
  end

  def get_card_url!(id), do: CardUrl |> Repo.get!(id) |> Repo.preload([:card, :page])

  def delete_card_url(%CardUrl{} = url) do
    owner = owner_of(url)

    Repo.delete(url)
    |> tap_ok(fn _ ->
      log_owned(owner, "link", "unlinked #{url.url} from “#{owner.title}”")
      broadcast(owner.board_id)
    end)
  end

  # Params reach us as atoms from Elixir and strings from the wire.
  defp stringify(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  @doc "The public path an attachment is served from."
  def attachment_url(%Attachment{} = a), do: "/attachments/#{a.id}/#{URI.encode(a.filename)}"

  defp store_file(source, key) do
    dest = Path.join(uploads_dir(), key)

    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, _} <- File.copy(source, dest) do
      :ok
    end
  end

  defp attachment_keys(query), do: Repo.all(from(a in query, select: a.key))

  @doc """
  The on-disk keys of every file on the boards `boards` selects — cards' and
  wiki pages' alike. Read them before the rows go, and hand them to
  `remove_files/1` once the delete has committed: the database cascades take
  the rows, but nothing takes the bytes.
  """
  def file_keys(%Ecto.Query{} = boards) do
    ids = from(b in subquery(boards), select: b.id)

    attachment_keys(
      from(a in Attachment,
        left_join: c in assoc(a, :card),
        left_join: p in assoc(a, :page),
        where: c.board_id in subquery(ids) or p.board_id in subquery(ids)
      )
    )
  end

  @doc "Removes uploaded files by key, and any folder they leave empty."
  def remove_files(keys) do
    dir = uploads_dir()

    Enum.each(keys, fn key ->
      path = Path.join(dir, key)
      File.rm(path)
      # Drop the card's folder once it's empty.
      File.rmdir(Path.dirname(path))
    end)
  end

  # Only keep a short, plain extension so the on-disk name is predictable.
  defp safe_ext(ext) do
    if Regex.match?(~r/^\.[a-z0-9]{1,8}$/, ext), do: ext, else: ""
  end

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

  def list_activities(board_id, limit \\ 50) do
    from(a in Activity,
      where: a.board_id == ^board_id,
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp log(repo, board_id, card_id, kind, message) do
    repo.insert(%Activity{board_id: board_id, card_id: card_id, kind: kind, message: message})
  end

  ## Cards and pages, together -----------------------------------------------
  #
  # Comments, status updates, checklist items and web links hang off a card
  # *or* off a wiki page — one table each, one row belonging to exactly one
  # of the two, with the database saying so (see `Slipdock.Boards.Owned`). The
  # writers above take whichever; these three route the side effects.

  # The owner's foreign key, ready to `struct!` onto a new row.
  defp owned_by(owner), do: Owned.owner_key(owner)

  # An activity line about a card or a page.
  defp log_owned(owner, kind, message) do
    Repo.insert(
      struct!(
        %Activity{board_id: owner.board_id, kind: kind, message: message},
        owned_by(owner)
      )
    )
  end

  # Tell the board, and re-index. A page is indexed by its own chunker, so
  # the Page clause has to come first: `Indexer.enqueue/1` matches any struct.
  defp notify_owned(%Slipdock.Wiki.Page{} = page) do
    broadcast(page.board_id)
    Indexer.enqueue_page(page)
  end

  defp notify_owned(%Card{} = card) do
    broadcast(card.board_id)
    Indexer.enqueue(card)
  end

  # The card or page a row hangs off, loaded.
  defp owner_of(%{card_id: id}) when is_integer(id), do: Repo.get!(Card, id)
  defp owner_of(%{page_id: id}) when is_integer(id), do: Repo.get!(Slipdock.Wiki.Page, id)

  ## Helpers

  # `where` for "the rows belonging to this card or this page".
  defp owned_clause(%Slipdock.Wiki.Page{id: id}), do: dynamic([r], r.page_id == ^id)
  defp owned_clause(%{id: id}), do: dynamic([r], r.card_id == ^id)

  # A row of `schema` by a client's id, only if it hangs off `owner`.
  defp get_owned(_schema, nil, _id), do: nil

  defp get_owned(schema, owner, id) do
    case to_id(id) do
      nil -> nil
      id -> Repo.one(from(r in schema, where: r.id == ^id, where: ^owned_clause(owner)))
    end
  end

  defp next_position(query) do
    case Repo.one(from(q in query, select: max(q.position))) do
      nil -> 0
      max -> max + 1
    end
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other
end
