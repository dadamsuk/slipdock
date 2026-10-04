defmodule Slipdock.Portable do
  @moduledoc """
  Board trees out as one JSON document, and back in again.

  This is not the same thing as `Slipdock.AccountExport`, which answers "let
  me leave with my data" and writes a zip a person reads. That one flattens a
  board to lists of cards and drops subcards, tags, checklists, comments,
  custom fields and dependencies, because nothing is ever going to read it
  back. This one is the opposite promise: **what comes out can go back in**,
  on this server or another one, and come back the same shape.

  Which forces three decisions.

  **The unit is a board tree, not a board.** Tags, custom fields, milestones
  and saved views are stored against the root of a tree and shared by every
  sub-board under it (see `Slipdock.Boards.Board`), and a card's subcards *are*
  a sub-board. Exporting one board of a tree would hand you cards whose tags
  and fields live somewhere you did not export, so a root board always comes
  with its descendants.

  **Nothing inside the document is a database id.** Every board, list, tag,
  field, card and page gets a `ref` — `"k12"`, `"t3"` — unique in the document
  and meaningless outside it. Anything pointing at anything else points at a
  ref. A document is then self-contained: the importer never has to care which
  server wrote it, and two documents can be imported into one server without
  colliding.

  **People are email addresses.** An assignee or a status update's author is
  written as an address, because an id from another server names nobody here.
  On the way back in an address that has no account is simply dropped, and the
  import says so — the alternative is an import that fails on the last card
  because somebody left the company.

  What is deliberately *not* in a document: attachments (bytes, not structure —
  they stay with the server), votes (a person's budget, not a board's content),
  activity and page revision history (a record of this server's past, which
  another server cannot honestly adopt), and public share tokens (a secret
  that would then be valid in two places). Each of those is a decision rather
  than an omission, and `warnings/1` on an export says which of them had
  something to leave behind.
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
  alias Slipdock.Search.Indexer
  alias Slipdock.Wiki.{Folder, Links, Page, Revision}

  @format_version 1

  # The most of any one kind of row — lists, folders, checklist items, comments
  # and so on — a single document may hold. Cards and pages answer to the
  # quota; these do not, so without a ceiling one card could carry millions.
  @max_rows 50_000

  @skips {__MODULE__, :skips}

  @doc "The format version this module writes, and the only one it reads."
  def format_version, do: @format_version

  ## Out ------------------------------------------------------------------------

  @doc """
  One document holding whole board trees.

  `boards` is a list of root boards to take; omit it, or pass `:owned`, for
  every root board the user owns. Options:

    * `:archived_cards` — include archived cards (default `false`)
    * `:archived_pages` — include archived wiki pages (default `false`)
    * `:archived_boards` — include archived root boards when taking all of
      them (default `false`)

  Archived *sub-boards* are not a thing — a sub-board goes away with its card —
  so the board-level switch is about root boards only.
  """
  @spec export(User.t(), keyword()) :: map()
  def export(%User{} = user, opts \\ []) do
    roots = roots_for(user, opts)

    %{
      slipdock_portable: @format_version,
      exported_at: DateTime.utc_now() |> DateTime.truncate(:second),
      exported_by: user.email,
      exported_from: %{
        version: Slipdock.Build.version(),
        commit: Slipdock.Build.sha()
      },
      options: %{
        archived_cards: !!opts[:archived_cards],
        archived_pages: !!opts[:archived_pages]
      },
      boards: Enum.map(roots, &tree_json(&1, opts))
    }
  end

  @doc """
  `export/2` as pretty JSON, with a filename to offer it under.

  Returns `{filename, iodata}`.
  """
  @spec to_json(User.t(), keyword()) :: {String.t(), iodata()}
  def to_json(%User{} = user, opts \\ []) do
    document = export(user, opts)
    name = "slipdock-export-#{Date.utc_today()}.json"
    {name, Jason.encode_to_iodata!(document, pretty: true)}
  end

  @doc """
  What an export of the same selection knowingly leaves behind, as sentences
  for a person.

  Takes the user and options rather than a document, because the counts come
  from the database: the document holds refs, not ids, which is the whole point
  of it. Empty when there was nothing of that kind to leave, so an export of a
  board with no attachments does not warn about attachments.
  """
  @spec warnings(User.t(), keyword()) :: [String.t()]
  def warnings(%User{} = user, opts \\ []) do
    board_ids =
      user
      |> roots_for(opts)
      |> Enum.flat_map(fn root -> [root.id | Enum.map(descendants(root), & &1.id)] end)

    [
      {attachment_count(board_ids),
       "Attachments are not in this file. They are bytes rather than structure, and they " <>
         "stay on the server they were uploaded to."},
      {vote_count(board_ids),
       "Votes are not in this file. A vote is a person's budget spent, which does not mean " <>
         "the same thing on another server."},
      {revision_count(board_ids),
       "Wiki page history is not in this file — only each page as it stands now. A record " <>
         "of who changed what here is not something another server can honestly adopt."}
    ]
    |> Enum.filter(fn {count, _} -> count > 0 end)
    |> Enum.map(fn {count, sentence} -> "#{count} left behind. #{sentence}" end)
  end

  ## In -------------------------------------------------------------------------

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
    link_pages!(pages_doc, ids)
    remap_page_links!(pages_doc, ids)
    link_cards!(cards_doc, ids)
    insert_milestones!(root, Map.get(tree, :milestones, []), ids)
    insert_saved_views!(root, Map.get(tree, :saved_views, []))
    settle_writing!(user, ids, opts)

    skipped = Enum.flat_map(cards_doc ++ pages_doc, &missing_people(&1, user))

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
            horizon_unit: list[:horizon_unit]
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
    assignee_ids = assignee_ids_for(doc, user)

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
  # gets a fresh code and a fresh per-board number, and `remap_page_links!/2`
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
              code: fresh_page_code(),
              number: fresh_page_number(board_id),
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
              assignee_id: user_id_for(doc[:assignee], user)
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
          body: signed(update[:body], update[:author], user)
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

          case blocked_id && blocker_id && dependency_refusal(doc, by_ref[ref], blocks, ids) do
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

  defp dependency_refusal(blocked, blocker, blocks, ids) do
    blocked_id = ids.cards[blocked[:ref]]
    blocker_id = ids.cards[blocker[:ref]]

    cond do
      blocked_id == blocker_id -> {:refused, "a card cannot depend on itself"}
      blocked[:board] != blocker[:board] -> {:refused, "the two cards are on different boards"}
      reaches?(blocks, blocked_id, blocker_id) -> {:refused, "it would make a circle"}
      true -> :ok
    end
  end

  # Does `from` block `target`, directly or down a chain?
  defp reaches?(blocks, from, target), do: reaches?(blocks, [from], target, MapSet.new())

  defp reaches?(_blocks, [], _target, _seen), do: false
  defp reaches?(_blocks, [target | _], target, _seen), do: true

  defp reaches?(blocks, [id | rest], target, seen) do
    if MapSet.member?(seen, id),
      do: reaches?(blocks, rest, target, seen),
      else: reaches?(blocks, Map.get(blocks, id, []) ++ rest, target, MapSet.put(seen, id))
  end

  defp fresh_page_code do
    highest =
      Repo.one(from(p in Page, select: max(fragment("CAST(substr(?, 3) AS INTEGER)", p.code))))

    Page.code_for((highest || 0) + 1)
  end

  defp fresh_page_number(board_id) do
    {1, _} = Repo.update_all(from(b in Board, where: b.id == ^board_id), inc: [page_seq: 1])
    Repo.one!(from(b in Board, where: b.id == ^board_id, select: b.page_seq))
  end

  # `[[W-31]]` in an imported body means the page that was W-31 on the server
  # the document came from, which is a different page here (or none). The
  # document says which page had which code, so the rewrite is exact.
  defp remap_page_links!(pages, ids) do
    renames =
      for doc <- pages,
          old = doc[:code],
          # Only something shaped like a code: a blank one would make the
          # pattern below match at every word boundary in every page.
          is_binary(old) and Page.code?(old),
          new_id = ids.pages[doc[:ref]],
          into: %{} do
        {old, Repo.one!(from(p in Page, where: p.id == ^new_id, select: p.code))}
      end

    if renames != %{} do
      # Only where the code stands as a reference — `[[W-31]]` or a bare `W-31`
      # on a word boundary — so prose that happens to contain the letters is
      # left alone. One pattern for every code, so each body is read once and a
      # new code is never itself rewritten by a later rename.
      alternatives = renames |> Map.keys() |> Enum.map_join("|", &Regex.escape/1)
      pattern = Regex.compile!("\\b(?:#{alternatives})\\b")

      for doc <- pages, page_id = ids.pages[doc[:ref]] do
        page = Repo.get!(Page, page_id)
        rewritten = Regex.replace(pattern, page.body || "", &Map.fetch!(renames, &1))

        if rewritten != page.body do
          page
          |> Ecto.Changeset.change(body: rewritten, content_hash: Page.hash(rewritten))
          |> Repo.update!()
        end
      end
    end

    :ok
  end

  # What writing a page or a comment by hand does besides the insert, done once
  # every imported page has its final body: a first revision, so the page has
  # a history to diff against, and its links, so `[[Other page]]` shows up in
  # that page's backlinks — the same for comments and status updates, whose
  # links can point at a page imported after their card.
  defp settle_writing!(user, ids, opts) do
    page_ids = Map.values(ids.pages)
    card_ids = Map.values(ids.cards)
    pages = Repo.all(from(p in Page, where: p.id in ^page_ids))
    via = if opts[:via] in Revision.vias(), do: opts[:via], else: "web"

    for page <- pages do
      %Revision{}
      |> Revision.changeset(%{
        "page_id" => page.id,
        "title" => page.title,
        "body" => page.body,
        "summary" => "Imported",
        "via" => via,
        "author_id" => user.id
      })
      |> Repo.insert!()

      Links.reconcile(page)
    end

    owned = fn query ->
      Repo.all(from(r in query, where: r.card_id in ^card_ids or r.page_id in ^page_ids))
    end

    Enum.each(owned.(Comment), &Links.reconcile_comment/1)
    Enum.each(owned.(StatusUpdate), &Links.reconcile_status/1)
  end

  defp link_pages!(pages, ids) do
    for doc <- pages, parent_ref = doc[:parent], parent_id = ids.pages[parent_ref] do
      Page
      |> Repo.get!(ids.pages[doc[:ref]])
      |> Ecto.Changeset.change(parent_id: parent_id)
      |> Repo.update!()
    end

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

  # Whoever an address names, they can be put on an imported card only if
  # they can open it — the rule `Slipdock.Boards.resolve_assignees/3` keeps
  # everywhere else. An imported tree is new and the importer's alone, so that
  # is the importer and nobody else; anyone else comes in unassigned, to be
  # shared with and assigned again. Nobody is not an error — the alternative is
  # an import that dies on the last card because somebody left.
  defp user_id_for(email, %User{} = user) when is_binary(email) do
    if String.downcase(String.trim(email)) == String.downcase(user.email), do: user.id
  end

  defp user_id_for(_, _user), do: nil

  # Everybody on a card, lead first. `assignees` is how a card with several
  # people comes; a document written before there could be more than one has
  # only `assignee`.
  defp assignee_emails(doc), do: List.wrap(doc[:assignees] || doc[:assignee])

  defp assignee_ids_for(doc, user),
    do:
      doc
      |> assignee_emails()
      |> Enum.map(&user_id_for(&1, user))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

  # The same words whether or not the address has an account on this server:
  # the report is not a way of finding out who does.
  defp missing_people(doc, user) do
    assignee_emails(doc)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.reject(&user_id_for(&1, user))
    |> Enum.map(&"#{&1} can't see this board yet, so what was theirs came in unassigned.")
  end

  defp signed(body, author, %User{} = user)
       when is_binary(body) and is_binary(author) and author != "" do
    if user_id_for(author, user), do: body, else: "*#{author}*\n\n#{body}"
  end

  defp signed(body, _author, _user), do: body

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

  ## Internals: choosing what to export -----------------------------------------

  defp roots_for(user, opts) do
    case opts[:boards] do
      nil -> owned_roots(user, opts)
      :owned -> owned_roots(user, opts)
      boards when is_list(boards) -> boards |> Enum.map(&root_of/1) |> Enum.uniq_by(& &1.id)
    end
  end

  defp owned_roots(user, opts) do
    query =
      from(b in Board,
        where: b.owner_id == ^user.id and is_nil(b.parent_card_id),
        order_by: [asc: b.id]
      )

    query = if opts[:archived_boards], do: query, else: where(query, [b], is_nil(b.archived_at))

    Repo.all(query)
  end

  @doc """
  Given any board of a tree, the root of it — exporting a sub-board on its
  own would hand out cards whose tags and fields were left behind. So the
  root is also what anybody asking to export a board has to own.
  """
  def root_of(%Board{} = board) do
    case board.root_id do
      nil -> board
      root_id -> Repo.get!(Board, root_id)
    end
  end

  def root_of(id) when is_integer(id) or is_binary(id),
    do: Board |> Repo.get!(id) |> root_of()

  ## Internals: writing a tree ---------------------------------------------------

  defp tree_json(%Board{} = root, opts) do
    boards = [root | descendants(root)]
    board_ids = Enum.map(boards, & &1.id)

    cards = cards_in(board_ids, opts)
    pages = pages_in(board_ids, opts)
    columns = Enum.flat_map(boards, &columns_of/1)
    tags = tags_of(root)
    fields = fields_of(root)
    folders = folders_in(board_ids)

    refs = %{
      boards: numbered(boards, "b"),
      cards: numbered(cards, "k"),
      pages: numbered(pages, "w"),
      columns: numbered(columns, "c"),
      tags: numbered(tags, "t"),
      fields: numbered(fields, "f"),
      folders: numbered(folders, "fo")
    }

    # Everything hanging off the cards and pages, fetched once for the tree
    # rather than once per card: an export of a large board was ten queries a
    # card and another for every email address.
    refs = Map.put(refs, :loaded, load_attached(boards, cards, pages))

    %{
      ref: refs.boards[root.id],
      root: board_json(root, columns, refs),
      boards: Enum.map(tl(boards), &board_json(&1, columns, refs)),
      tags: Enum.map(tags, &tag_json(&1, refs)),
      fields: Enum.map(fields, &field_json(&1, refs)),
      milestones: Enum.map(milestones_of(root), &milestone_json(&1, refs)),
      saved_views: Enum.map(saved_views_of(root), &saved_view_json/1),
      folders: Enum.map(folders, &folder_json(&1, refs)),
      cards: Enum.map(cards, &card_json(&1, refs)),
      pages: Enum.map(pages, &page_json(&1, refs))
    }
  end

  # Every board under this one, however deep: a sub-board hangs off a card,
  # and that card's board is already in the set.
  defp descendants(%Board{} = root) do
    Repo.all(
      from(b in Board,
        where: b.root_id == ^root.id and not is_nil(b.parent_card_id),
        order_by: [asc: b.id]
      )
    )
  end

  defp numbered(records, prefix) do
    records
    |> Enum.with_index(1)
    |> Map.new(fn {record, index} -> {record.id, "#{prefix}#{index}"} end)
  end

  defp board_json(%Board{} = board, columns, refs) do
    %{
      ref: refs.boards[board.id],
      name: board.name,
      code: board.code,
      shortcut: board.shortcut,
      description: board.description,
      color: board.color,
      vote_budget: board.vote_budget,
      vote_max: board.vote_max,
      add_card: board.add_card,
      add_page: board.add_page,
      add_document: board.add_document,
      simple: board.simple,
      kind: board.kind,
      archived: board.archived_at != nil,
      # A sub-board hangs off a card; a root board hangs off nothing.
      inside_card: board.parent_card_id && refs.cards[board.parent_card_id],
      lists:
        columns
        |> Enum.filter(&(&1.board_id == board.id))
        |> Enum.map(&column_json(&1, refs))
    }
  end

  defp column_json(column, refs) do
    %{
      ref: refs.columns[column.id],
      name: column.name,
      position: column.position,
      wip_limit: column.wip_limit,
      color: column.color,
      category: column.category,
      horizon_from: column.horizon_from,
      horizon_to: column.horizon_to,
      horizon_unit: column.horizon_unit
    }
  end

  defp tag_json(tag, refs), do: %{ref: refs.tags[tag.id], name: tag.name, color: tag.color}

  defp field_json(field, refs) do
    %{
      ref: refs.fields[field.id],
      name: field.name,
      key: field.key,
      kind: field.kind,
      position: field.position,
      options: field.options,
      config: field.config,
      sum: field.sum
    }
  end

  defp milestone_json(milestone, refs) do
    %{
      name: milestone.name,
      date: milestone.date,
      color: milestone.color,
      card: milestone.card_id && refs.cards[milestone.card_id]
    }
  end

  defp saved_view_json(view), do: %{name: view.name, config: view.config}

  defp folder_json(folder, refs) do
    %{
      ref: refs.folders[folder.id],
      board: refs.boards[folder.board_id],
      name: folder.name,
      slug: folder.slug,
      position: folder.position,
      parent: folder.parent_id && refs.folders[folder.parent_id]
    }
  end

  defp card_json(%Card{} = card, refs) do
    %{
      ref: refs.cards[card.id],
      board: refs.boards[card.board_id],
      list: refs.columns[card.column_id],
      title: card.title,
      description: card.description,
      position: card.position,
      priority: card.priority,
      flags: card.flags,
      start_date: card.start_date,
      due_date: card.due_date,
      date_precision: card.date_precision,
      completed: card.completed,
      percent_complete: card.percent_complete,
      # Minutes, whatever the unit; a running timer's time isn't spent yet.
      time_spent: card.time_spent,
      time_estimate: card.time_estimate,
      time_unit: card.time_unit,
      color: card.color,
      archived: card.archived_at != nil,
      created_at: card.inserted_at,
      assignee: email_of(card.assignee_id, refs),
      assignees: card |> assignee_ids(refs) |> Enum.map(&email_of(&1, refs)),
      # A sub-board is a board in this document; the card points at it so an
      # import can rebuild the nesting without guessing.
      subcards: refs.boards[refs.loaded.sub_boards[card.id]],
      tags: tag_refs(card.id, refs),
      blocked_by: dependency_refs(card.id, refs),
      links: link_json(card.id, refs),
      checklist: owned(refs, :checklist, {:card, card.id}),
      comments: owned(refs, :comments, {:card, card.id}),
      status_updates: status_json({:card, card.id}, refs),
      urls: owned(refs, :urls, {:card, card.id}),
      fields: field_value_json({:card, card.id}, refs)
    }
  end

  defp page_json(%Page{} = page, refs) do
    %{
      ref: refs.pages[page.id],
      board: refs.boards[page.board_id],
      list: page.column_id && refs.columns[page.column_id],
      title: page.title,
      slug: page.slug,
      code: page.code,
      number: page.number,
      body: page.body,
      summary: page.summary,
      position: page.position,
      board_position: page.board_position,
      status: page.status,
      template: page.template,
      folder: page.folder_id && refs.folders[page.folder_id],
      parent: page.parent_id && refs.pages[page.parent_id],
      priority: page.priority,
      flags: page.flags,
      start_date: page.start_date,
      due_date: page.due_date,
      date_precision: page.date_precision,
      completed: page.completed,
      percent_complete: page.percent_complete,
      color: page.color,
      archived: page.archived_at != nil,
      created_at: page.inserted_at,
      assignee: email_of(page.assignee_id, refs),
      checklist: owned(refs, :checklist, {:page, page.id}),
      comments: owned(refs, :comments, {:page, page.id}),
      status_updates: status_json({:page, page.id}, refs),
      urls: owned(refs, :urls, {:page, page.id}),
      fields: field_value_json({:page, page.id}, refs)
    }
  end

  ## Internals: the queries ------------------------------------------------------

  defp columns_of(%Board{} = board) do
    Repo.all(
      from(c in Slipdock.Boards.Column,
        where: c.board_id == ^board.id,
        order_by: [asc: c.position, asc: c.id]
      )
    )
  end

  defp tags_of(%Board{} = root),
    do: Repo.all(from(t in Tag, where: t.board_id == ^root.id, order_by: [asc: t.name]))

  defp fields_of(%Board{} = root),
    do:
      Repo.all(
        from(f in FieldDefinition,
          where: f.board_id == ^root.id,
          order_by: [asc: f.position, asc: f.id]
        )
      )

  defp milestones_of(%Board{} = root),
    do:
      Repo.all(
        from(m in Milestone, where: m.board_id == ^root.id, order_by: [asc: m.date, asc: m.id])
      )

  defp saved_views_of(%Board{} = root),
    do: Repo.all(from(v in SavedView, where: v.board_id == ^root.id, order_by: [asc: v.name]))

  defp folders_in(board_ids) do
    Repo.all(
      from(f in Folder,
        where: f.board_id in ^board_ids,
        order_by: [asc: f.position, asc: f.id]
      )
    )
  end

  defp cards_in(board_ids, opts) do
    query =
      from(c in Card,
        where: c.board_id in ^board_ids,
        order_by: [asc: c.board_id, asc: c.position, asc: c.id]
      )

    query = if opts[:archived_cards], do: query, else: where(query, [c], is_nil(c.archived_at))

    Repo.all(query)
  end

  defp pages_in(board_ids, opts) do
    query =
      from(p in Page,
        where: p.board_id in ^board_ids,
        order_by: [asc: p.board_id, asc: p.position, asc: p.id]
      )

    query = if opts[:archived_pages], do: query, else: where(query, [p], is_nil(p.archived_at))

    Repo.all(query)
  end

  # One query per kind of thing, for every card and page in the tree at once.
  # Rows that hang off a card or a page are keyed {:card, id} / {:page, id};
  # each list keeps its query's order.
  defp load_attached(boards, cards, pages) do
    card_ids = Enum.map(cards, & &1.id)
    page_ids = Enum.map(pages, & &1.id)

    owned = fn query ->
      from(r in query, where: r.card_id in ^card_ids or r.page_id in ^page_ids)
      |> Repo.all()
      |> Enum.group_by(&owner_key/1, &Map.drop(&1, [:card_id, :page_id]))
    end

    assignees =
      from(a in "card_assignees",
        where: a.card_id in ^card_ids,
        select: {a.card_id, a.user_id}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    statuses =
      owned.(
        from(s in StatusUpdate,
          order_by: [asc: s.inserted_at, asc: s.id],
          select: %{
            card_id: s.card_id,
            page_id: s.page_id,
            health: s.health,
            body: s.body,
            written_at: s.inserted_at,
            author_id: s.user_id
          }
        )
      )

    user_ids =
      Enum.map(cards, & &1.assignee_id) ++
        Enum.map(pages, & &1.assignee_id) ++
        Enum.concat(Map.values(assignees)) ++
        (statuses |> Map.values() |> Enum.concat() |> Enum.map(& &1.author_id))

    user_ids = user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      sub_boards:
        for(
          %Board{parent_card_id: card_id, id: id} <- boards,
          card_id,
          into: %{},
          do: {card_id, id}
        ),
      assignees: assignees,
      emails:
        Map.new(Repo.all(from(u in User, where: u.id in ^user_ids, select: {u.id, u.email}))),
      tags:
        from(t in "card_tags",
          where: t.card_id in ^card_ids,
          order_by: [asc: t.tag_id],
          select: {t.card_id, t.tag_id}
        )
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)),
      blockers:
        from(d in "card_dependencies",
          where: d.blocked_id in ^card_ids,
          order_by: [asc: d.blocker_id],
          select: {d.blocked_id, d.blocker_id}
        )
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)),
      links:
        from(l in CardLink, where: l.from_id in ^card_ids, order_by: [asc: l.id])
        |> Repo.all()
        |> Enum.group_by(& &1.from_id),
      checklist:
        owned.(
          from(i in ChecklistItem,
            order_by: [asc: i.position, asc: i.id],
            select: %{
              card_id: i.card_id,
              page_id: i.page_id,
              text: i.text,
              done: i.done,
              position: i.position
            }
          )
        ),
      comments:
        owned.(
          from(c in Comment,
            order_by: [asc: c.inserted_at, asc: c.id],
            select: %{
              card_id: c.card_id,
              page_id: c.page_id,
              body: c.body,
              written_at: c.inserted_at
            }
          )
        ),
      statuses: statuses,
      urls:
        owned.(
          from(u in CardUrl,
            order_by: [asc: u.inserted_at, asc: u.id],
            select: %{card_id: u.card_id, page_id: u.page_id, url: u.url, title: u.title}
          )
        ),
      field_values:
        from(v in FieldValue,
          where: v.card_id in ^card_ids or v.page_id in ^page_ids,
          order_by: [asc: v.id]
        )
        |> Repo.all()
        |> Enum.group_by(&owner_key/1)
    }
  end

  defp owner_key(%{card_id: id}) when not is_nil(id), do: {:card, id}
  defp owner_key(%{page_id: id}), do: {:page, id}

  defp owned(refs, kind, key), do: Map.get(refs.loaded[kind], key, [])

  # Lead first, then the rest in id order — as `Boards.assignee_ids/1` has it.
  defp assignee_ids(%Card{id: id, assignee_id: lead}, refs) do
    ids = Map.get(refs.loaded.assignees, id, [])
    if lead in ids, do: [lead | List.delete(ids, lead)], else: Enum.sort(ids)
  end

  defp tag_refs(card_id, refs) do
    refs.loaded.tags
    |> Map.get(card_id, [])
    |> Enum.map(&refs.tags[&1])
    |> Enum.reject(&is_nil/1)
  end

  defp dependency_refs(card_id, refs) do
    refs.loaded.blockers
    |> Map.get(card_id, [])
    |> Enum.map(&refs.cards[&1])
    |> Enum.reject(&is_nil/1)
  end

  defp link_json(card_id, refs) do
    refs.loaded.links
    |> Map.get(card_id, [])
    |> Enum.map(&%{kind: &1.kind, to: refs.cards[&1.to_id]})
    |> Enum.reject(&is_nil(&1.to))
  end

  defp status_json(key, refs) do
    refs
    |> owned(:statuses, key)
    |> Enum.map(fn update ->
      update |> Map.put(:author, email_of(update.author_id, refs)) |> Map.delete(:author_id)
    end)
  end

  defp field_value_json(key, refs) do
    refs
    |> owned(:field_values, key)
    |> Enum.map(
      &%{
        field: refs.fields[&1.field_id],
        number: &1.number,
        text: &1.text,
        date: &1.date,
        option: &1.option
      }
    )
    |> Enum.reject(&is_nil(&1.field))
  end

  defp email_of(nil, _refs), do: nil
  defp email_of(user_id, refs), do: refs.loaded.emails[user_id]

  ## Internals: the warnings -----------------------------------------------------

  defp attachment_count([]), do: 0

  defp attachment_count(board_ids) do
    Repo.one(
      from(a in Slipdock.Boards.Attachment,
        join: c in Card,
        on: c.id == a.card_id,
        where: c.board_id in ^board_ids,
        select: count(a.id)
      )
    ) || 0
  end

  defp vote_count([]), do: 0

  defp vote_count(board_ids) do
    Repo.one(
      from(v in Slipdock.Boards.Vote,
        join: c in Card,
        on: c.id == v.card_id,
        where: c.board_id in ^board_ids,
        select: count(v.id)
      )
    ) || 0
  end

  defp revision_count([]), do: 0

  defp revision_count(board_ids) do
    Repo.one(
      from(r in Slipdock.Wiki.Revision,
        join: p in Page,
        on: p.id == r.page_id,
        where: p.board_id in ^board_ids,
        select: count(r.id)
      )
    ) || 0
  end
end
