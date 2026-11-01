defmodule Slipdock.Vaults do
  @moduledoc """
  Vaults (W-2201): each person has exactly one, and it is their whole wiki as
  one tree of files.

  A vault holds no pages and configures nothing. Every root board its owner
  has is a folder off its root, and a sub-board is its epic's folder
  (`Slipdock.Vaults.Layout`). So there is nothing to keep in step: a new or
  renamed board simply shows. An archived board keeps its place in the
  layout, so links to its pages still resolve, but is out of the tree, the
  sync listing and the feed (`hidden_board_ids/1`). What a vault row does hold is
  what hangs off the whole: its name, switcher key, place on the home page,
  recordings folder and mirrors.

  It is also the set of boards a plain `[[link]]` is looked for across, after
  the page's own board and page codes. Boards shared with its owner by
  someone else are not in it: stubs cover those.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Vaults.{Index, Layout, Mirror, Vault}
  alias Slipdock.Wiki
  alias Slipdock.Wiki.Page

  @preloads [:mirrors]
  @default_name "Slipdock"

  ## Reading ------------------------------------------------------------------

  @doc "The person's one vault, made the first time it is wanted."
  def root(%User{id: user_id}), do: root(user_id)

  def root(user_id) when is_integer(user_id) do
    case find_root(user_id) do
      %Vault{} = vault -> vault
      nil -> create_root(user_id)
    end
  end

  defp find_root(user_id) do
    from(v in Vault, where: v.user_id == ^user_id, order_by: [asc: v.id], limit: 1)
    |> Repo.one()
  end

  # Two first needs at once: the name's unique index lets one through, and
  # the other reads what it made. A switcher key taken in the same moment
  # stops the insert too, so that try goes without: `switchable/1` gives it
  # one when it's listed.
  defp create_root(user_id) do
    insert_root(user_id, Slipdock.Boards.suggest_shortcut(@default_name))
    find_root(user_id) || (insert_root(user_id, nil) && find_root(user_id))
  end

  defp insert_root(user_id, shortcut) do
    %Vault{user_id: user_id, shortcut: shortcut}
    |> Vault.changeset(%{"name" => @default_name})
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc "A person's vaults: the one, in the list shape the API answers with."
  def list_vaults(%User{} = user), do: [user |> root() |> Repo.preload(@preloads)]

  @doc """
  The person's vault, by id or (case-insensitively) by name. Somebody else's
  vault is not found, the same as one that does not exist.
  """
  def get_vault(%User{id: user_id} = user, ref) do
    ref = ref |> to_string() |> String.trim()
    root(user)

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
  The vault a board belongs to: its top board's owner's, or nil for a board
  nobody owns. The question every vault-only behaviour (cross-board links,
  inline tags) asks first.
  """
  def for_board(%Board{id: id}), do: for_board(id)

  def for_board(board_id) when is_integer(board_id) do
    from(b in Board,
      left_join: top in Board,
      on: top.id == b.root_id,
      where: b.id == ^board_id,
      select: coalesce(top.owner_id, b.owner_id)
    )
    |> Repo.one()
    |> case do
      nil -> nil
      owner_id -> root(owner_id)
    end
  end

  def for_board(_), do: nil

  @doc "Whether a board is in a vault: whether anybody owns it."
  def in_vault?(board), do: not is_nil(for_board(board))

  @doc "The ids of every board in a vault, sub-boards and archived ones too."
  def board_ids(%Vault{} = vault), do: vault |> Layout.boards() |> Enum.map(& &1.id)

  @doc """
  The ids of the vault's boards that are out of its tree: every board whose
  root board is archived (only a root board can be). An archived board is
  browsed from the archive, not the tree, so the tree, the sync listing and
  the feed leave these out. Their pages still answer `[[links]]`.
  """
  def hidden_board_ids(%Vault{} = vault) do
    ids = board_ids(vault)

    from(b in Board,
      left_join: r in Board,
      on: r.id == b.root_id,
      where: b.id in ^ids and (not is_nil(b.archived_at) or not is_nil(r.archived_at)),
      select: b.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  The vault's boards in its tree, each with the path of its folder,
  sub-boards too, in path order: none whose root is archived
  (`hidden_board_ids/1`).
  """
  def tree_boards(%Vault{} = vault) do
    hidden = hidden_board_ids(vault)
    vault |> boards() |> Enum.reject(&MapSet.member?(hidden, &1.board.id))
  end

  @doc """
  The vault's boards, each with the path of its folder, sub-boards and
  archived ones too, in path order.
  """
  def boards(%Vault{} = vault) do
    paths = Layout.dirs(vault).boards

    from(b in Board, where: b.id in ^Map.keys(paths))
    |> Repo.all()
    |> Enum.map(&%{board: &1, path: paths[&1.id]})
    |> Enum.sort_by(& &1.path)
  end

  @doc "How many live pages the vault holds."
  def page_count(%Vault{} = vault), do: vault |> Index.build() |> length()

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
  `%{pages: %{id => "Projects/Roadmap"}, folders: %{id => "Projects"}, boards:
  %{id => "Projects"}, names: Names.t}` — the paths of its files on disk
  (`Slipdock.Vaults.Layout`) without the `.md`, and a page with pages under it
  at its own name rather than its `index.md`. `names` is what to call the
  directories on those paths (`Slipdock.Vaults.Names`).
  """
  def addresses(%Vault{} = vault) do
    layout = Layout.build(vault)

    %{
      pages: Map.new(layout.pages, fn {id, p} -> {id, join_path(p.dir, p.stem)} end),
      folders: layout.folders,
      boards: layout.boards,
      names: Slipdock.Vaults.Names.build(layout)
    }
  end

  defp join_path("", name), do: name
  defp join_path(dir, name), do: dir <> "/" <> name

  @doc """
  What a vault view address names: `{:page, id}`, `{:folder, id}` or
  `{:board, id}`, matched case aside, a trailing `.md` ignored; `:error` for
  nothing.
  """
  def resolve_address(%Vault{} = vault, path) do
    want =
      path
      |> to_string()
      |> String.trim("/")
      |> String.replace_suffix(".md", "")
      |> String.downcase()

    %{pages: pages, folders: folders, boards: boards} = addresses(vault)
    find = fn map -> Enum.find_value(map, fn {id, p} -> String.downcase(p) == want && id end) end

    cond do
      id = find.(pages) -> {:page, id}
      id = find.(folders) -> {:folder, id}
      id = find.(boards) -> {:board, id}
      true -> :error
    end
  end

  @doc """
  Which board a vault path falls in, and what is left of the path below it:
  `{:ok, board_id, rest}`. Matched whole segment by segment, so `/Projects`
  does not swallow `/Projectsearch`; the deepest board wins, a sub-board being
  inside its parent's folder. `{:error, :not_found, _}` at the root or outside
  every board.
  """
  def locate(%Vault{} = vault, path) do
    with {:ok, path} <- normalize_path(path) do
      segments = split(path)

      Layout.dirs(vault).boards
      |> Enum.filter(fn {_id, dir} -> prefix?(down(dir), down(path)) end)
      |> Enum.max_by(fn {_id, dir} -> length(split(dir)) end, fn -> nil end)
      |> case do
        nil ->
          {:error, :not_found, "a board at /#{path}"}

        {id, dir} ->
          {:ok, id, segments |> Enum.drop(length(split(dir))) |> Enum.join("/")}
      end
    end
  end

  defp down(path), do: path |> String.downcase() |> split()

  defp split(""), do: []
  defp split(path), do: String.split(path, "/")

  defp prefix?(prefix, segments), do: Enum.take(segments, length(prefix)) == prefix

  @doc """
  A vault path in its stored shape: no leading or trailing slash, no empty
  segments, `""` for the root. `.` and `..` are refused rather than
  interpreted — a path that climbs is never what somebody meant.
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

  @doc """
  Gives a vault the switcher key `value` (#1204). Blank takes a fresh one from
  its name. A key a board or another vault has is refused.
  """
  def set_shortcut(%Vault{} = vault, value) do
    key = Slipdock.Boards.Board.sanitize_shortcut(value || "")

    key =
      if key == "",
        do: Slipdock.Boards.suggest_shortcut(vault.name, {:vault, vault.id}),
        else: key

    changeset = Vault.shortcut_changeset(vault, key)

    if changeset.valid? and Slipdock.Boards.shortcut_taken?(key, {:vault, vault.id}) do
      {:error, Ecto.Changeset.add_error(changeset, :shortcut, "is already used by a board")}
    else
      changeset |> Repo.update() |> preloaded()
    end
  end

  @doc """
  `user`'s vaults for the board switcher, by name, each with a key: one made
  before vaults had keys gets its key here, the first time it is listed.
  """
  def switchable(%User{id: user_id}) do
    from(v in Vault, where: v.user_id == ^user_id, order_by: [asc: fragment("lower(?)", v.name)])
    |> Repo.all()
    |> Enum.map(fn
      %Vault{shortcut: nil} = vault ->
        case set_shortcut(vault, nil) do
          {:ok, vault} -> vault
          _ -> vault
        end

      vault ->
        vault
    end)
  end

  def switchable(_), do: []

  @doc "Renames a vault."
  def update_vault(%Vault{} = vault, attrs) do
    vault |> Vault.changeset(attrs) |> Repo.update() |> preloaded()
  end

  @doc """
  Sets the folder on the owner's Google Drive the vault's meeting recordings
  are kept in (W-1690), after checking, through the owner's connection, that
  it is a folder there. A blank path clears it. Changing it forgets every
  recording found under the old one.

  `{:ok, vault}`, or `{:error, reason}`: `:not_connected`, `:revoked`,
  `:invalid`, `:not_found`, `:unavailable` (see `Slipdock.Recordings`).
  """
  def set_recordings_folder(%Vault{} = vault, path) when path in [nil, ""],
    do: save_recordings_folder(vault, nil)

  def set_recordings_folder(%Vault{} = vault, path) when is_binary(path) do
    if String.trim(path) == "" do
      save_recordings_folder(vault, nil)
    else
      with {:ok, folder} <- Slipdock.Recordings.check_folder(vault.user_id, path),
           do: save_recordings_folder(vault, folder)
    end
  end

  defp save_recordings_folder(vault, folder) do
    Slipdock.Recordings.forget_all(vault)

    vault
    |> Ecto.Changeset.change(recordings_folder: folder)
    |> Repo.update()
    |> preloaded()
  end

  defp preloaded({:ok, vault}), do: {:ok, Repo.preload(vault, @preloads, force: true)}
  defp preloaded(error), do: error
end
