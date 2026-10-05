defmodule Slipdock.Portable.Import do
  @moduledoc """
  Reading a portable document back in and building the board trees it holds —
  see `Slipdock.Portable` for the format.

  A document is somebody else's file, so it is checked whole before anything
  is built: its version, its shape, its size and the quota. After that every
  row goes in through its own schema's changeset, and a row that is refused is
  named in the report rather than failing the import. What has to wait for
  every row to exist — dependencies, page parents, rewritten page codes,
  backlinks — is done afterwards, mostly in `Slipdock.Portable.Refs`.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User

  alias Slipdock.Boards.{
    Board,
    Card,
    CardLink,
    CardUrl,
    ChecklistItem,
    Comment,
    FieldDefinition,
    FieldValue,
    Milestone,
    SavedView,
    StatusUpdate,
    Tag
  }

  alias Slipdock.{Quota, Repo}
  alias Slipdock.Boards.Column
  alias Slipdock.Portable.Refs
  alias Slipdock.Search.Indexer
  alias Slipdock.Wiki.{Folder, Page}

  @format_version Slipdock.Portable.format_version()

  # The most of any one kind of row — lists, folders, checklist items, comments
  # and so on — a single document may hold. Cards and pages answer to the
  # quota; these do not, so without a ceiling one card could carry millions.
  @max_rows 50_000

  @skips {__MODULE__, :skips}

  @doc """
  Reads a document and builds the board trees in it, owned by `user`.

  Returns `{:ok, report}` or `{:error, reason}`. The report says what was made
  and what could not be — `%{boards: [...], cards: n, pages: n, skipped: [...]}`
  — because an import that half-worked in silence is the worst of the possible
  outcomes.

  Three things it does **not** do, each a decision:

  **It never merges.** A document always becomes new boards, even when a board
  of that name and code is already here. Merging means deciding, per card,
  whether "the same card" means the same title, and getting that wrong quietly
  destroys work; a second copy is obvious and a person can delete it. A code
  that is taken is regenerated, and the report says so.

  **Automation rules do not fire.** Cards are inserted directly rather than
  through `Boards.create_card/2`, because importing four hundred cards through
  the normal path would run every rule on the board four hundred times and
  email somebody about each. Rules are about what happens *here*, and an
  import is history arriving.

  **The quota is checked once, up front, against the whole document.** The card
  limit is there to be a nudge towards subscribing, and the honest way to apply
  it to a file holding 300 cards is to say "this will not fit" before making
  any of it — not to stop at card 41 and leave a half-built board.
  """
  @spec import(User.t(), map() | binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def import(user, document, opts \\ [])

  def import(%User{} = user, document, opts) when is_binary(document) do
    case Jason.decode(document) do
      {:ok, decoded} -> import(user, decoded, opts)
      {:error, _} -> {:error, :not_json}
    end
  end

  def import(%User{} = user, %{} = document, opts) do
    document = atomise(document)

    with :ok <- check_format(document),
         {:ok, trees} <- trees_of(document),
         :ok <- check_shape(trees),
         :ok <- check_quota(user, trees) do
      Repo.transaction(fn ->
        Process.put(@skips, [])

        try do
          trees
          |> Enum.map(&import_tree(user, &1, opts))
          |> merge_reports()
          |> Map.update!(:skipped, &(&1 ++ Enum.reverse(Process.get(@skips))))
        after
          Process.delete(@skips)
        end
      end)
      |> case do
        {:ok, report} ->
          # Only once it has committed: the indexer reads the rows from
          # another process, and a rolled-back import has nothing to index.
          Indexer.enqueue_all(report.card_ids)
          Indexer.enqueue_pages(report.page_ids)
          {:ok, Map.drop(report, [:card_ids, :page_ids])}

        error ->
          error
      end
    end
  end

  defp trees_of(document) do
    case Map.get(document, :boards, []) do
      trees when is_list(trees) -> {:ok, trees}
      _ -> {:error, :not_a_slipdock_export}
    end
  end

  defp check_format(%{slipdock_portable: @format_version}), do: :ok

  defp check_format(%{slipdock_portable: other}) when is_integer(other),
    do: {:error, {:unsupported_version, other}}

  defp check_format(_), do: {:error, :not_a_slipdock_export}

  @doc "The most rows of any one kind a document may hold."
  def max_rows, do: @max_rows

  # A document is somebody else's file, so its shape is checked before anything
  # is built. Sub-boards are reached by following `subcards` from the root, so
  # a ref that is the root, or that two cards both claim, would build a board
  # inside itself or build it twice — forever, or 2^depth times. Refusing those
  # is enough to make the walk finite: every board is then reached at most once.
  defp check_shape(trees) do
    Enum.reduce_while(trees, :ok, fn tree, :ok ->
      case check_tree(tree) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_tree(%{root: %{ref: root_ref}} = tree) do
    claimed = for card <- rows(tree, :cards), ref = card[:subcards], do: ref

    cond do
      root_ref in claimed -> {:error, {:bad_sub_board, root_ref}}
      dup = first_duplicate(claimed) -> {:error, {:bad_sub_board, dup}}
      not rows_are_maps?(tree) -> {:error, :not_a_slipdock_export}
      true -> check_sizes(tree)
    end
  end

  defp check_tree(_), do: {:error, :not_a_slipdock_export}

  # Every row is read with `row[:key]`, which only a map answers. A file with a
  # string or a number where a card should be is not an export, and is turned
  # away here rather than crashing halfway through building it.
  @tree_rows ~w(boards cards pages tags fields folders milestones saved_views)a
  @owned_rows ~w(checklist comments status_updates urls fields links)a

  defp rows_are_maps?(tree) do
    boards = [tree.root | rows(tree, :boards)]
    owners = rows(tree, :cards) ++ rows(tree, :pages)

    Enum.all?(@tree_rows, &all_maps?(rows(tree, &1))) and
      Enum.all?(boards, &all_maps?(rows(&1, :lists))) and
      Enum.all?(owners, fn owner -> Enum.all?(@owned_rows, &all_maps?(rows(owner, &1))) end)
  end

  defp all_maps?(list), do: Enum.all?(list, &is_map/1)

  defp first_duplicate(refs) do
    Enum.reduce_while(refs, MapSet.new(), fn ref, seen ->
      if MapSet.member?(seen, ref), do: {:halt, ref}, else: {:cont, MapSet.put(seen, ref)}
    end)
    |> case do
      %MapSet{} -> nil
      ref -> ref
    end
  end

  defp check_sizes(tree) do
    boards = [tree.root | rows(tree, :boards)]
    owners = rows(tree, :cards) ++ rows(tree, :pages)

    counts = [
      boards: length(boards),
      lists: Enum.sum(Enum.map(boards, &length(rows(&1, :lists)))),
      tags: length(rows(tree, :tags)),
      fields: length(rows(tree, :fields)),
      folders: length(rows(tree, :folders)),
      milestones: length(rows(tree, :milestones)),
      saved_views: length(rows(tree, :saved_views)),
      checklist: sum_rows(owners, :checklist),
      comments: sum_rows(owners, :comments),
      status_updates: sum_rows(owners, :status_updates),
      urls: sum_rows(owners, :urls),
      field_values: sum_rows(owners, :fields),
      dependencies: sum_rows(owners, :blocked_by),
      links: sum_rows(owners, :links),
      tags_on_cards: sum_rows(owners, :tags),
      assignees: sum_rows(owners, :assignees)
    ]

    case Enum.find(counts, fn {_, count} -> count > @max_rows end) do
      nil -> :ok
      {kind, count} -> {:error, {:too_many, kind, count, @max_rows}}
    end
  end

  @doc "How a kind of row named in a `{:too_many, kind, …}` refusal reads in a sentence."
  def row_kind(kind), do: kind |> Atom.to_string() |> String.replace("_", " ")

  defp rows(%{} = doc, key) do
    case Map.get(doc, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp rows(_, _), do: []

  defp sum_rows(docs, key), do: Enum.reduce(docs, 0, &(length(rows(&1, key)) + &2))

  # One question asked once, about the whole file. See the moduledoc above for
  # why this is not per card.
  defp check_quota(user, trees) do
    # Everything the file would add that counts as an item: cards and pages,
    # archived ones included — they are built all the same, and restoring them
    # afterwards is only refused one at a time. Attachments do not travel in an
    # export, so there is nothing to weigh against the storage limit here.
    wanted =
      trees
      |> Enum.flat_map(&(Map.get(&1, :cards, []) ++ Map.get(&1, :pages, [])))
      |> Enum.count()

    boards = Enum.count(trees)

    with :ok <- room_for(user, :items, wanted),
         :ok <- room_for(user, :boards, boards) do
      :ok
    end
  end

  # An expired trial refuses the whole file, like a full quota does.
  defp room_for(user, dimension, wanted) do
    case Quota.check(user, dimension, wanted) do
      :ok ->
        :ok

      {:error, :trial_expired} ->
        {:error, :trial_expired}

      {:error, _reason} ->
        %{remaining: remaining} = Quota.status(user, dimension)
        {:error, {Quota.limit_name(dimension), wanted, remaining}}
    end
  end

  defp import_tree(user, tree, opts) do
    root_doc = Map.fetch!(tree, :root)
    boards_doc = [root_doc | Map.get(tree, :boards, [])]
    cards_doc = Map.get(tree, :cards, [])
    pages_doc = Map.get(tree, :pages, [])

    {root, code_changed} =
      case insert_board(user, root_doc, nil, nil, opts) do
        {nil, _} -> Repo.rollback({:invalid, hd(Process.get(@skips))})
        inserted -> inserted
      end

    # Lists, then the things the root owns and every card in the tree points
    # at: tags and fields have to exist before a card can reference one.
    ids = %{
      boards: %{root_doc.ref => root.id},
      columns: insert_columns!(root, root_doc),
      tags: insert_tags!(root, Map.get(tree, :tags, [])),
      fields: insert_fields!(root, Map.get(tree, :fields, [])),
      folders: %{},
      cards: %{},
      pages: %{}
    }

    # Sub-boards hang off cards and their cards live on them, so the tree is
    # built a level at a time: this board's cards, then the sub-boards those
    # cards own, then their cards.
    ids = build_level(user, root, root_doc, boards_doc, cards_doc, ids, opts)

    ids = Map.put(ids, :folders, insert_folders!(Map.get(tree, :folders, []), ids))
    ids = Map.put(ids, :pages, insert_pages!(user, pages_doc, ids))

    # Second pass: everything pointing at something that had to exist first.
    Refs.link_pages!(pages_doc, ids)
    Refs.remap_page_links!(pages_doc, ids)
    link_cards!(cards_doc, ids)
    insert_milestones!(root, Map.get(tree, :milestones, []), ids)
    insert_saved_views!(root, Map.get(tree, :saved_views, []))
    Refs.settle_writing!(user, ids, opts)

    skipped = Enum.flat_map(cards_doc ++ pages_doc, &Refs.missing_people(&1, user))

    %{
      boards: [%{id: root.id, name: root.name, code: root.code}],
      cards: map_size(ids.cards),
      pages: map_size(ids.pages),
      card_ids: Map.values(ids.cards),
      page_ids: Map.values(ids.pages),
      skipped:
        Enum.uniq(skipped) ++
          if(code_changed,
            do: ["The code “#{root_doc[:code]}” was taken, so this board is “#{root.code}”."],
            else: []
          )
    }
  end

  # One board's cards, then a sub-board for each card that had one, then that
  # sub-board's cards — depth first, so a ref is always written before it is
  # read.
  defp build_level(user, board, board_doc, boards_doc, cards_doc, ids, opts) do
    mine = Enum.filter(cards_doc, &(&1[:board] == board_doc.ref))

    ids =
      Enum.reduce(mine, ids, fn card_doc, acc ->
        case insert_card!(user, board, card_doc, acc) do
          nil -> acc
          card -> put_in(acc, [:cards, card_doc[:ref]], card.id)
        end
      end)

    Enum.reduce(mine, ids, fn card_doc, acc ->
      card_id = acc.cards[card_doc[:ref]]

      case card_doc[:subcards] && Enum.find(boards_doc, &(&1[:ref] == card_doc[:subcards])) do
        nil ->
          acc

        # `check_shape/1` has already refused a document that could get here;
        # this is the backstop, so no ref is ever built twice.
        %{ref: ref} when is_map_key(acc.boards, ref) ->
          acc

        # The card it hangs off was refused, so there is nothing to hang it
        # off — and a sub-board with no card would surface as a root board.
        _sub_doc when is_nil(card_id) ->
          acc

        sub_doc ->
          case insert_board(user, sub_doc, card_id, board.root_id || board.id, opts) do
            {nil, _} ->
              acc

            {sub, _} ->
              acc = put_in(acc, [:boards, sub_doc.ref], sub.id)
              acc = Map.put(acc, :columns, Map.merge(acc.columns, insert_columns!(sub, sub_doc)))

              build_level(user, sub, sub_doc, boards_doc, cards_doc, acc, opts)
          end
      end
    end)
  end

  ## In: the inserts -------------------------------------------------------------

  # Every row goes through its schema's own changeset — the one the UI and the
  # API use — so a file cannot put anything here that could not have been typed
  # in: a `javascript:` link, a priority that is not one, a duplicate tag. A
  # row that fails is left out and named in the report, and whatever needed it
  # (a card on a list that was refused) is left out in turn. The fields a
  # changeset does not cast, the ones saying where a row belongs, are set on
  # the struct. Each insert is its own savepoint: Postgres abandons the whole
  # transaction at a failed constraint otherwise, and a duplicate tag would
  # take every row after it down too.
  defp known(value, keys), do: if(value in keys, do: value)

  defp insert(%module{} = struct, attrs, what) do
    case struct |> module.changeset(attrs) |> Repo.insert(mode: :savepoint) do
      {:ok, row} -> row
      {:error, changeset} -> skip("#{what} was left out: #{errors(changeset)}.")
    end
  end

  # The skipped rows of one import, gathered in the process doing it rather
  # than threaded through every insert. `import/3` sets and clears it.
  defp skip(message) do
    Process.put(@skips, [message | Process.get(@skips, [])])
    nil
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn whole, key ->
        case Keyword.get(opts, String.to_existing_atom(key)) do
          value when is_binary(value) or is_number(value) -> to_string(value)
          _ -> whole
        end
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp named(kind, name) when is_binary(name) and name != "", do: "The #{kind} “#{name}”"
  defp named(kind, _), do: "A #{kind}"

  defp insert_board(user, doc, parent_card_id, root_id, opts) do
    wanted = doc[:code]
    code = free_code(wanted, doc[:name])

    board =
      insert(
        %Board{
          archived_at: if(doc[:archived] && opts[:keep_archived] != false, do: now()),
          parent_card_id: parent_card_id,
          root_id: root_id,
          owner_id: user.id
        },
        %{
          name: doc[:name] || "Imported board",
          code: code,
          # A shortcut is one or two characters and unique across the server,
          # so it cannot travel: the importing person picks their own.
          shortcut: nil,
          description: doc[:description],
          color: doc[:color] || "indigo",
          vote_budget: doc[:vote_budget] || 10,
          vote_max: doc[:vote_max] || 5,
          add_card: bool(doc[:add_card], true),
          add_page: bool(doc[:add_page], true),
          add_document: bool(doc[:add_document], true),
          simple: bool(doc[:simple], false),
          kind: if(doc[:kind] in Board.kinds(), do: doc[:kind])
        },
        named("board", doc[:name]) <> if(root_id, do: ", and everything on it,", else: "")
      )

    {board, board != nil and wanted not in [nil, ""] and code != wanted}
  end

  defp insert_columns!(board, doc) do
    doc
    |> rows(:lists)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {list, index}, acc ->
      column =
        insert(
          %Column{},
          %{
            board_id: board.id,
            name: list[:name] || "List #{index + 1}",
            position: list[:position] || index,
            wip_limit: list[:wip_limit],
            color: list[:color],
            category: list[:category],
            horizon_from: date(list[:horizon_from]),
            horizon_to: date(list[:horizon_to]),
            horizon_unit: list[:horizon_unit],
            # How the list draws its cards is a nicety: one this server does
            # not know is dropped rather than costing the list its cards.
            sort_by: known(list[:sort_by], Slipdock.ListOrder.sort_keys()),
            sort_dir: known(list[:sort_dir], Slipdock.ListOrder.dir_keys()),
            group_by: known(list[:group_by], Slipdock.ListOrder.group_keys())
          },
          named("list", list[:name]) <> ", and the cards on it,"
        )

      if column, do: Map.put(acc, list[:ref], column.id), else: acc
    end)
  end

  defp insert_tags!(root, tags) do
    Enum.reduce(tags, %{}, fn tag, acc ->
      inserted =
        insert(
          %Tag{},
          %{board_id: root.id, name: tag[:name], color: tag[:color] || "slate"},
          named("tag", tag[:name])
        )

      if inserted, do: Map.put(acc, tag[:ref], inserted.id), else: acc
    end)
  end

  defp insert_fields!(root, fields) do
    fields
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {field, index}, acc ->
      inserted =
        insert(
          %FieldDefinition{board_id: root.id},
          %{
            name: field[:name],
            key: field[:key],
            kind: field[:kind],
            position: field[:position] || index,
            options: field[:options] || [],
            config: field[:config] || %{},
            sum: bool(field[:sum], false)
          },
          named("field", field[:name])
        )

      if inserted, do: Map.put(acc, field[:ref], inserted.id), else: acc
    end)
  end

  defp insert_folders!(folders, ids) do
    # Parents first, so a nested folder has somewhere to hang. The document
    # writes them in position order, which is not necessarily parent order, so
    # walk down from the top-level ones: one insert each, and a folder whose
    # parent never arrives — or that is its own ancestor — is never reached.
    children = Enum.group_by(folders, &(&1[:parent] || nil))
    insert_folder_level!(Map.get(children, nil, []), nil, children, ids, %{})
  end

  defp insert_folder_level!(level, parent_id, children, ids, acc) do
    Enum.reduce(level, acc, fn folder, acc ->
      board_id = ids.boards[folder[:board]]

      inserted =
        cond do
          Map.has_key?(acc, folder[:ref]) ->
            nil

          is_nil(board_id) ->
            skip("#{named("folder", folder[:name])} was left out: its board is not in the file.")

          true ->
            insert(
              %Folder{board_id: board_id},
              %{
                name: folder[:name],
                slug: folder[:slug],
                position: folder[:position] || 0,
                parent_id: parent_id
              },
              named("folder", folder[:name])
            )
        end

      if inserted do
        acc = Map.put(acc, folder[:ref], inserted.id)
        insert_folder_level!(Map.get(children, folder[:ref], []), inserted.id, children, ids, acc)
      else
        acc
      end
    end)
  end

  defp insert_card!(user, board, doc, ids) do
    assignee_ids = Refs.assignee_ids_for(doc, user)

    card =
      insert(
        %Card{archived_at: if(doc[:archived], do: now())},
        %{
          board_id: board.id,
          column_id: ids.columns[doc[:list]],
          title: doc[:title] || "Untitled",
          description: doc[:description],
          position: doc[:position] || 0,
          priority: doc[:priority] || "none",
          flags: doc[:flags] || [],
          start_date: date(doc[:start_date]),
          due_date: date(doc[:due_date]),
          date_precision: doc[:date_precision] || "day",
          completed: bool(doc[:completed], false),
          percent_complete: doc[:percent_complete],
          time_spent: minutes(doc[:time_spent]),
          time_estimate: minutes(doc[:time_estimate]),
          time_unit:
            if(doc[:time_unit] in Slipdock.TimeTracking.unit_keys(),
              do: doc[:time_unit],
              else: Slipdock.TimeTracking.default_unit()
            ),
          color: doc[:color],
          assignee_id: List.first(assignee_ids)
        },
        named("card", doc[:title])
      )

    if card do
      Repo.insert_all(
        "card_assignees",
        Enum.map(assignee_ids, &[card_id: card.id, user_id: &1])
      )

      tag_ids = doc |> rows(:tags) |> Enum.map(&ids.tags[&1]) |> Enum.reject(&is_nil/1)

      Repo.insert_all("card_tags", Enum.map(Enum.uniq(tag_ids), &[card_id: card.id, tag_id: &1]))

      insert_attached!(user, [card_id: card.id], doc, ids)
    end

    card
  end

  # A page's code is globally unique on a server ("W-31" resolves with no board
  # behind it), so an imported page cannot keep the one it arrived with. It
  # gets a fresh code and a fresh per-board number, and `Refs.remap_page_links!/2`
  # then rewrites `[[W-31]]` inside the imported bodies so the wiki that comes
  # out the other side still links to itself.
  defp insert_pages!(user, pages, ids) do
    pages
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {doc, index}, acc ->
      board_id = ids.boards[doc[:board]]

      page =
        if is_nil(board_id) do
          skip("#{named("page", doc[:title])} was left out: its board is not in the file.")
        else
          insert(
            %Page{
              board_id: board_id,
              column_id: doc[:list] && ids.columns[doc[:list]],
              code: Refs.fresh_page_code(),
              number: Refs.fresh_page_number(board_id),
              board_position: doc[:board_position] || 0,
              archived_at: if(doc[:archived], do: now()),
              created_by_id: user.id,
              # The changeset hashes a body that changes, and "" does not.
              content_hash: Page.hash(if(is_binary(doc[:body]), do: doc[:body], else: ""))
            },
            %{
              title: doc[:title] || "Untitled",
              slug: doc[:slug] || "page-#{index}",
              body: doc[:body] || "",
              summary: doc[:summary],
              position: doc[:position] || 0,
              status: doc[:status] || "published",
              template: bool(doc[:template], false),
              folder_id: doc[:folder] && ids.folders[doc[:folder]],
              priority: doc[:priority] || "none",
              flags: doc[:flags] || [],
              start_date: date(doc[:start_date]),
              due_date: date(doc[:due_date]),
              date_precision: doc[:date_precision] || "day",
              completed: bool(doc[:completed], false),
              percent_complete: doc[:percent_complete],
              color: doc[:color],
              assignee_id: Refs.user_id_for(doc[:assignee], user)
            },
            named("page", doc[:title])
          )
        end

      if page do
        insert_attached!(user, [page_id: page.id], doc, ids)
        Map.put(acc, doc[:ref], page.id)
      else
        acc
      end
    end)
  end

  # Checklists, comments, status updates, web links and field values: the same
  # five for a card and for a page, which is why they take an owner.
  defp insert_attached!(user, owner, doc, ids) do
    owner = Map.new(owner)
    on = fn what -> "#{what} on “#{doc[:title] || "Untitled"}”" end

    for {item, index} <- Enum.with_index(rows(doc, :checklist)) do
      insert(
        %ChecklistItem{},
        Map.merge(owner, %{
          text: item[:text],
          done: bool(item[:done], false),
          position: item[:position] || index
        }),
        on.("A checklist item")
      )
    end

    for comment <- rows(doc, :comments) do
      insert(%Comment{}, Map.put(owner, :body, comment[:body]), on.("A comment"))
    end

    # A status update is signed, and the signature is the importer's: a
    # document cannot put words in somebody else's name (they would turn up in
    # that person's own account export). Who wrote it goes into the text, as
    # the Trello importer does with comments.
    for update <- rows(doc, :status_updates) do
      insert(
        %StatusUpdate{user_id: user.id},
        Map.merge(owner, %{
          health: update[:health],
          body: Refs.signed(update[:body], update[:author], user)
        }),
        on.("A status update")
      )
    end

    for url <- rows(doc, :urls) do
      insert(
        %CardUrl{},
        Map.merge(owner, %{url: url[:url], title: url[:title]}),
        on.("A link")
      )
    end

    for value <- rows(doc, :fields), field_id = ids.fields[value[:field]] do
      insert(
        %FieldValue{},
        Map.merge(owner, %{
          field_id: field_id,
          number: value[:number],
          text: value[:text],
          date: date(value[:date]),
          option: value[:option]
        }),
        on.("A field value")
      )
    end

    :ok
  end

  # Dependencies and links point at other cards, so they wait until every card
  # in the tree exists. A dependency gets the same three checks as one made by
  # hand — not on itself, not across boards, not round in a circle — because a
  # cycle is a board on which nothing can ever become ready. Every card here is
  # new, so the graph to check against is the one this file builds.
  defp link_cards!(cards, ids) do
    by_ref = Map.new(cards, &{&1[:ref], &1})

    Enum.reduce(cards, %{}, fn doc, blocks ->
      blocked_id = ids.cards[doc[:ref]]

      blocks =
        Enum.reduce(rows(doc, :blocked_by), blocks, fn ref, blocks ->
          blocker_id = ids.cards[ref]

          case blocked_id && blocker_id && Refs.dependency_refusal(doc, by_ref[ref], blocks, ids) do
            nil ->
              blocks

            :ok ->
              Repo.insert_all(
                "card_dependencies",
                [[blocked_id: blocked_id, blocker_id: blocker_id]],
                on_conflict: :nothing
              )

              Map.update(blocks, blocker_id, [blocked_id], &[blocked_id | &1])

            {:refused, why} ->
              skip("A dependency of #{named("card", doc[:title])} was left out: #{why}.")
              blocks
          end
        end)

      for link <- rows(doc, :links), blocked_id, to_id = ids.cards[link[:to]] do
        insert(
          %CardLink{from_id: blocked_id, to_id: to_id},
          %{kind: link[:kind]},
          "A link from #{named("card", doc[:title])}"
        )
      end

      blocks
    end)

    :ok
  end

  defp insert_milestones!(root, milestones, ids) do
    for milestone <- milestones do
      insert(
        %Milestone{board_id: root.id},
        %{
          name: milestone[:name],
          date: date(milestone[:date]),
          color: milestone[:color],
          card_id: milestone[:card] && ids.cards[milestone[:card]]
        },
        named("milestone", milestone[:name])
      )
    end

    :ok
  end

  defp insert_saved_views!(root, views) do
    for view <- views do
      # Not the public token: a share link that worked on the server this came
      # from must not start working here as well.
      insert(
        %SavedView{},
        %{board_id: root.id, name: view[:name], config: view[:config] || %{}},
        named("saved view", view[:name])
      )
    end

    :ok
  end

  ## In: the small decisions -----------------------------------------------------

  # A board's code is unique per server, so an import onto a server that
  # already has "del" gets "del-2". The report says so rather than leaving
  # somebody to notice.
  defp free_code(wanted, name) do
    base = Board.sanitize_code(if is_binary(wanted), do: wanted, else: "")
    base = if base == "" and is_binary(name), do: Board.sanitize_code(name), else: base
    # A name is any length and a code is at most ten characters.
    base = base |> String.slice(0, 10) |> String.trim_trailing("-")
    base = if base == "", do: "board", else: base

    if taken?(base), do: next_free(base, 2), else: base
  end

  defp next_free(base, n) do
    # Codes are capped at ten characters, so the suffix eats into the stem
    # rather than overflowing it.
    suffix = "-#{n}"
    candidate = String.slice(base, 0, 10 - String.length(suffix)) <> suffix

    cond do
      n > 99 ->
        Board.sanitize_code("b#{System.unique_integer([:positive])}") |> String.slice(0, 10)

      taken?(candidate) ->
        next_free(base, n + 1)

      true ->
        candidate
    end
  end

  defp taken?(code), do: Repo.exists?(from(b in Board, where: b.code == ^code))

  defp merge_reports(reports) do
    empty = %{boards: [], cards: 0, pages: 0, card_ids: [], page_ids: [], skipped: []}

    Enum.reduce(reports, empty, fn report, acc ->
      %{
        boards: acc.boards ++ report.boards,
        cards: acc.cards + report.cards,
        pages: acc.pages + report.pages,
        card_ids: acc.card_ids ++ report.card_ids,
        page_ids: acc.page_ids ++ report.page_ids,
        skipped: Enum.uniq(acc.skipped ++ report.skipped)
      }
    end)
  end

  # Documents arrive as JSON with string keys, and are written here with atom
  # ones. One conversion at the door beats `doc["x"] || doc[:x]` everywhere.
  defp atomise(%{} = map) do
    Map.new(map, fn {key, value} ->
      {safe_atom(key), atomise(value)}
    end)
  end

  defp atomise(list) when is_list(list), do: Enum.map(list, &atomise/1)
  defp atomise(other), do: other

  defp safe_atom(key) when is_atom(key), do: key

  defp safe_atom(key) when is_binary(key) do
    # Only keys this module writes become atoms; anything else stays a string,
    # so a hostile document cannot fill the atom table.
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp bool(nil, default), do: default
  defp bool(value, _default) when is_boolean(value), do: value
  defp bool("true", _), do: true
  defp bool("false", _), do: false
  defp bool(_, default), do: default

  defp minutes(n) when is_integer(n) and n >= 0, do: n
  defp minutes(_), do: nil

  defp date(nil), do: nil
  defp date(%Date{} = date), do: date

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date(_), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
