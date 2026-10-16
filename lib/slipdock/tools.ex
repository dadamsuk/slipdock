defmodule Slipdock.Tools do
  @moduledoc """
  Tools (#958): packaged docs, files, a board blueprint and agent skills,
  published on this server by one person and installed by others on it.

  A Tool is a `Slipdock.Tools.Tool` (its name, owned by whoever published it
  first) with immutable `Slipdock.Tools.Version`s, each read from a package
  by `Slipdock.Tools.Package` and stored file by file, identified by a sha
  over its files.

  A package is instructions that will run in somebody else's agent with
  their write token, so who can see one is narrow: its owner, the people it
  is shared with, and — once an admin has approved a version — everybody on
  the server.
  """

  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Quota
  alias Slipdock.Repo
  alias Slipdock.Blueprint
  alias Slipdock.Boards
  alias Slipdock.Tools.{Install, Package, Tool}
  alias Slipdock.Tools.Version, as: ToolVersion

  ## Publishing -----------------------------------------------------------------

  @doc """
  Publishes the package in `bytes` (a `.tar.gz`) as a new version, made by
  `user`: the first version of a new Tool, or the next one of theirs.
  Returns `{:ok, %ToolVersion{}}` with its tool, `{:error, message}`, or
  `{:error, :payment_required, code, message}` when storage is full.

  Refused: an unreadable or invalid package (`Package.read/1` says why), a
  name somebody else's Tool already has, a version that is not newer than
  the latest, and a package that would take its owner past their storage.
  """
  def publish(%User{} = user, bytes) when is_binary(bytes) do
    with {:ok, package} <- Package.read(bytes),
         {:ok, tool} <- tool_for(user, package.manifest),
         :ok <- newer(tool, package.manifest["version"]),
         :ok <- storage(user, package.size) do
      insert_version(user, tool, package)
    end
  end

  defp tool_for(user, %{"name" => slug}) do
    case Repo.get_by(Tool, slug: slug) do
      nil -> {:ok, %Tool{slug: slug, owner_id: user.id}}
      %Tool{owner_id: owner} = tool when owner == user.id -> {:ok, tool}
      %Tool{} -> {:error, "the name “#{slug}” belongs to someone else's Tool — choose another"}
    end
  end

  defp newer(%Tool{id: nil}, _version), do: :ok

  defp newer(%Tool{} = tool, version) do
    case latest_version(tool) do
      nil ->
        :ok

      latest ->
        case Version.compare(version, latest.version) do
          :gt ->
            :ok

          :eq ->
            {:error,
             "#{tool.slug} #{version} is already published, and a version never changes — bump the version"}

          :lt ->
            {:error,
             "#{tool.slug} #{version} is older than the latest, #{latest.version} — bump the version"}
        end
    end
  end

  defp storage(user, size) do
    case Quota.check(user, :storage, size) do
      :ok ->
        :ok

      {:error, :trial_expired} ->
        {:error, :payment_required, "trial_expired", Quota.message(user, :trial)}

      {:error, reason} ->
        %{remaining: left} = Quota.status(user, :storage)

        {:error, :payment_required, Atom.to_string(reason),
         "This package unpacks to #{kb(size)}, and you have #{kb(left)} of storage left on " <>
           "this server. Delete some attachments, or ask an admin to raise the limit."}
    end
  end

  defp kb(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"

  defp insert_version(user, tool, package) do
    manifest = package.manifest

    Repo.transaction(fn ->
      tool =
        tool
        |> Ecto.Changeset.change(name: manifest["title"], summary: manifest["summary"])
        |> Repo.insert_or_update()
        |> case do
          {:ok, tool} -> tool
          {:error, _} -> Repo.rollback("the name “#{tool.slug}” is taken")
        end

      {:ok, version} =
        Repo.insert(%ToolVersion{
          tool_id: tool.id,
          version: manifest["version"],
          sha: Package.sha(package.entries),
          manifest: manifest,
          readme: package.readme,
          board: package.board,
          size: package.size,
          published_by_id: user.id
        })

      rows =
        for {path, bytes} <- package.entries do
          %{
            version_id: version.id,
            path: path,
            content: bytes,
            size: byte_size(bytes),
            sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
          }
        end

      rows |> Enum.chunk_every(100) |> Enum.each(&Repo.insert_all(Slipdock.Tools.File, &1))

      %{version | tool: tool}
    end)
  end

  ## Reading ----------------------------------------------------------------------

  @doc "Every version of `tool`, newest first."
  def versions(%Tool{id: id}) do
    from(v in ToolVersion, where: v.tool_id == ^id)
    |> Repo.all()
    |> Enum.sort(&(Version.compare(&1.version, &2.version) != :lt))
  end

  @doc "The newest version of `tool`, or nil."
  def latest_version(%Tool{} = tool), do: tool |> versions() |> List.first()

  @doc "The version `number` of `tool`, or nil."
  def get_version(%Tool{id: id}, number),
    do: Repo.get_by(ToolVersion, tool_id: id, version: to_string(number))

  @doc "The Tools `user` can see, by name."
  def list_for(%User{} = user), do: list_own(user)
  def list_for(_), do: []

  @doc "The Tools `user` owns, by name."
  def list_own(%User{id: id}),
    do: Repo.all(from(t in Tool, where: t.owner_id == ^id, order_by: [asc: t.slug]))

  @doc """
  The Tool `slug` as `user` may see it: `{:ok, tool}`, or `{:error,
  :not_found}` — the same answer whether it does not exist or is not theirs
  to see, so asking says nothing about what is on the server.
  """
  def fetch(user, slug) when is_binary(slug) do
    case Repo.get_by(Tool, slug: String.downcase(String.trim(slug))) do
      nil -> {:error, :not_found}
      tool -> if visible?(user, tool), do: {:ok, tool}, else: {:error, :not_found}
    end
  end

  def fetch(_user, _slug), do: {:error, :not_found}

  @doc "Whether `user` may see `tool` at all."
  def visible?(%User{id: id}, %Tool{owner_id: id}), do: true
  def visible?(_user, _tool), do: false

  @doc "Whether `user` owns `tool`."
  def owner?(%User{id: id}, %Tool{owner_id: id}), do: true
  def owner?(_user, _tool), do: false

  @doc """
  The version `user` sees of `tool`: the one asked for (by number) or else
  the latest. nil when there is none.
  """
  def visible_version(user, %Tool{} = tool, number \\ nil) do
    cond do
      not visible?(user, tool) -> nil
      number in [nil, ""] -> latest_version(tool)
      true -> get_version(tool, number)
    end
  end

  @doc "The files of `version`, path order, bytes and all."
  def files(%ToolVersion{id: id}),
    do: Repo.all(from(f in Slipdock.Tools.File, where: f.version_id == ^id, order_by: f.path))

  @doc "One file of `version` by its path in the package, or nil."
  def file(%ToolVersion{id: id}, path),
    do: Repo.get_by(Slipdock.Tools.File, version_id: id, path: path)

  @doc """
  The skills in `version`, as they land in a skills directory: each one's
  name, description, the files in its folder (its own, and any `local` files
  the manifest puts beside them), a sha over those files and their size.

  The sha is computed the way `Slipdock.Skills` computes one, so
  `slipdock tools check` compares a local copy the way `slipdock skills
  check` does.
  """
  def skills(%ToolVersion{} = version) do
    version
    |> skill_trees()
    |> Enum.map(fn {name, files} -> skill_entry(version, name, files) end)
  end

  @doc """
  Each skill of `version` as `{name, [{path in the skill folder, bytes}]}`,
  `SKILL.md` first, with the manifest's `local` files placed beside it.
  """
  def skill_trees(%ToolVersion{} = version) do
    files = files(version)
    locals = Enum.filter(version.manifest["files"] || [], &(&1["install"] == "local"))

    files
    |> Enum.filter(&String.starts_with?(&1.path, "skills/"))
    |> Enum.group_by(&(&1.path |> String.split("/") |> Enum.at(1)))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, own} ->
      prefix = "skills/#{name}/"
      own = Enum.map(own, &{String.replace_prefix(&1.path, prefix, ""), &1.content})

      beside =
        for %{"skill" => ^name, "path" => path} <- locals,
            f = Enum.find(files, &(&1.path == "files/" <> path)),
            do: {path, f.content}

      {name, Enum.sort_by(own ++ beside, &skill_order/1)}
    end)
  end

  defp skill_order({"SKILL.md", _}), do: ""
  defp skill_order({path, _}), do: path

  defp skill_entry(version, name, files) do
    skill_md = Enum.find_value(files, fn {p, c} -> if p == "SKILL.md", do: c end) || ""

    description =
      case Package.front_matter(skill_md) do
        {:ok, front} -> front["description"]
        _ -> nil
      end

    %{
      name: name,
      description: description,
      files: Enum.map(files, &elem(&1, 0)),
      sha: Slipdock.Skills.digest(files),
      bytes: files |> Enum.map(&byte_size(elem(&1, 1))) |> Enum.sum(),
      version: version.version
    }
  end

  ## Installing --------------------------------------------------------------------

  @doc """
  Builds `tool`'s board for `user` and records the install (#961): the
  server makes the lists, folders, tags, page skeletons and rules from the
  version's `board.json` (`Slipdock.Blueprint`), puts the package's board
  files in a `Tool` folder on the board's wiki, and returns the board.

  Options: `version:` (a version number; the latest `user` can see when
  left out) and `name:` (the board's name; the Tool's title otherwise).

  Installing again when `user` already has the board returns that board,
  with `created: false`, and makes nothing new. Nothing outside the board
  it makes is touched.

  Returns `{:ok, %{install:, board:, created:, version:, report:}}`, or
  `{:error, :not_found}` for a Tool or version `user` can't see, or
  `{:error, message}`.
  """
  def install_board(%User{} = user, %Tool{} = tool, opts \\ []) do
    with %ToolVersion{} = version <-
           visible_version(user, tool, opts[:version]) || {:error, :not_found} do
      case current_install(user, tool) do
        %Install{board: %Boards.Board{} = board} = install ->
          {:ok, %{install: install, board: board, created: false, version: version, report: nil}}

        install ->
          build(user, tool, version, install, opts)
      end
    end
  end

  @doc "`user`'s install of `tool`, with its board (nil when that board is gone), or nil."
  def current_install(%User{id: user_id}, %Tool{id: tool_id}) do
    Install
    |> Repo.get_by(user_id: user_id, tool_id: tool_id)
    |> Repo.preload(:board)
  end

  def current_install(_, _), do: nil

  @doc "Every install `user` has, with its Tool and board."
  def installs(%User{id: user_id}) do
    from(i in Install, where: i.user_id == ^user_id, order_by: [asc: i.inserted_at])
    |> Repo.all()
    |> Repo.preload([:tool, :board])
  end

  defp build(_user, _tool, %ToolVersion{board: nil}, _install, _opts),
    do: {:error, "this Tool has no board to install — its skills install on their own"}

  defp build(user, tool, version, install, opts) do
    name = blank_to_nil(opts[:name]) || tool.name
    message = "installed from the #{tool.name} Tool, #{version.version}"

    Repo.transaction(fn ->
      with {:ok, board} <-
             Boards.create_board(%{"name" => name},
               columns: version.board["lists"],
               owner_id: user.id
             ),
           {:ok, report} <-
             Blueprint.apply(board, Map.delete(version.board, "lists"),
               user: user,
               message: message
             ),
           {:ok, files} <- put_board_files(board, version, user),
           {:ok, install} <- record_install(install, user, tool, version, board) do
        # The lists came with the board itself, before the rest was applied.
        lists = Enum.map(version.board["lists"], & &1["name"])

        report =
          report
          |> put_in([:added, "lists"], lists)
          |> put_in([:added, "files"], files)

        %{
          install: install,
          board: Boards.get_board!(board.id),
          created: true,
          version: version,
          report: report
        }
      else
        {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(changeset_message(cs))
        {:error, message} -> Repo.rollback(message)
      end
    end)
  end

  defp record_install(nil, user, tool, version, board) do
    Repo.insert(%Install{
      user_id: user.id,
      tool_id: tool.id,
      version: version.version,
      board_id: board.id
    })
  end

  defp record_install(%Install{} = install, _user, _tool, version, board) do
    install
    |> Ecto.Changeset.change(version: version.version, board_id: board.id)
    |> Repo.update()
  end

  @tool_folder "Tool"

  @doc "The wiki folder a Tool's board files go in."
  def tool_folder, do: @tool_folder

  # The package's `board` files, into the `Tool` folder at the same relative
  # paths. Returns the paths added; one already there is left alone.
  defp put_board_files(board, version, user) do
    wanted = Enum.filter(version.manifest["files"] || [], &(&1["install"] == "board"))

    Enum.reduce_while(wanted, {:ok, []}, fn %{"path" => path}, {:ok, added} ->
      case put_board_file(board, version, user, path) do
        {:ok, :added} -> {:cont, {:ok, added ++ [path]}}
        {:ok, :skipped} -> {:cont, {:ok, added}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp put_board_file(board, version, user, path) do
    dir = Path.dirname(path)
    folder_path = if dir == ".", do: @tool_folder, else: @tool_folder <> "/" <> dir

    with {:ok, folder} <- ensure_folder(board, folder_path),
         %{content: bytes} <-
           file(version, "files/" <> path) || {:error, "files/#{path} is missing"} do
      name = Path.basename(path)

      if Slipdock.Wiki.Files.taken?(board.id, folder.id, name) do
        {:ok, :skipped}
      else
        tmp = Path.join(System.tmp_dir!(), "tool-file-#{System.unique_integer([:positive])}")
        File.write!(tmp, bytes)

        try do
          case Slipdock.Wiki.Files.create(board, %{name: name, folder_id: folder.id}, tmp, user) do
            {:ok, _} ->
              {:ok, :added}

            {:error, %Ecto.Changeset{} = cs} ->
              {:error, "file #{path}: " <> changeset_message(cs)}

            {:error, other} ->
              {:error, "file #{path}: #{inspect(other)}"}
          end
        after
          File.rm(tmp)
        end
      end
    end
  end

  defp ensure_folder(board, path) do
    case Slipdock.Wiki.Folders.find(board, "/" <> path) do
      {:ok, folder} -> {:ok, folder}
      _ -> Slipdock.Wiki.Folders.create(board, %{"name" => path})
    end
  end

  defp changeset_message(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s),
    do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  @doc "The bytes a person's Tools take up, for their storage quota."
  def storage_used(user_id) when is_integer(user_id) do
    from(v in ToolVersion,
      join: t in Tool,
      on: t.id == v.tool_id,
      where: t.owner_id == ^user_id,
      select: type(sum(v.size), :integer)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end
end
