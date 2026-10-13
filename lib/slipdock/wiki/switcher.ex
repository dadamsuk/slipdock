defmodule Slipdock.Wiki.Switcher do
  @moduledoc """
  The quick switcher (W-103 R11.4): type a few letters of a note's title, one
  of its aliases or its path, and open it. Ctrl/Cmd-O on a wiki.

  Matching is fuzzy the way editors' switchers are: the letters typed must
  come in order, not side by side, so `acmcall` finds `Jobs/Acme/Call`. A
  match scores higher for letters that run together, for starting a word, a
  path segment or the whole text, and for a shorter text; the title counts
  for more than an alias, and an alias for more than the path.

  What it searches is gathered once, when the switcher opens (`pool/2`): every
  page of the vault the board is in — or the board alone, outside a vault —
  that the reader may open, with its path, and never a body. Each keystroke
  then scores that pool in memory (`search/3`), which on 10,000 notes takes a
  few milliseconds rather than a query.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo, Vaults}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Vaults.Layout
  alias Slipdock.Wiki.{Folders, Page}

  @type entry :: %{
          id: pos_integer,
          board_id: pos_integer,
          board: String.t(),
          title: String.t(),
          slug: String.t(),
          code: String.t(),
          aliases: [String.t()],
          path: String.t(),
          updated_at: DateTime.t()
        }

  @doc """
  The pages the switcher on `board` searches, for `user`: the whole vault's
  when the board is in one (paths as the vault lays them out), else the
  board's own (paths as its folders do). Drafts only on boards the reader can
  write to; archived pages never.
  """
  @spec pool(User.t(), Board.t()) :: [entry]
  def pool(%User{} = user, %Board{} = board) do
    case Vaults.for_board(board) do
      nil -> board_pool(user, [board], nil)
      vault -> vault_pool(user, vault)
    end
  end

  defp vault_pool(user, vault) do
    boards =
      vault
      |> Vaults.board_ids()
      |> then(&Repo.all(from(b in Board, where: b.id in ^&1)))

    board_pool(user, boards, Layout.build(vault))
  end

  defp board_pool(user, boards, layout) do
    levels =
      for board <- boards,
          perm = Access.board_permission(user, board),
          Access.can_read?(perm),
          into: %{},
          do: {board.id, {board, Access.can_write?(perm)}}

    folder_paths =
      if layout,
        do: %{},
        else:
          levels
          |> Map.keys()
          |> Enum.flat_map(&Folders.outline(Folders.list(&1)))
          |> Map.new(&{&1.folder.id, &1.path})

    from(p in Page,
      where: p.board_id in ^Map.keys(levels) and is_nil(p.archived_at),
      select:
        map(p, [
          :id,
          :board_id,
          :title,
          :slug,
          :code,
          :aliases,
          :status,
          :folder_id,
          :updated_at
        ])
    )
    |> Repo.all()
    |> Enum.filter(fn page ->
      {_board, writer} = levels[page.board_id]
      page.status != "draft" or writer
    end)
    |> Enum.map(fn page ->
      {board, _writer} = levels[page.board_id]

      path = path_of(page, layout, folder_paths)
      aliases = page.aliases || []

      %{
        id: page.id,
        board_id: page.board_id,
        board: board.name,
        title: page.title,
        slug: page.slug,
        code: page.code,
        aliases: aliases,
        path: path,
        updated_at: page.updated_at,
        # Every name at once, lower case: one cheap look rules most pages
        # out before any of them is scored.
        haystack: String.downcase(Enum.join([page.title, path | aliases], "\n"))
      }
    end)
  end

  # Where the page sits, written as a path without the `.md`: the vault's
  # layout when there is one, else its folder's path and its title.
  defp path_of(page, nil, folder_paths) do
    case folder_paths[page.folder_id] do
      nil -> page.title
      dir -> dir <> "/" <> page.title
    end
  end

  defp path_of(page, layout, _folder_paths) do
    case layout.pages[page.id] do
      %{path: path} ->
        path |> String.replace_suffix(".md", "") |> String.replace_suffix("/index", "")

      nil ->
        page.title
    end
  end

  @doc """
  The best `limit` matches in `pool` for `query`, best first, each with
  `:matched` saying which of its names matched (`:title`, `{:alias, name}`,
  `:path`, or `:code` for a page's code typed whole). An empty query gives
  the pages changed most lately.
  """
  def search(pool, query, limit \\ 12) do
    case String.downcase(String.trim(query || "")) do
      "" ->
        pool
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
        |> Enum.take(limit)
        |> Enum.map(&Map.put(&1, :matched, :recent))

      q ->
        letters = q |> String.replace(~r/\s+/u, "") |> String.graphemes()
        # A page's code (`W-31`), typed whole, is that page and goes first,
        # as it does in the card finder.
        code = String.upcase(q)

        coded =
          pool
          |> Enum.filter(&(&1.code == code))
          |> Enum.map(&Map.put(&1, :matched, :code))

        pool
        |> Enum.reject(&(&1.code == code))
        |> Enum.filter(&subsequence?(&1.haystack, letters))
        |> Enum.flat_map(fn entry ->
          case best(entry, q) do
            nil -> []
            {score, matched} -> [{score, Map.put(entry, :matched, matched)}]
          end
        end)
        |> Enum.sort_by(fn {score, entry} -> {-score, String.length(entry.title)} end)
        |> Enum.map(&elem(&1, 1))
        |> then(&(coded ++ &1))
        |> Enum.take(limit)
    end
  end

  # Whether the letters come in order somewhere in the text.
  defp subsequence?(_text, []), do: true

  defp subsequence?(text, [c | rest]) do
    case :binary.match(text, c) do
      {at, len} -> subsequence?(binary_part(text, at + len, byte_size(text) - at - len), rest)
      :nomatch -> false
    end
  end

  # The entry's best name for the query, and which one it was. The title is
  # worth most; an alias nearly as much; the path, which holds every folder
  # name above the page too, least.
  defp best(entry, q) do
    [
      {score(q, entry.title), 1.0, :title},
      {score(q, entry.path), 0.7, :path}
      | Enum.map(entry.aliases, &{score(q, &1), 0.9, {:alias, &1}})
    ]
    |> Enum.reject(fn {score, _w, _what} -> is_nil(score) end)
    |> Enum.map(fn {score, weight, what} -> {score * weight, what} end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
  end

  @doc """
  How well `query` matches `text` in order, or nil when it does not: higher
  is better. Both are compared case aside, and spaces in the query match
  anything.
  """
  def score(query, text) when is_binary(query) and is_binary(text) do
    q = query |> String.downcase() |> String.replace(~r/\s+/u, "") |> String.graphemes()
    t = text |> String.downcase() |> String.graphemes()
    lower = String.downcase(text)
    whole = String.downcase(String.trim(query))

    case positions(q, t) do
      nil ->
        nil

      [first | _] = at ->
        runs = at |> Enum.chunk_every(2, 1, :discard) |> Enum.count(fn [a, b] -> b == a + 1 end)
        starts = Enum.count(at, &word_start?(t, &1))
        gaps = List.last(at) - first + 1 - length(at)

        length(at) * 1.0 + runs * 4 + starts * 6 +
          if(first == 0, do: 8, else: 0) +
          if(String.starts_with?(lower, whole), do: 30, else: 0) +
          terms_found(whole, lower) - gaps * 0.2 - length(t) * 0.02
    end
  end

  # Each word of the query found whole in the text counts, and more when it
  # starts a word there: `note 4242` wants the note with 4242 in it, not
  # the one where a 4, a 2, a 4 and a 2 happen to come in order.
  defp terms_found(query, text) do
    query
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(fn term ->
      cond do
        String.starts_with?(text, term) -> 20
        Regex.match?(~r/(^|[\s\/\-_.(\[])#{Regex.escape(term)}/u, text) -> 20
        String.contains?(text, term) -> 10
        true -> 0
      end
    end)
    |> Enum.sum()
  end

  # Where each letter of the query falls in the text, each after the last:
  # taken at a word's start when one comes before the next plain match, so
  # `ac` in `a big acme` lands on `acme`, not on the `a` of `a big`.
  defp positions([], _text), do: []

  defp positions(q, text) do
    indexed = Enum.with_index(text)
    walk(q, indexed, -1, [], text)
  end

  defp walk([], _indexed, _after, acc, _text), do: Enum.reverse(acc)

  defp walk([c | rest], indexed, after_pos, acc, text) do
    candidates = for {^c, i} <- indexed, i > after_pos, do: i

    case candidates do
      [] ->
        nil

      [first | _] ->
        # Prefer a word start, or the place right after the last match, if
        # the rest of the query still fits after it.
        preferred =
          Enum.find(candidates, fn i -> i == after_pos + 1 or word_start?(text, i) end)

        pick =
          if preferred && fits?(rest, indexed, preferred), do: preferred, else: first

        walk(rest, indexed, pick, [pick | acc], text)
    end
  end

  defp fits?([], _indexed, _after), do: true

  defp fits?([c | rest], indexed, after_pos) do
    case Enum.find(indexed, fn {g, i} -> g == c and i > after_pos end) do
      nil -> false
      {_g, i} -> fits?(rest, indexed, i)
    end
  end

  defp word_start?(_text, 0), do: true

  defp word_start?(text, i),
    do: Enum.at(text, i - 1) in [" ", "/", "-", "_", ".", "(", "["]
end
