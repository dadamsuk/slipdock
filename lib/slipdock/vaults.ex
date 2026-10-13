defmodule Slipdock.Vaults do
  @moduledoc """
  Vaults: Obsidian-style vaults made of board wikis (W-103).

  A vault belongs to one person and is nothing but a name and a set of
  **mappings**, each a vault path → a board's wiki or one folder of it. The
  pages stay where they always were, on their boards, with the boards'
  permissions; the vault is the map that lays those wikis out as one tree of
  files, and the set of boards a plain `[[link]]` is looked for across.

  Three rules hold the model together:

    * **Longest prefix wins.** A mapping inside another is allowed — `/Jobs`
      inside `/` — and a vault path belongs to the deepest mapping that
      contains it (`locate/2`).
    * **A target is somewhere you can write.** A vault is for writing into;
      mapping a board you can only read would make a vault you cannot sync.
    * **A board belongs to one vault.** It may be mapped more than once in
      that vault (its root at `/`, a folder of it at `/Projects/X`), but not
      into two vaults, because "which vault is this board in" has to have one
      answer for links to resolve the same way every time (`for_board/1`).
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Vaults.{Index, Mapping, Mirror, Vault}
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Folder, NoteTags, Page}

  @preloads [mappings: [:board, :folder]]

  ## Reading ------------------------------------------------------------------

  @doc "A user's vaults, by name, each with its mappings."
  def list_vaults(%User{id: user_id}) do
    from(v in Vault, where: v.user_id == ^user_id, order_by: [asc: fragment("lower(?)", v.name)])
    |> Repo.all()
    |> Repo.preload(@preloads)
  end

  @doc """
  One of `user`'s vaults, by id or (case-insensitively) by name. Somebody
  else's vault is not found, the same as one that does not exist.
  """
  def get_vault(%User{id: user_id}, ref) do
    ref = ref |> to_string() |> String.trim()

    query =
      case Integer.parse(ref) do
        {id, ""} ->
          from(v in Vault,
            where: v.user_id == ^user_id,
            where: v.id == ^id or fragment("lower(?) = lower(?)", v.name, ^ref)
          )

        _ ->
          from(v in Vault,
            where: v.user_id == ^user_id,
            where: fragment("lower(?) = lower(?)", v.name, ^ref)
          )
      end

    case query |> first(:id) |> Repo.one() do
      nil -> {:error, :not_found, "vault #{inspect(ref)}"}
      vault -> {:ok, Repo.preload(vault, @preloads)}
    end
  end

  @doc """
  The vault a board belongs to, or nil — the question every vault-only
  behaviour (cross-board links, inline tags) asks first.
  """
  def for_board(%Board{id: id}), do: for_board(id)

  def for_board(board_id) when is_integer(board_id) do
    from(v in Vault,
      join: m in Mapping,
      on: m.vault_id == v.id,
      where: m.board_id == ^board_id,
      limit: 1
    )
    |> Repo.one()
  end

  def for_board(_), do: nil

  @doc "Whether a board is mapped into any vault."
  def in_vault?(board), do: not is_nil(for_board(board))

  @doc "The ids of every board mapped into a vault."
  def board_ids(%Vault{id: id}) do
    from(m in Mapping, where: m.vault_id == ^id, distinct: true, select: m.board_id)
    |> Repo.all()
  end

  @doc """
  How many live pages each mapping of the vault holds, `%{mapping_id =>
  count}`: a page counts once, under the deepest mapping above it, as the
  vault's tree lays it out. A mapping holding nothing is absent.
  """
  def page_counts(%Vault{} = vault) do
    vault |> Index.build() |> Enum.frequencies_by(& &1.mapping_id)
  end

  @doc """
  The folders the vault is synced to, as far as the server knows: one per
  API token that has listed it or followed its feed, most recent first.
  """
  def mirrors(%Vault{id: id}) do
    from(m in Mirror, where: m.vault_id == ^id, order_by: [desc: m.last_synced_at, desc: m.id])
    |> Repo.all()
  end

  @doc """
  Notes that `token` has just synced the vault — listed it or read its
  change feed — so the vaults screen can say where it is mirrored. A call
  without an API token (a browser session) is not a mirror and is ignored.
  """
  def touch_mirror(%Vault{id: vault_id}, %{id: token_id} = token) when is_integer(token_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    label = Map.get(token, :label)

    Repo.insert(
      %Mirror{
        vault_id: vault_id,
        token_id: token_id,
        label: label,
        last_synced_at: now
      },
      on_conflict: [set: [last_synced_at: now, label: label, updated_at: now]],
      conflict_target: [:vault_id, :token_id]
    )

    :ok
  end

  def touch_mirror(_vault, _token), do: :ok

  @doc """
  Where everything of the vault is, as the vault view addresses it (#752):
  `%{pages: %{id => "Jobs/Interview Questions"}, folders: %{id => "Jobs"}}`
  — the paths of its files on disk (`Slipdock.Vaults.Layout`) without the
  `.md`, and a page with pages under it at its own name rather than its
  `index.md`.
  """
  def addresses(%Vault{} = vault) do
    layout = Slipdock.Vaults.Layout.build(vault)

    %{
      pages: Map.new(layout.pages, fn {id, p} -> {id, join_path(p.dir, p.stem)} end),
      folders: layout.folders
    }
  end

  defp join_path("", name), do: name
  defp join_path(dir, name), do: dir <> "/" <> name

  @doc """
  What a vault view address names: `{:page, id}`, `{:folder, id}` or
  `{:mapping, mapping}` (a board's wiki, or a folder of it, mounted there),
  matched case aside, a trailing `.md` ignored; `:error` for nothing.
  """
  def resolve_address(%Vault{} = vault, path) do
    want =
      path
      |> to_string()
      |> String.trim("/")
      |> String.replace_suffix(".md", "")
      |> String.downcase()

    %{pages: pages, folders: folders} = addresses(vault)
    find = fn map -> Enum.find_value(map, fn {id, p} -> String.downcase(p) == want && id end) end

    cond do
      id = find.(pages) ->
        {:page, id}

      id = find.(folders) ->
        {:folder, id}

      m =
          Enum.find(
            Repo.preload(vault, @preloads, force: true).mappings,
            &(String.downcase(&1.path) == want)
          ) ->
        {:mapping, m}

      true ->
        :error
    end
  end

  @doc """
  Which mapping a vault path falls in, and what is left of the path below it:
  `{:ok, mapping, rest}`. The longest matching prefix wins, matched whole
  segment by segment, so `/Jobs` does not swallow `/Jobsearch`.
  `{:error, :not_found, _}` when nothing — not even `/` — is mapped above it.
  """
  def locate(%Vault{} = vault, path) do
    with {:ok, path} <- normalize_path(path) do
      vault = Repo.preload(vault, @preloads, force: true)
      segments = split(path)

      vault.mappings
      |> Enum.filter(&prefix?(split(&1.path), segments))
      |> Enum.max_by(&length(split(&1.path)), fn -> nil end)
      |> case do
        nil ->
          {:error, :not_found, "a mapping for #{Mapping.display_path(path)}"}

        mapping ->
          rest = segments |> Enum.drop(length(split(mapping.path))) |> Enum.join("/")
          {:ok, mapping, rest}
      end
    end
  end

  defp split(""), do: []
  defp split(path), do: String.split(path, "/")

  defp prefix?(prefix, segments), do: Enum.take(segments, length(prefix)) == prefix

  @doc """
  A vault path in its stored shape: no leading or trailing slash, no empty
  segments, `""` for the root. `.` and `..` are refused rather than
  interpreted — a path that climbs is never what somebody meant to map.
  """
  def normalize_path(nil), do: {:ok, ""}

  def normalize_path(path) when is_binary(path) do
    segments =
      path
      |> String.replace("\\", "/")
      |> String.split("/")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if Enum.any?(segments, &(&1 in [".", ".."])),
      do: {:error, :unprocessable_entity, "a vault path cannot contain . or .."},
      else: {:ok, Enum.join(segments, "/")}
  end

  @doc """
  The page a link's words name across a vault, as a `[[link]]` on one of its
  boards would find it after its own board: `{:ok, page, path}` with the
  page's vault path, or not found. `reader` sees only what they may open.
  """
  def resolve_link(%Vault{} = vault, link, %User{} = reader) do
    link =
      link
      |> to_string()
      |> String.trim()
      |> String.trim_leading("[[")
      |> String.trim_trailing("]]")

    link = link |> String.split("|", parts: 2) |> hd() |> String.split("#", parts: 2) |> hd()

    vault
    |> Index.build()
    |> Index.match(link)
    |> Enum.find_value(fn entry ->
      with %Page{} = page <- Repo.get(Page, entry.id),
           true <- Wiki.visible?(page, Access.page_permission(reader, page)) do
        {:ok, page, entry.path}
      else
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, :not_found, "a page for [[#{link}]] in #{vault.name}"}
      found -> found
    end
  end

  @doc """
  Pages linked to but never written, anywhere in the vault: the wanted pages
  of all its boards at once, most wanted first. Only the pages doing the
  wanting that `reader` may open are listed, and a want nobody visible has
  is left out.
  """
  def wanted(%Vault{} = vault, %User{} = reader) do
    vault
    |> board_ids()
    |> Wiki.Links.wanted()
    |> Enum.map(fn want ->
      %{want | from: Enum.filter(want.from, &readable?(&1, reader))}
    end)
    |> Enum.reject(&(&1.from == []))
  end

  defp readable?(page, reader),
    do: is_nil(page.archived_at) and Wiki.visible?(page, Access.page_permission(reader, page))

  ## Writing ------------------------------------------------------------------

  @doc "Makes a vault for `user`."
  def create_vault(%User{id: user_id}, attrs) do
    %Vault{user_id: user_id}
    |> Vault.changeset(attrs)
    |> Repo.insert()
    |> preloaded()
  end

  @doc "Renames a vault."
  def update_vault(%Vault{} = vault, attrs) do
    vault |> Vault.changeset(attrs) |> Repo.update() |> preloaded()
  end

  @doc """
  Deletes a vault and its mappings. The pages are untouched: they were always
  the boards', and the boards simply stop being in a vault.
  """
  def delete_vault(%Vault{} = vault) do
    boards = board_ids(vault)

    with {:ok, deleted} <- Repo.delete(vault) do
      Enum.each(boards, &NoteTags.refresh_board/1)
      {:ok, deleted}
    end
  end

  @doc """
  Maps a vault path to a board's wiki, or to one folder of it.

  `attrs`: `path` (default `/`), `board` (a `%Board{}`), and optionally
  `folder` (a `%Folder{}` on that board). `user` must be able to write to the
  board. Refused when the path is already mapped in this vault, when the
  board or folder is already mapped, or when the board is in another vault.
  """
  def add_mapping(%Vault{} = vault, %User{} = user, attrs) do
    board = attrs[:board]
    folder = attrs[:folder]

    with {:ok, path} <- normalize_path(attrs[:path]),
         :ok <- check_board(board, user),
         :ok <- check_folder(folder, board),
         :ok <- check_one_vault(vault, board),
         :ok <- check_overlap(vault, path, board, folder) do
      %Mapping{vault_id: vault.id}
      |> Mapping.changeset(%{path: path, board_id: board.id, folder_id: folder && folder.id})
      |> Repo.insert()
      |> case do
        {:ok, mapping} ->
          # Notes on a board in a vault read their inline #tags (W-103 R3.4).
          NoteTags.refresh_board(board)
          {:ok, Repo.preload(mapping, [:board, :folder])}

        error ->
          error
      end
    end
  end

  defp check_board(%Board{} = board, user) do
    cond do
      not is_nil(board.archived_at) ->
        {:error, :unprocessable_entity, "#{board.name} is archived"}

      Access.can_write?(Access.board_permission(user, board)) ->
        :ok

      true ->
        {:error, :forbidden, "you can't write to #{board.name}, so it can't be in your vault"}
    end
  end

  defp check_board(_, _user), do: {:error, :unprocessable_entity, "say which board to map"}

  defp check_folder(nil, _board), do: :ok
  defp check_folder(%Folder{board_id: id}, %Board{id: id}), do: :ok

  defp check_folder(%Folder{}, _board),
    do: {:error, :unprocessable_entity, "that folder is not on that board"}

  defp check_one_vault(%Vault{id: id}, %Board{} = board) do
    case for_board(board) do
      nil -> :ok
      %Vault{id: ^id} -> :ok
      %Vault{} -> {:error, :unprocessable_entity, "#{board.name} is already in another vault"}
    end
  end

  @doc "Takes a mapping out of a vault, by its id or by its path."
  def remove_mapping(%Vault{} = vault, ref) do
    with {:ok, mapping} <- find_mapping(vault, ref),
         {:ok, deleted} <- Repo.delete(mapping) do
      NoteTags.refresh_board(deleted.board_id)
      {:ok, deleted}
    end
  end

  @doc "One of the vault's mappings, by its id or by its path."
  def find_mapping(%Vault{} = vault, ref) do
    vault = Repo.preload(vault, @preloads, force: true)
    ref = ref |> to_string() |> String.trim()

    found =
      case Integer.parse(ref) do
        {id, ""} ->
          Enum.find(vault.mappings, &(&1.id == id))

        _ ->
          case normalize_path(ref) do
            {:ok, path} -> Enum.find(vault.mappings, &(&1.path == path))
            _ -> nil
          end
      end

    case found do
      nil -> {:error, :not_found, "mapping #{inspect(ref)}"}
      mapping -> {:ok, mapping}
    end
  end

  ## Previews -------------------------------------------------------------------

  @sample 10

  @doc """
  What adding a mapping would do, before it is done — refused for the same
  reasons `add_mapping/3` refuses, and otherwise:

      %{path: "/Jobs", arriving: %{count: 12, sample: ["Jobs/Acme.md", ...]},
        moving: %{count: 3, sample: [%{from: "Jobs/Old.md", to: "Jobs/Old.md"}, ...]},
        mirrors: ["slipdock CLI on laptop"]}

  `arriving` are the pages of the board (or folder) that join the vault,
  with their vault paths; `moving` the pages already in the vault that the
  new mapping takes over, being the longer prefix. The synced folders named
  in `mirrors` gain the arriving files.
  """
  def preview_mapping(%Vault{} = vault, %User{} = user, attrs) do
    board = attrs[:board]
    folder = attrs[:folder]

    with {:ok, path} <- normalize_path(attrs[:path]),
         :ok <- check_board(board, user),
         :ok <- check_folder(folder, board),
         :ok <- check_one_vault(vault, board),
         :ok <- check_free(vault, path, board, folder),
         :ok <- check_overlap(vault, path, board, folder) do
      mappings = Index.mappings(vault)
      before = Index.build_from(mappings)
      later = Index.build_from(mappings ++ [{board.id, folder && folder.id, path, :new}])
      {_gone, moved, came} = diff(before, later)

      {:ok,
       %{
         path: Mapping.display_path(path),
         arriving: sample(came, & &1.path),
         moving:
           sample(Enum.filter(moved, &(&1.to_mapping == :new)), &Map.take(&1, [:from, :to])),
         mirrors: mirror_names(vault)
       }}
    end
  end

  @doc """
  What taking a mapping out would do: the pages that leave the vault (and so
  the synced folders), and those that fall back to an outer mapping and so
  move to another path. The pages themselves stay on their board.

      %{path: "/Jobs", leaving: %{count:, sample: [...]}, moving: %{count:, sample: [...]},
        mirrors: [...]}
  """
  def preview_unmapping(%Vault{} = vault, ref) do
    with {:ok, mapping} <- find_mapping(vault, ref) do
      mappings = Index.mappings(vault)
      before = Index.build_from(mappings)
      later = Index.build_from(Enum.reject(mappings, &(elem(&1, 3) == mapping.id)))
      {gone, moved, _came} = diff(before, later)

      {:ok,
       %{
         path: Mapping.display_path(mapping),
         leaving: sample(gone, & &1.path),
         moving: sample(moved, &Map.take(&1, [:from, :to])),
         mirrors: mirror_names(vault)
       }}
    end
  end

  # Pages in `before` and not `later`, in both but at another path or under
  # another mapping, and in `later` alone.
  defp diff(before, later) do
    old = Map.new(before, &{&1.id, &1})
    new = Map.new(later, &{&1.id, &1})

    gone = Enum.reject(before, &Map.has_key?(new, &1.id))
    came = Enum.reject(later, &Map.has_key?(old, &1.id))

    moved =
      for entry <- later,
          %{} = was <- [old[entry.id]],
          was.path != entry.path or was.mapping_id != entry.mapping_id,
          do: %{from: was.path <> ".md", to: entry.path <> ".md", to_mapping: entry.mapping_id}

    {gone, moved, came}
  end

  defp sample(list, fun) do
    %{count: length(list), sample: list |> Enum.take(@sample) |> Enum.map(&file(fun.(&1)))}
  end

  defp file(path) when is_binary(path), do: path <> ".md"
  defp file(other), do: other

  defp mirror_names(vault), do: vault |> mirrors() |> Enum.map(&(&1.label || "an unnamed token"))

  # The same refusals the unique indexes make, worded the same, before
  # anything is written.
  defp check_free(vault, path, board, folder) do
    mappings = Repo.preload(vault, @preloads, force: true).mappings

    cond do
      Enum.any?(mappings, &(&1.path == path)) ->
        {:error, :unprocessable_entity,
         "#{Mapping.display_path(path)} is already mapped in this vault"}

      folder && Repo.exists?(from(m in Mapping, where: m.folder_id == ^folder.id)) ->
        {:error, :unprocessable_entity, "that folder is already mapped into a vault"}

      is_nil(folder) and
          Repo.exists?(from(m in Mapping, where: m.board_id == ^board.id and is_nil(m.folder_id))) ->
        {:error, :unprocessable_entity, "#{board.name} is already mapped into a vault"}

      true ->
        :ok
    end
  end

  ## Overlaps -------------------------------------------------------------------

  @doc """
  Pages that sit at a vault path another mapping owns: a page of the board
  mapped at `/` filed in its `Jobs` folder, once `/Jobs` is mapped onto
  another board. Both boards then claim `/Jobs/...`, and a synced edit to
  such a file would be sent to the inner mapping's board. `add_mapping/3`
  refuses to make one; this finds any made before it did.

      [%{path: "Jobs/Acme.md", board: "KnowledgeBase", under: "/Jobs"}]
  """
  def overlaps(%Vault{} = vault) do
    mappings = Index.mappings(vault)
    mappings |> Index.build_from() |> shadowed(mappings) |> describe_overlaps(mappings)
  end

  # The entries whose own mapping is not the one their directory locates to,
  # the longest prefix winning, as `locate/2` and a sync's writes decide.
  defp shadowed(index, mappings) do
    paths = Enum.map(mappings, fn {_b, _f, path, id} -> {split(path), id} end)

    Enum.filter(index, fn entry ->
      dir = Enum.drop(entry.segments, -1)

      owner =
        paths
        |> Enum.filter(fn {prefix, _id} -> prefix?(prefix, dir) end)
        |> Enum.max_by(fn {prefix, _id} -> length(prefix) end, fn -> nil end)

      match?({_, id} when id != entry.mapping_id, owner)
    end)
  end

  defp describe_overlaps(entries, mappings) do
    paths = Map.new(mappings, fn {_b, _f, path, id} -> {id, path} end)
    owners = Map.new(mappings, fn {board_id, _f, path, _id} -> {split(path), board_id} end)
    names = board_names(Enum.map(entries, & &1.board_id) ++ Map.values(owners))

    Enum.map(entries, fn entry ->
      dir = Enum.drop(entry.segments, -1)
      under = owners |> Map.keys() |> Enum.filter(&prefix?(&1, dir)) |> Enum.max_by(&length/1)

      %{
        path: entry.path <> ".md",
        board: names[entry.board_id],
        mapping: Mapping.display_path(paths[entry.mapping_id]),
        under: Mapping.display_path(Enum.join(under, "/")),
        owner: names[owners[under]]
      }
    end)
  end

  defp board_names([]), do: %{}

  defp board_names(ids),
    do:
      Repo.all(from(b in Board, where: b.id in ^Enum.uniq(ids), select: {b.id, b.name}))
      |> Map.new()

  # A new mapping is refused while it would make an overlap the vault does
  # not already have: pages of one mapping at paths another owns. The way
  # out is to move those pages first, or to map somewhere else.
  defp check_overlap(vault, path, board, folder) do
    mappings = Index.mappings(vault)
    before = mappings |> Index.build_from() |> shadowed(mappings) |> MapSet.new(& &1.id)
    later_mappings = mappings ++ [{board.id, folder && folder.id, path, :new}]

    fresh =
      later_mappings
      |> Index.build_from()
      |> shadowed(later_mappings)
      |> Enum.reject(&MapSet.member?(before, &1.id))

    case describe_overlaps(fresh, later_mappings) do
      [] ->
        :ok

      overlaps ->
        n = length(overlaps)
        [%{board: board_name, under: under, owner: owner} | _] = overlaps
        examples = overlaps |> Enum.take(3) |> Enum.map_join(", ", & &1.path)
        more = if n > 3, do: ", …", else: ""

        {:error, :unprocessable_entity,
         "#{Mapping.display_path(path)} would overlap #{n} #{if n == 1, do: "page", else: "pages"} " <>
           "#{board_name} already has under #{under} (#{examples}#{more}), which would then " <>
           "belong to #{owner}'s mapping: move them to #{owner} first, or map somewhere else"}
    end
  end

  @doc """
  Every board `user` can see, each with why it cannot be mapped into
  `vault` — `nil` when it can: `[{board, reason}]`, by name. The same rules
  as `add_mapping/3`.
  """
  def mapping_candidates(%Vault{} = vault, %User{} = user) do
    user
    |> Access.list_boards(archived: :all)
    |> Enum.sort_by(&String.downcase(&1.name))
    |> Enum.map(fn board ->
      reason =
        with :ok <- check_board(board, user),
             :ok <- check_one_vault(vault, board) do
          nil
        else
          {:error, :forbidden, _} -> "you can't write to it"
          {:error, _, message} -> String.replace_prefix(message, board.name <> " ", "")
        end

      {board, reason}
    end)
  end

  defp preloaded({:ok, vault}), do: {:ok, Repo.preload(vault, @preloads, force: true)}
  defp preloaded(error), do: error
end
