defmodule Slipdock.Boards do
  @moduledoc """
  The Boards context: boards and sub-boards, made, found, changed and
  deleted, with the switcher keys and codes they go by.

  The rest of what lives on a board has a context of its own beside this one
  (a split of what was one module, #2787):

  - `Boards.PubSub`: the board topics, and telling open pages a board changed
  - `Boards.Arrangement`: archiving boards and the order they are listed in
  - `Boards.Templates`: board templates
  - `Boards.Columns`: lists, and the order of the cards and pages in one
  - `Boards.Cards`: cards, and `Boards.CardEvents`, the automations their changes fire
  - `Boards.Moves`: moving a card to another board, and the movement ledger
  - `Boards.Dependencies` and `Boards.Links`: how cards relate to each other
  - `Boards.Tags`, `Boards.SavedViews`, `Boards.Milestones`
  - `Boards.StatusUpdates`, `Boards.Handoffs`, `Boards.Waits`
  - `Boards.Checklists`, `Boards.Comments`, `Boards.Attachments`, `Boards.CardUrls`
  - `Boards.ActivityLog`: the activity log

  Every mutation broadcasts `{:board_changed, board_id}` on the board's
  PubSub topic so open LiveViews refresh.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.Column
  alias Slipdock.Boards.Tag
  alias Slipdock.Boards.Template
  alias Slipdock.CardState
  alias Slipdock.Importers
  alias Slipdock.Quota
  alias Slipdock.Repo
  alias Slipdock.Rollup
  alias Slipdock.Wiki.Changes

  @default_columns [
    %{"name" => "Backlog", "category" => "todo"},
    %{"name" => "To Do", "category" => "todo"},
    %{"name" => "In Progress", "category" => "doing"},
    %{"name" => "Done", "category" => "done"}
  ]

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

  @doc """
  `:ok` when `ref` names a column on `board` (or is nil), otherwise an error
  naming the board's columns. For listings: `list_cards/2` answers an unknown
  column with no cards, which reads exactly like an empty list (#1005).
  """
  def check_column(_board, nil), do: :ok

  def check_column(%Board{id: board_id} = board, ref) do
    case find_column(board, ref) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        names =
          Repo.all(
            from(c in Column,
              where: c.board_id == ^board_id,
              order_by: c.position,
              select: c.name
            )
          )

        {:error,
         "no list \"#{ref}\" on this board; its lists are: #{Enum.join(names, ", ")} " <>
           "(a name or an id of one of them)"}
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
      columns: [cards: {active_cards_query(), Boards.Cards.card_preloads()}],
      saved_views: [],
      parent_card: [],
      template: [],
      owner: []
    )
    |> Map.put(:tags, Boards.Tags.list_tags(Board.root_id(board)))
    |> Map.put(:milestones, Boards.Milestones.list_milestones(Board.root_id(board)))
    |> Map.put(:fields, Slipdock.Fields.list_fields(Board.root_id(board)))
    |> put_rollup(Rollup.build(Board.root_id(board)))
    |> put_computed()
    |> put_placed_pages()
    |> put_snoozed()
    |> put_usual_stays()
    |> put_states()
  end

  # One aggregate over the movement ledger for every list at once (#1113).
  defp put_usual_stays(%Board{} = board),
    do: %{board | usual_stays: Slipdock.Pulse.usual_stays(board)}

  @doc """
  Every card on a loaded `board`, the snoozed ones too, with its state
  worked out again (`Slipdock.CardState`): a handful of queries for the
  whole board. What the board page runs when a runner moves a job along.
  """
  def put_states(%Board{columns: columns} = board) do
    cards = Enum.flat_map(columns, &(&1.cards ++ &1.snoozed))
    runner_tree = CardState.runner_tree?(Board.root_id(board))

    by_id =
      cards
      |> CardState.put(board,
        usual: board.usual_stays,
        columns: columns,
        runner_tree: runner_tree
      )
      |> Map.new(&{&1.id, &1})

    restate = fn list -> Enum.map(list, &Map.get(by_id, &1.id, &1)) end

    %{
      board
      | runner_tree: runner_tree,
        columns:
          Enum.map(columns, &%{&1 | cards: restate.(&1.cards), snoozed: restate.(&1.snoozed)})
    }
  end

  @doc "One card with its state worked out (`Slipdock.CardState`), for a card read on its own."
  def with_state(%Card{} = card) do
    [card] = CardState.put([card], Repo.get!(Board, card.board_id))
    card
  end

  # Snoozed cards (W-1803) leave the lists for the list's `snoozed`, after
  # they have been decorated like the rest so the footer can show them as
  # they are. A sprint keeps them in place: it is a deliberate commitment,
  # and a sprint's work hidden from it would be a sprint nobody can read.
  defp put_snoozed(%Board{} = board) do
    if sprint_tree?(board) do
      board
    else
      now = DateTime.utc_now()

      columns =
        Enum.map(board.columns, fn col ->
          {asleep, awake} = Enum.split_with(col.cards, &Card.snoozed?(&1, now))
          %{col | cards: awake, snoozed: asleep}
        end)

      %{board | columns: columns}
    end
  end

  defp sprint_tree?(%Board{root_id: nil} = board), do: Board.sprints?(board)

  defp sprint_tree?(%Board{root_id: root_id}),
    do: Repo.exists?(from(b in Board, where: b.id == ^root_id and b.kind == "sprints"))

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

  @doc """
  Dependencies, loaded as light "stubs" (no nested preloads). Each says
  whether it is `verify_released` (#1661): awaiting verification on a board
  that ships by push, so it no longer blocks (`Slipdock.Verified.released?/2`).
  Preload `blocked_by` with this wherever `Card.blocked?/1` is asked.
  """
  def dependency_query do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      select:
        struct(c, [
          :id,
          :title,
          :completed,
          :archived_at,
          :column_id,
          :board_id,
          :priority,
          :start_date,
          :due_date,
          :verify_state
        ]),
      select_merge: %{
        verify_released:
          coalesce(c.verify_state, "") == "pending" and
            not (b.ship_via == "pull_request" and b.verify_work)
      }
    )
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

  @doc """
  Creates a board. Pass `template: %Template{}` to take its lists, or
  `columns:` to set them out here (names, or maps shaped like a template's
  lists; one with no category gets one guessed from its name); otherwise the
  default four lists are created. `save_template: name` keeps the board's
  lists as a new template of that name as well, owned by the board's owner,
  in the same transaction, so a template name that is taken refuses the board too rather than leaving
  half of what was asked for. `owner_id:` says whose it is, and a root board
  must have one — an `"owner_id"` in `attrs` is ignored, since attributes
  are what forms send.
  """
  def create_board(attrs, opts \\ []) do
    template = opts[:template]
    custom = custom_columns(opts[:columns])

    columns =
      (custom || (template && template.columns) || @default_columns)
      |> without_scheduled(opts[:parent_card_id])

    attrs = attrs |> put_code() |> put_shortcut(nil, opts)

    result =
      Multi.new()
      |> Multi.insert(
        :board,
        %Board{
          template_id: template && template.id,
          kind: if(opts[:wiki], do: "wiki", else: template_kind(template, opts))
        }
        |> Board.changeset(attrs)
        |> vault_key_check()
        |> Ecto.Changeset.change(Keyword.take(opts, [:parent_card_id, :root_id, :owner_id]))
        |> validate_custom_columns(custom)
        |> enforce_board_limit()
      )
      |> Multi.run(:columns, fn repo, %{board: board} -> insert_columns(repo, board, columns) end)
      |> Multi.run(:saved, fn repo, %{board: board} ->
        save_board_template(repo, board, attrs, opts[:save_template], columns)
      end)
      |> Multi.run(:activity, fn repo, %{board: board} ->
        Boards.ActivityLog.log(repo, board.id, nil, "board", "created board “#{board.name}”")
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{saved: board}} ->
        if board.template_id && !template, do: Boards.PubSub.broadcast_templates()
        # A template may carry a documentation skeleton, folders, tags and
        # rules as well as lists, so a new board arrives with somewhere to
        # write rather than an empty wiki. The same applier builds a Tool's
        # board (see `Slipdock.Blueprint`).
        if template, do: apply_template_extras(board, template, opts[:owner_id])
        Boards.PubSub.broadcast(board.id)
        # Nobody is subscribed to a new tree yet, its owner included. A
        # Knowledge Base is on no list of boards, so nobody's needs redrawing.
        if is_nil(board.parent_card_id) and not Board.wiki?(board),
          do: Boards.PubSub.notify_users_boards_changed([board.owner_id])

        {:ok, board}

      {:error, step, changeset, _} when step in [:board, :saved] ->
        {:error, changeset}
    end
  end

  # A template's Scheduled list (#2100) is for a root board, where the
  # recurring agent work lands: an epic's or a sprint's sub-board made from
  # the same template leaves it out.
  defp without_scheduled(columns, nil), do: columns

  defp without_scheduled(columns, _parent_card_id),
    do: Enum.reject(columns, &(column_category(&1) == "scheduled"))

  defp column_category(%{"category" => category}), do: category
  defp column_category(%{category: category}), do: category
  defp column_category(_), do: nil

  defp apply_template_extras(board, template, owner_id) do
    user = owner_id && Repo.get(Slipdock.Accounts.User, owner_id)

    # The lists are already made — the template's, or the custom ones given
    # instead of them — so only the rest of the blueprint is applied.
    extras = template |> Slipdock.Blueprint.from_template() |> Map.put("lists", [])

    case Slipdock.Blueprint.apply(board, extras,
           user: user,
           message: "from the #{template.name} template"
         ) do
      {:ok, _report} ->
        :ok

      # The board stands with its lists; what the template could not add is
      # logged rather than taking the board down with it.
      {:error, message} ->
        require Logger
        Logger.warning("template #{template.id} on board #{board.id}: #{message}")
        :ok
    end
  end

  # Lists set out when the board is made, rather than taken from a template.
  # Nil when none were given; [] when some were but every name was blank,
  # which `validate_custom_columns/2` refuses.
  defp custom_columns(nil), do: nil

  defp custom_columns(columns) do
    columns
    |> Template.normalize_columns()
    |> Enum.map(
      &Map.update!(&1, "category", fn c -> c || Importers.guess_category(&1["name"]) end)
    )
  end

  defp validate_custom_columns(changeset, nil), do: changeset

  defp validate_custom_columns(changeset, []),
    do: Ecto.Changeset.add_error(changeset, :columns, "add at least one list")

  defp validate_custom_columns(changeset, columns) when length(columns) > 20,
    do: Ecto.Changeset.add_error(changeset, :columns, "can have at most 20 lists")

  defp validate_custom_columns(changeset, _), do: changeset

  # Keeps the new board's lists as a template when asked to, and points the
  # board at it. A refusal (the name is taken, or blank) is reported on the
  # board's own changeset under `save_template`, since that is the form the
  # person filled in.
  defp save_board_template(_repo, board, _attrs, name, _columns) when name in [nil, false],
    do: {:ok, board}

  defp save_board_template(repo, board, attrs, name, columns) do
    name = if name == true, do: board.name, else: to_string(name)

    %Template{owner_id: board.owner_id, system: false}
    |> Template.changeset(%{
      "name" => name,
      "description" => board.description,
      "columns" => columns
    })
    |> Boards.Templates.reserve_built_in_names(repo)
    |> repo.insert()
    |> case do
      {:ok, template} ->
        repo.update(Ecto.Changeset.change(board, template_id: template.id))

      {:error, refused} ->
        message =
          case refused.errors[:name] do
            {"already exists", _} -> "a template called “#{String.trim(name)}” already exists"
            {"can't be blank", _} -> "give the template a name"
            {message, keys} -> "template name " <> interpolate(message, keys)
            nil -> "the lists can't be saved as a template"
          end

        {:error,
         %Board{}
         |> Board.changeset(attrs)
         |> Ecto.Changeset.add_error(:save_template, message)
         |> Map.put(:action, :insert)}
    end
  end

  defp interpolate(message, keys) do
    Regex.replace(~r/%{(\w+)}/, message, fn _, key ->
      keys |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
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
      # A Knowledge Base is everybody's own, and counts against nothing.
      get.(:kind) == "wiki" -> changeset
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

  Its code comes from the card's title unless `opts[:code]` names one.
  """
  def create_sub_board(%Card{} = card, %Template{} = template, opts \\ []) do
    parent = Repo.get!(Board, card.board_id)

    if Repo.exists?(from(b in Board, where: b.parent_card_id == ^card.id)) do
      {:error, "This card already has subcards."}
    else
      case create_board(
             # A simple board's subcards are as simple as it is, and they
             # call a handoff what it does (#1212).
             %{
               "name" => Board.name_for_card(card.title),
               "code" => opts[:code],
               "color" => parent.color,
               "simple" => parent.simple,
               "handoff_label" => parent.handoff_label,
               "handoff_prompt" => parent.handoff_prompt,
               # Verified work's switches (#1620) hold for the subcards too,
               # and so does the page they are set on (#2011).
               "agentic_building" => parent.agentic_building,
               "bar_required" => parent.bar_required,
               "lanes" => parent.lanes,
               "lane_mode" => parent.lane_mode,
               "profiles" => parent.profiles,
               "shared_paths" => parent.shared_paths,
               "evidence_required" => parent.evidence_required,
               "verify_work" => parent.verify_work,
               "verify_pool" => parent.verify_pool,
               "ship_via" => parent.ship_via
             },
             template: template,
             parent_card_id: card.id,
             root_id: Board.root_id(parent),
             owner_id: parent.owner_id
           ) do
        {:ok, board} ->
          Boards.ActivityLog.log(
            Repo,
            card.board_id,
            card.id,
            "card",
            "added subcards to “#{card.title}” (#{template.name} template)"
          )

          Boards.PubSub.broadcast(card.board_id)
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

        Boards.ActivityLog.log(
          Repo,
          card.board_id,
          card.id,
          "card",
          "removed the subcards of “#{card.title}”"
        )

        Boards.PubSub.broadcast(card.board_id)
        {:ok, Boards.Cards.get_card!(card.id)}
    end
  end

  def update_board(%Board{} = board, attrs) do
    changeset =
      board
      |> Board.changeset(attrs |> put_code(board) |> put_shortcut(board))
      |> vault_key_check()

    # A root board's name is its folder's on disk, so a new one moves the lot.
    renamed? = Map.has_key?(changeset.changes, :name)

    Changes.tracking(if(renamed?, do: board.id), fn -> Repo.update(changeset) end)
    |> Boards.Shared.tap_ok(fn updated ->
      if renamed?, do: Changes.record(updated.id, "board", updated.id)
      Boards.PubSub.broadcast(updated.id)
    end)
  end

  @doc """
  Saves `board`'s wait routes (#1949), already checked by
  `Slipdock.WaitRoutes.set/2`: a question kind => user ids.
  """
  def set_wait_routes(%Board{} = board, routes) do
    board
    |> Board.wait_routes_changeset(routes)
    |> Repo.update()
    |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast(&1.id))
  end

  def delete_board(%Board{} = board) do
    keys =
      Boards.Attachments.file_keys(
        from(b in Board, where: b.id == ^board.id or b.root_id == ^board.id)
      )

    # Read before the delete: afterwards a sub-board has no parent to climb.
    chain = Boards.PubSub.ancestor_board_ids(board.id)

    Repo.delete(board)
    |> Boards.Shared.tap_ok(fn _ ->
      Boards.Attachments.remove_files(keys)
      Boards.PubSub.broadcast_chain(chain)
    end)
  end

  def change_board(%Board{} = board, attrs \\ %{}), do: Board.changeset(board, attrs)

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
    Repo.exists?(query) or claimed_elsewhere?(:code, code)
  end

  @doc """
  A board shortcut key that is free to use: `name`'s key, or the next one
  along when that is taken. Pass `except` to ignore a board's own key, so
  re-saving a board keeps the key it already has.
  """
  def suggest_shortcut(name, except \\ nil) do
    Board.shortcut_from_name(name, &shortcut_taken?(&1, except))
  end

  @doc """
  Whether a switcher key is in use. Boards and vaults share one set of keys
  (#1204), so `b` then a key never means two things. `except` is a board's id,
  or `{:vault, id}`, whose own key does not count.
  """
  def shortcut_taken?(shortcut, except \\ nil) do
    {board_id, vault_id} =
      case except do
        {:vault, id} -> {nil, id}
        id -> {id, nil}
      end

    boards = from(b in Board, where: b.shortcut == ^shortcut)
    boards = if board_id, do: from(b in boards, where: b.id != ^board_id), else: boards
    vaults = from(v in Slipdock.Vaults.Vault, where: v.shortcut == ^shortcut)
    vaults = if vault_id, do: from(v in vaults, where: v.id != ^vault_id), else: vaults

    Repo.exists?(boards) or Repo.exists?(vaults) or claimed_elsewhere?(:shortcut, shortcut)
  end

  # A key typed into a board's settings can be one a vault already has; the
  # boards' unique index cannot see that, so this does.
  defp vault_key_check(changeset) do
    with key when is_binary(key) <- Ecto.Changeset.get_change(changeset, :shortcut),
         true <-
           Repo.exists?(from(v in Slipdock.Vaults.Vault, where: v.shortcut == ^key)) do
      Ecto.Changeset.add_error(changeset, :shortcut, "is already used by a vault")
    else
      _ -> changeset
    end
  end

  # Async tests each make their boards in a transaction the others can't see,
  # so a key derived in one can be a key another has just used, and the insert
  # would then wait for that test to end. The test config names a module that
  # knows which keys running tests hold (`Slipdock.BoardKeyClaims`, #830);
  # nothing else sets it.
  defp claimed_elsewhere?(kind, value) do
    case Application.get_env(:slipdock, :board_key_claims) do
      nil -> false
      claims -> not claims.claim(kind, value)
    end
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
        # A code given by hand is held too, so a code derived from a name in
        # another running test steps around it rather than waiting on this
        # board (#833). The given code is kept either way.
        _ = claimed_elsewhere?(:code, Board.sanitize_code(given))
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
  # Not a hole: field is one of the schema's own fields, never request input.
  # sobelow_skip ["DOS.StringToAtom"]
  defp attr_key(attrs, field) do
    if Enum.any?(attrs, fn {k, _} -> is_atom(k) end), do: String.to_atom(field), else: field
  end

  defp put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  @doc "The root board id of the tree `board_id` belongs to."
  def root_of_board(board_id), do: root_of(board_id)

  @doc false
  def root_of(board_id) do
    case Repo.get!(Board, board_id) do
      %Board{root_id: nil, id: id} -> id
      %Board{root_id: root_id} -> root_id
    end
  end
end
