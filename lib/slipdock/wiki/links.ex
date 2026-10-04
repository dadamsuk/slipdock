defmodule Slipdock.Wiki.Links do
  @moduledoc """
  What a page points at: pulling references out of a body, resolving them to
  real things, and keeping `page_links` in step with the prose.

  Three jobs, deliberately separate:

    * **Extraction** is pure. `extract/1` walks the document's syntax tree
      and lexes only its text nodes with `Slipdock.Wiki.Markup`, so a
      `[[link]]` inside backticks or a fenced block is never a link.
    * **Resolution** hits the database and, optionally, a reader's
      permissions. The store-time resolution is unfiltered — the index is
      about what the prose says, not about who is looking — while render-time
      resolution is filtered, so a card chip degrades to plain text for
      someone who cannot open the card.
    * **Reconciliation** replaces a page's rows after every save. Only
      `pinned` survives, because only `pinned` was not written in the body.

  Renaming is the case worth knowing about. Once a link resolves it is stored
  by **id**, so renaming a page cannot break the links into it. A link that
  never resolved is stored by the words somebody wrote, and starts working
  the day a page with that title appears.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Boards, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Comment, SavedView, StatusUpdate}
  alias Slipdock.Wiki.{Link, Markup, Page}

  @type resolution :: %{
          required(:kind) => Markup.kind(),
          required(:raw) => String.t(),
          required(:target) => String.t(),
          required(:label) => String.t() | nil,
          required(:board) => String.t() | nil,
          required(:count) => pos_integer,
          required(:to) => term | nil
        }

  ## Extraction ---------------------------------------------------------------

  @doc """
  Every reference in `body`, in the order first written, with how many times
  each appears — so a page *about* a thing outranks a passing mention of it.
  """
  @spec extract(String.t() | nil) :: [map]
  def extract(nil), do: []

  def extract(body) do
    body
    |> text_runs()
    |> Enum.flat_map(&Markup.refs/1)
    |> tally()
  end

  @doc "The plain-text runs of a Markdown body: everything that is not code."
  @spec text_runs(String.t()) :: [String.t()]
  def text_runs(body) do
    case MDEx.parse_document(body,
           extension: [
             table: true,
             tasklist: true,
             strikethrough: true,
             autolink: true,
             footnotes: true
           ]
         ) do
      {:ok, doc} -> doc |> Enum.flat_map(&literal/1)
      _ -> [body]
    end
  end

  defp literal(%MDEx.Text{literal: text}), do: [text]
  defp literal(_), do: []

  # Counted by what was written, so `[[Retry policy]]` twice is one row with
  # a count of two, and `[[retry-policy]]` beside it is a row of its own.
  defp tally(refs) do
    refs
    |> Enum.reduce({[], %{}}, fn ref, {order, counts} ->
      key = {ref.kind, ref.board, ref.target, ref.label}

      case counts do
        %{^key => _} -> {order, Map.update!(counts, key, &(&1 + 1))}
        _ -> {[{key, ref} | order], Map.put(counts, key, 1)}
      end
    end)
    |> then(fn {order, counts} ->
      order
      |> Enum.reverse()
      |> Enum.map(fn {key, ref} -> Map.put(ref, :count, counts[key]) end)
    end)
  end

  ## Resolution ---------------------------------------------------------------

  @doc """
  Attaches a target to each reference: `{:page, page}`, `{:card, card}`,
  `{:board, board}`, `{:view, view}`, `{:mention, user}`, `{:directive, name}`
  or `nil` when nothing answers to it.

  `board` is the page's own board, which is what an unqualified reference is
  read against. Options:

    * `:as` — a `%User{}`, in which case a target that reader cannot see
      resolves to `nil`. Leave it out to resolve as the system, which is what
      the stored index wants.
  """
  @spec resolve(Board.t(), [map], keyword) :: [resolution]
  def resolve(%Board{} = board, refs, opts \\ []) do
    reader = Keyword.get(opts, :as)
    Enum.map(refs, &Map.put(&1, :to, target(board, &1, reader)))
  end

  defp target(board, %{kind: :page} = ref, reader) do
    scope = board_for(board, ref.board)

    with %Board{} <- scope,
         {:ok, page} <- Slipdock.Wiki.find_page(scope, ref.target),
         true <- visible_page?(page, reader) do
      {:page, page}
    else
      _ -> nil
    end
  end

  defp target(_board, %{kind: :card} = ref, reader) do
    with {id, ""} <- Integer.parse(ref.target),
         %Card{} = card <- Repo.get(Card, id),
         true <- readable_card?(card, reader) do
      {:card, Repo.preload(card, [:column, :assignee, :assignees])}
    else
      _ -> nil
    end
  end

  defp target(_board, %{kind: :board} = ref, reader) do
    with {:ok, found} <- Boards.find_board(ref.target),
         true <- readable_board?(found, reader) do
      {:board, found}
    else
      _ -> nil
    end
  end

  defp target(board, %{kind: :view} = ref, reader) do
    scope = board_for(board, ref.board)

    with %Board{} <- scope,
         {:ok, view} <- Boards.find_saved_view(scope, ref.target),
         true <- readable_view?(view, reader) do
      {:view, view}
    else
      _ -> nil
    end
  end

  defp target(board, %{kind: :mention} = ref, _reader) do
    case member_named(board, ref.target) do
      %User{} = user -> {:mention, user}
      _ -> nil
    end
  end

  defp target(_board, %{kind: :directive, target: name}, _reader), do: {:directive, name}

  # An inline query is answered by `Slipdock.Wiki.Query`, not resolved to a
  # row; anything else unknown simply points at nothing.
  defp target(_board, _ref, _reader), do: nil

  # An unqualified reference means "this board"; a qualified one names
  # another by code or name, and silently resolves to nothing when there is
  # no such board — a typo should not become a link to somewhere else.
  defp board_for(board, nil), do: board

  defp board_for(_board, ref) do
    case Boards.find_board(ref) do
      {:ok, found} -> found
      _ -> nil
    end
  end

  defp visible_page?(_page, nil), do: true

  defp visible_page?(page, %User{} = reader),
    do: Slipdock.Wiki.visible?(page, Access.page_permission(reader, page))

  defp readable_card?(_card, nil), do: true

  defp readable_card?(card, %User{} = reader),
    do: Access.can_read?(Access.card_permission(reader, card))

  defp readable_board?(_board, nil), do: true

  defp readable_board?(board, %User{} = reader),
    do: Access.can_read?(Access.board_permission(reader, board))

  defp readable_view?(_view, nil), do: true

  defp readable_view?(view, %User{} = reader),
    do: Access.can_read?(Access.view_permission(reader, view))

  # A mention resolves against the people who can actually see the board, so
  # `@someone` who is not on it stays literal text rather than becoming a
  # link to a stranger.
  defp member_named(%Board{} = board, name) do
    wanted = String.downcase(name)

    board
    |> members()
    |> Enum.find(fn user ->
      String.downcase(user.email) == wanted or
        String.downcase(to_string(user.name)) == wanted or
        handle(user) == wanted
    end)
  end

  @doc """
  The people who can read this board: its owner, and everyone granted access.

  The candidates come from grants anywhere in the board's tree, and each is
  then asked whether they can read *this* board: a grant on one sub-board
  reaches that sub-board and nothing above or beside it, and somebody who
  holds one must not be offered, linked or emailed from the rest of the tree.
  """
  def members(%Board{} = board) do
    root_id = Board.root_id(board)

    grant_user_ids =
      from(g in Slipdock.Access.Grant,
        left_join: b in Board,
        on: b.id == g.board_id,
        where: g.board_id == ^board.id or g.board_id == ^root_id or b.root_id == ^root_id,
        where: not is_nil(g.user_id),
        select: g.user_id
      )
      |> Repo.all()

    group_user_ids =
      from(g in Slipdock.Access.Grant,
        join: m in "group_members",
        on: m.group_id == g.group_id,
        left_join: b in Board,
        on: b.id == g.board_id,
        where: g.board_id == ^board.id or g.board_id == ^root_id or b.root_id == ^root_id,
        select: m.user_id
      )
      |> Repo.all()

    ids = Enum.uniq([board.owner_id | grant_user_ids ++ group_user_ids]) |> Enum.reject(&is_nil/1)

    from(u in User, where: u.id in ^ids, order_by: [asc: u.email])
    |> Repo.all()
    |> Enum.filter(&Access.can_read?(Access.board_permission(&1, board)))
  end

  @doc ~S'The `@handle` a user answers to: the part of their email before the "@".'
  def handle(%User{email: email}), do: email |> String.split("@") |> hd() |> String.downcase()

  ## Reconciliation -----------------------------------------------------------

  @doc """
  Rewrites a page's `page_links` from its body. Called on every save.

  Rows written in the prose are rebuilt from the prose. Two kinds are not,
  and are carried across a rebuild rather than deleted with it:

    * **pinned** rows — "this page is *the* spec for that card" is a
      person's judgement, not something the prose says; and
    * **recorded** rows (`count: 0`) — a relation `record/2` kept when there
      was nowhere in the prose to write it.

  Both used to survive only if the body happened to mention the same target,
  which meant "Write it up" lost its card the moment somebody replaced the
  stub text it came with. The relation is the point: a page that explains a
  card is no use if the person looking at the card cannot see it exists.
  """
  def reconcile(%Page{} = page) do
    board = Repo.get!(Board, page.board_id)
    kept = kept_rows(page)

    resolutions =
      page.body
      |> extract()
      |> then(&resolve(board, &1))
      # Directives, mentions and inline queries are not references to a
      # thing; they are instructions to the renderer.
      |> Enum.reject(&(&1.kind in [:directive, :mention, :inline]))

    Repo.transaction(fn ->
      Repo.delete_all(from(l in Link, where: l.page_id == ^page.id))

      written =
        Enum.map(resolutions, fn resolution ->
          attrs = row_attrs(page, resolution)
          key = pin_key(attrs)

          %Link{}
          |> Link.changeset(Map.put(attrs, :pinned, match?(%{pinned: true}, kept[key])))
          |> Repo.insert!()

          key
        end)

      kept
      |> Map.drop(written)
      |> Enum.each(fn {_key, row} ->
        %Link{} |> Link.changeset(Map.put(row, :page_id, page.id)) |> Repo.insert!()
      end)
    end)

    :ok
  end

  @doc """
  Rewrites the links written in a comment. Called whenever one is saved.

  A comment is writing too: "see [[Retry policy]]" on a card belongs in that
  page's backlinks, and the card it was written on is what the backlink shows.
  Only page references are kept — a comment mentioning `#412` is already a
  card talking about a card, and the board has better ways to say that.
  """
  def reconcile_comment(%Comment{card_id: id} = comment) when is_integer(id) do
    card = Repo.get!(Card, id)
    reconcile_from(%{source_comment_id: comment.id, source_card_id: card.id}, card, comment.body)
  end

  # A comment on a *page*. `page_id` on the row is the source — the page the
  # remark was written on — which is what a backlink names, exactly as it
  # names the card for a comment on a card.
  def reconcile_comment(%Comment{page_id: id} = comment) when is_integer(id) do
    page = Repo.get!(Page, id)
    reconcile_from(%{source_comment_id: comment.id, source_page_id: page.id}, page, comment.body)
  end

  @doc "The same for a status update's note."
  def reconcile_status(%StatusUpdate{card_id: id} = status) when is_integer(id) do
    card = Repo.get!(Card, id)
    reconcile_from(%{source_status_id: status.id, source_card_id: card.id}, card, status.body)
  end

  def reconcile_status(%StatusUpdate{page_id: id} = status) when is_integer(id) do
    page = Repo.get!(Page, id)
    reconcile_from(%{source_status_id: status.id, source_page_id: page.id}, page, status.body)
  end

  defp reconcile_from(source, %{board_id: board_id}, text) do
    board = Repo.get!(Board, board_id)

    Repo.delete_all(from(l in Link, where: ^source_clause(source)))

    text
    |> extract()
    |> Enum.filter(&(&1.kind == :page))
    |> then(&resolve(board, &1))
    |> Enum.each(fn resolution ->
      %Link{}
      |> Link.changeset(Map.merge(source, link_attrs(resolution)))
      |> Repo.insert!()
    end)

    :ok
  end

  defp source_clause(%{source_comment_id: id}), do: dynamic([l], l.source_comment_id == ^id)
  defp source_clause(%{source_status_id: id}), do: dynamic([l], l.source_status_id == ^id)

  # The rows on this page that the body did not write: pins somebody set, and
  # relations `record/2` kept. Keyed by target so a rebuilt row can claim its
  # pin, and anything the prose no longer mentions can be put back as it was.
  defp kept_rows(%Page{id: id}) do
    from(l in Link, where: l.page_id == ^id, where: l.pinned or l.count == 0)
    |> Repo.all()
    |> Map.new(fn link ->
      attrs = Map.from_struct(link)

      {pin_key(attrs),
       %{
         kind: link.kind,
         raw: link.raw,
         label: link.label,
         resolved: link.resolved,
         pinned: link.pinned,
         count: 0,
         target_page_id: link.target_page_id,
         target_card_id: link.target_card_id,
         target_board_id: link.target_board_id,
         target_view_id: link.target_view_id
       }}
    end)
  end

  defp pin_key(attrs) do
    {attrs[:kind] || attrs.kind, attrs[:target_page_id], attrs[:target_card_id],
     attrs[:target_board_id], attrs[:target_view_id]}
  end

  defp row_attrs(%Page{} = page, resolution),
    do: Map.put(link_attrs(resolution), :page_id, page.id)

  defp link_attrs(resolution) do
    base = %{
      kind: to_string(resolution.kind),
      raw: resolution.raw,
      label: resolution.label,
      count: resolution.count,
      resolved: not is_nil(resolution.to),
      target_page_id: nil,
      target_card_id: nil,
      target_board_id: nil,
      target_view_id: nil
    }

    case resolution.to do
      {:page, %Page{id: id}} -> %{base | target_page_id: id}
      {:card, %Card{id: id}} -> %{base | target_card_id: id}
      {:board, %Board{id: id}} -> %{base | target_board_id: id}
      {:view, %SavedView{id: id}} -> %{base | target_view_id: id}
      _ -> base
    end
  end

  ## Reading the graph --------------------------------------------------------

  @doc "The links written *in* this page, resolved rows first."
  def outgoing(%Page{id: id}) do
    from(l in Link,
      where: l.page_id == ^id,
      order_by: [desc: l.resolved, desc: l.count, asc: l.id]
    )
    |> Repo.all()
    |> Repo.preload([:target_page, :target_card, :target_board, :target_view])
  end

  @doc """
  Everything that links *to* this page: pinned first, then by how often it is
  mentioned, so a page about the subject beats a page that name-dropped it.

  Filtered by the reader, since a backlink from a page they cannot open would
  tell them it exists.
  """
  def backlinks(%Page{id: id}, reader \\ nil) do
    from(l in Link, where: l.target_page_id == ^id, order_by: [desc: l.pinned, desc: l.count])
    |> Repo.all()
    |> Repo.preload([:source_page, page: [:board], source_card: [:column]])
    |> Enum.map(&name_the_source/1)
    |> Enum.filter(&readable_link_source?(&1, reader))
  end

  @doc "The pages that reference a card, pinned first — the card's Docs section."
  def for_card(%Card{id: id}, reader \\ nil) do
    from(l in Link, where: l.target_card_id == ^id, order_by: [desc: l.pinned, desc: l.count])
    |> Repo.all()
    |> Repo.preload([:source_page, page: [:board], source_card: [:column]])
    |> Enum.map(&name_the_source/1)
    |> Enum.filter(&readable_link_source?(&1, reader))
  end

  # What a backlink shows is the page it was written on, and a comment left
  # on a page was written on that page as surely as its body was. Filling
  # `page` in from `source_page` means every reader of a backlink — the
  # permission check below, the sidebar, the API — asks one question rather
  # than two.
  defp name_the_source(%Link{page_id: nil, source_page: %Page{} = page} = link),
    do: %{link | page: page}

  defp name_the_source(link), do: link

  defp readable_link_source?(%Link{page: %Page{} = page}, nil), do: live_page?(page)

  defp readable_link_source?(%Link{page: %Page{} = page}, %User{} = reader) do
    live_page?(page) and Slipdock.Wiki.visible?(page, Access.page_permission(reader, page))
  end

  # A link written on a card is as readable as the card.
  defp readable_link_source?(%Link{source_card: %Card{} = card}, nil),
    do: is_nil(card.archived_at)

  defp readable_link_source?(%Link{source_card: %Card{} = card}, %User{} = reader),
    do: is_nil(card.archived_at) and Access.can_read?(Access.card_permission(reader, card))

  defp readable_link_source?(_link, _reader), do: false

  # A page that has been put away is not writing anyone is meant to be
  # reading — and neither is a page on a board that has been put away. An
  # archived board is the whole project shelved, and a card elsewhere should
  # not still be pointing at its documents.
  defp live_page?(%Page{} = page) do
    not Page.archived?(page) and
      not match?(%Board{archived_at: %DateTime{}}, page.board)
  end

  @doc """
  Pages linked to but never written, most-wanted first.

  This is the classic way a wiki grows, and a good work queue: the pages
  people keep reaching for are the pages worth writing.
  """
  def wanted(%Board{} = board) do
    page_ids = from(p in Page, where: p.board_id == ^board.id, select: p.id)

    from(l in Link,
      where: l.page_id in subquery(page_ids),
      where: l.kind == "page" and not l.resolved
    )
    |> Repo.all()
    |> Repo.preload(page: [])
    |> Enum.group_by(& &1.raw)
    |> Enum.map(fn {raw, links} ->
      %{
        raw: raw,
        title: title_of(hd(links)),
        count: Enum.sum(Enum.map(links, & &1.count)),
        from: links |> Enum.map(& &1.page) |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.id)
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.title})
  end

  # What a "create this page" link should be pre-titled with: the words as
  # written, without the brackets or the display label.
  defp title_of(%Link{raw: raw, label: label}) do
    inner =
      raw
      |> String.trim_leading("[[")
      |> String.trim_trailing("]]")
      |> String.split("|", parts: 2)
      |> hd()
      |> String.trim()

    case String.split(inner, "/", parts: 2) do
      [_board, page] -> page
      [page] -> if label, do: page, else: page
    end
  end

  ## Pinning ------------------------------------------------------------------

  @doc """
  Marks (or unmarks) a link as *the* page for what it points at.

  A pin is meaning, not prose: it says this page is the spec, the runbook or
  the retro for that card, which is why the card shows it prominently and why
  it survives a rebuild of the rest of the row. Pinning from either end is
  the same row.
  """
  def pin(page, target, pinned \\ true)

  # Unpinning is `unlink/2`: a row the prose never wrote has nothing left to
  # say once the pin is off, and leaving it behind would keep the page listed
  # on the card it was just taken off.
  def pin(%Page{} = page, target, false), do: unlink(page, target)

  def pin(%Page{} = page, target, true) do
    clause = target_clause(target)

    case Repo.one(from(l in Link, where: l.page_id == ^page.id, where: ^clause)) do
      nil ->
        # Pinning something the prose does not mention still records the
        # relation; the next save will fill in the count from the body.
        %Link{}
        |> Link.changeset(Map.merge(bare_attrs(page, target), %{pinned: true}))
        |> Repo.insert()

      %Link{} = link ->
        link |> Link.changeset(%{pinned: true}) |> Repo.update()
    end
  end

  @doc """
  Records that a page relates to something, without claiming it is *the* page
  for it. Used when a link cannot be written into the prose — a passage that
  was reflowed, say — so the relation is kept rather than lost.
  """
  def record(%Page{} = page, target) do
    clause = target_clause(target)

    case Repo.one(from(l in Link, where: l.page_id == ^page.id, where: ^clause)) do
      nil -> %Link{} |> Link.changeset(bare_attrs(page, target)) |> Repo.insert()
      %Link{} = link -> {:ok, link}
    end
  end

  @doc """
  Takes a relation off a page: the opposite of `record/2`.

  A row the prose wrote is only unpinned, not deleted — the page really does
  mention that card, and the next save would put the row back anyway. A row
  nothing in the prose accounts for goes.
  """
  def unlink(%Page{} = page, target) do
    clause = target_clause(target)

    case Repo.one(from(l in Link, where: l.page_id == ^page.id, where: ^clause)) do
      nil -> {:ok, nil}
      %Link{count: 0} = link -> Repo.delete(link)
      %Link{} = link -> link |> Link.changeset(%{pinned: false}) |> Repo.update()
    end
  end

  defp target_clause({:card, %Card{id: id}}), do: dynamic([l], l.target_card_id == ^id)
  defp target_clause({:page, %Page{id: id}}), do: dynamic([l], l.target_page_id == ^id)
  defp target_clause({:board, %Board{id: id}}), do: dynamic([l], l.target_board_id == ^id)
  defp target_clause({:view, %SavedView{id: id}}), do: dynamic([l], l.target_view_id == ^id)

  defp bare_attrs(%Page{id: page_id}, {:card, %Card{} = card}),
    do: %{
      page_id: page_id,
      kind: "card",
      raw: "##{card.id}",
      resolved: true,
      count: 0,
      target_card_id: card.id
    }

  defp bare_attrs(%Page{id: page_id}, {:page, %Page{} = other}),
    do: %{
      page_id: page_id,
      kind: "page",
      raw: other.code,
      resolved: true,
      count: 0,
      target_page_id: other.id
    }

  defp bare_attrs(%Page{id: page_id}, {:board, %Board{} = board}),
    do: %{
      page_id: page_id,
      kind: "board",
      raw: "[[board:#{board.code}]]",
      resolved: true,
      count: 0,
      target_board_id: board.id
    }

  defp bare_attrs(%Page{id: page_id}, {:view, %SavedView{} = view}),
    do: %{
      page_id: page_id,
      kind: "view",
      raw: "[[view:#{view.name}]]",
      resolved: true,
      count: 0,
      target_view_id: view.id
    }
end
