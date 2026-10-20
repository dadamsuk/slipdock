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

  @doc """
  The Tools `user` can see, by name: their own, then the ones shared with
  them, then the ones listed for everyone.
  """
  def list_for(%User{} = user) do
    own = list_own(user)
    shared = list_shared(user)
    seen = MapSet.new(own ++ shared, & &1.id)
    own ++ shared ++ Enum.reject(list_listed(), &MapSet.member?(seen, &1.id))
  end

  def list_for(_), do: []

  @doc "Every Tool listed for everyone on the server, by name."
  def list_listed,
    do: Repo.all(from(t in Tool, where: not is_nil(t.listed_version_id), order_by: [asc: t.slug]))

  ## Listing for everyone -----------------------------------------------------------

  @doc """
  The owner asks for `version` to be listed for everyone on the server. It
  shows as listed only once an admin approves it (`approve_listing/2`);
  until then the version listed before, if any, stays listed.
  """
  def request_listing(%User{} = user, %ToolVersion{} = version) do
    tool = Repo.get!(Tool, version.tool_id)

    cond do
      not owner?(user, tool) ->
        {:error, "only the Tool's owner can ask for it to be listed"}

      version.approved_at ->
        {:error, "#{tool.slug} #{version.version} is already approved"}

      true ->
        version
        |> Ecto.Changeset.change(
          listing_requested_at: now(),
          declined_at: nil,
          declined_reason: nil
        )
        |> Repo.update()
    end
  end

  @doc "Versions waiting for an admin to decide on listing them, oldest request first."
  def listing_queue do
    from(v in ToolVersion,
      where:
        not is_nil(v.listing_requested_at) and is_nil(v.approved_at) and is_nil(v.declined_at),
      order_by: [asc: v.listing_requested_at],
      preload: [tool: :owner]
    )
    |> Repo.all()
  end

  @doc """
  An admin approves `version` for listing: from now on everybody on the
  server can see and install that version. A newer version needs approving
  in its turn; until it is, this one stays the listed one.
  """
  def approve_listing(%User{admin: true} = admin, %ToolVersion{} = version) do
    Repo.transaction(fn ->
      {:ok, version} =
        version
        |> Ecto.Changeset.change(approved_at: now(), approved_by_id: admin.id, declined_at: nil)
        |> Repo.update()

      tool = Repo.get!(Tool, version.tool_id)
      current = tool.listed_version_id && Repo.get(ToolVersion, tool.listed_version_id)

      # Approving an old request never takes a newer listed version back.
      if is_nil(current) or Version.compare(version.version, current.version) != :lt do
        tool |> Ecto.Changeset.change(listed_version_id: version.id) |> Repo.update!()
      end

      version
    end)
  end

  def approve_listing(_user, _version), do: {:error, "only an admin can approve a listing"}

  @doc "An admin declines listing `version`, with a reason the owner sees."
  def decline_listing(%User{admin: true}, %ToolVersion{} = version, reason) do
    version
    |> Ecto.Changeset.change(declined_at: now(), declined_reason: blank_to_nil(reason))
    |> Repo.update()
  end

  def decline_listing(_user, _version, _reason),
    do: {:error, "only an admin can decline a listing"}

  @doc "The owner (or an admin) takes the Tool off the listing; shares are kept."
  def unlist(%User{} = user, %Tool{} = tool) do
    if owner?(user, tool) or user.admin,
      do: tool |> Ecto.Changeset.change(listed_version_id: nil) |> Repo.update(),
      else: {:error, "only the Tool's owner can unlist it"}
  end

  @doc "The version listed for everyone, or nil."
  def listed_version(%Tool{listed_version_id: nil}), do: nil
  def listed_version(%Tool{listed_version_id: id}), do: Repo.get(ToolVersion, id)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "The Tools shared with `user`, directly or through a group, by name."
  def list_shared(%User{id: user_id} = user) do
    group_ids = Slipdock.Accounts.group_ids_for(user)

    from(t in Tool,
      join: g in Slipdock.Access.Grant,
      on: g.tool_id == t.id,
      where: g.user_id == ^user_id or g.group_id in ^group_ids,
      where: t.owner_id != ^user_id,
      distinct: true,
      order_by: [asc: t.slug]
    )
    |> Repo.all()
  end

  @doc "Whether `tool` is shared with `user`, directly or through a group."
  def shared_with?(%User{id: user_id} = user, %Tool{id: tool_id}) do
    group_ids = Slipdock.Accounts.group_ids_for(user)

    Repo.exists?(
      from(g in Slipdock.Access.Grant,
        where: g.tool_id == ^tool_id,
        where: g.user_id == ^user_id or g.group_id in ^group_ids
      )
    )
  end

  def shared_with?(_, _), do: false

  @doc """
  Shares `tool` with `subject` (a user, a group, or an email address) so
  they can see and install it. Only its owner can share it.
  """
  def share(%User{} = owner, %Tool{} = tool, subject) do
    if owner?(owner, tool),
      do: Slipdock.Access.grant(tool, subject, "read", owner),
      else: {:error, "only the Tool's owner can share it"}
  end

  @doc "Takes back the share `grant_id` on `tool`. Owner only."
  def unshare(%User{} = owner, %Tool{} = tool, grant_id) do
    with true <- owner?(owner, tool) || {:error, "only the Tool's owner can share it"},
         %Slipdock.Access.Grant{} = grant <-
           Repo.get_by(Slipdock.Access.Grant, id: grant_id, tool_id: tool.id) ||
             {:error, "that share is not on this Tool"} do
      Slipdock.Access.revoke(grant)
    end
  end

  @doc "Who `tool` is shared with."
  def grants(%Tool{} = tool), do: Slipdock.Access.list_grants(tool)

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

  @doc "Whether `user` may see `tool` at all: their own, shared with them, or listed."
  def visible?(user, tool), do: access(user, tool) != :none

  @doc """
  How `user` reaches `tool`: `:owner`, `:shared` (granted to them or a group
  of theirs), `:listed` (an admin approved a version for everyone), or
  `:none`. Owners and grantees see every version; somebody who sees it only
  because it is listed sees the listed version and nothing newer.
  """
  def access(%User{id: id}, %Tool{owner_id: id}), do: :owner

  def access(%User{} = user, %Tool{} = tool) do
    cond do
      shared_with?(user, tool) -> :shared
      tool.listed_version_id -> :listed
      true -> :none
    end
  end

  def access(_user, _tool), do: :none

  @doc "Whether `user` owns `tool`."
  def owner?(%User{id: id}, %Tool{owner_id: id}), do: true
  def owner?(_user, _tool), do: false

  @doc """
  The version `user` sees of `tool`: the one asked for (by number) or else
  the latest. nil when there is none.
  """
  def visible_version(user, %Tool{} = tool, number \\ nil) do
    case access(user, tool) do
      :none ->
        nil

      :listed ->
        listed = Repo.get(ToolVersion, tool.listed_version_id)
        if number in [nil, ""] or (listed && listed.version == to_string(number)), do: listed

      _ ->
        if number in [nil, ""], do: latest_version(tool), else: get_version(tool, number)
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

  @doc "One skill of `version` as `{:ok, [{path, bytes}]}`, or `{:error, :not_found}`."
  def skill_files(%ToolVersion{} = version, name) do
    case List.keyfind(skill_trees(version), name, 0) do
      {^name, files} -> {:ok, files}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Every skill of `version` as one gzipped tar, laid out the way a skills
  directory is: `<skill>/SKILL.md`, `<skill>/references/…`, and the
  package's `local` files beside the skill they belong to. What
  `slipdock tools install` unpacks into `~/.claude/skills`.
  """
  def skills_tarball(%ToolVersion{} = version) do
    for {name, files} <- skill_trees(version), {path, bytes} <- files do
      {String.to_charlist(Path.join(name, path)), bytes}
    end
    |> tarball()
  end

  @doc """
  The whole package of `version` as a gzipped tar, every file at its path in
  the package (`tool.json`, `README.md`, `skills/…`, `files/…`). It is not
  the archive that was uploaded, which isn't kept, but it holds the same
  files and publishes as it stands: `Package.read/1` takes it back with the
  same sha.
  """
  def package_tarball(%ToolVersion{} = version) do
    version
    |> files()
    |> Enum.map(&{String.to_charlist(&1.path), &1.content})
    |> tarball()
  end

  @doc "What `package_tarball/1` is saved as: `<name>-<version>.tar.gz`."
  def package_filename(%ToolVersion{} = version) do
    %{tool: tool} = Repo.preload(version, :tool)
    "#{tool.slug}-#{version.version}.tar.gz"
  end

  defp tarball(entries) do
    path =
      Path.join(System.tmp_dir!(), "tool-#{System.unique_integer([:positive])}.tar.gz")

    try do
      with :ok <- :erl_tar.create(String.to_charlist(path), entries, [:compressed, :write]),
           {:ok, bytes} <- File.read(path) do
        {:ok, bytes}
      else
        _ -> {:error, :unavailable}
      end
    after
      File.rm(path)
    end
  end

  @doc """
  One skill as the `.zip` claude.ai's skill upload takes (Settings →
  Capabilities): `<skill>/SKILL.md` and the rest of its folder.
  """
  def claude_zip(%ToolVersion{} = version, name) do
    with {:ok, files} <- skill_files(version, name),
         do: Slipdock.Skills.ChatGPT.zip_files(name, files)
  end

  @doc "One skill as ChatGPT's skill upload takes it, with a note on the connector."
  def chatgpt_zip(%ToolVersion{} = version, name, base_url) do
    with {:ok, files} <- skill_files(version, name),
         do: Slipdock.Skills.ChatGPT.zip_skill(name, files, base_url)
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
  with `created: false`, and makes nothing new. Installing a newer version
  over it upgrades it (#965): only what the board is missing is added —
  lists, folders, tags, pages, rules, files — and a page is replaced only
  while it is still exactly the skeleton the installed version made, so
  nothing the person wrote is overwritten. The install's version moves on
  and `upgraded: true` comes back with the report. Nothing outside the
  board is touched.

  Returns `{:ok, %{install:, board:, created:, upgraded:, version:, report:}}`, or
  `{:error, :not_found}` for a Tool or version `user` can't see, or
  `{:error, message}`.
  """
  def install_board(%User{} = user, %Tool{} = tool, opts \\ []) do
    with %ToolVersion{} = version <-
           visible_version(user, tool, opts[:version]) || {:error, :not_found} do
      case current_install(user, tool) do
        %Install{board: %Boards.Board{} = board} = install ->
          if Version.compare(version.version, install.version) == :gt,
            do: upgrade(user, tool, version, install),
            else: {:ok, unchanged(install, board, version)}

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

  defp unchanged(install, board, version),
    do: %{
      install: install,
      board: board,
      created: false,
      upgraded: false,
      version: version,
      report: nil
    }

  defp upgrade(user, tool, version, install) do
    old = get_version(tool, install.version)
    board = Boards.get_board!(install.board_id)
    message = "upgraded by the #{tool.name} Tool to #{version.version}"

    # The old version's skeletons, by title: what an unedited page still says.
    refresh =
      for %{"title" => title} = page <- (old && old.board && old.board["pages"]) || [],
          into: %{},
          do: {title, page}

    Repo.transaction(fn ->
      with {:ok, report} <-
             Blueprint.apply(board, version.board || Blueprint.empty(),
               user: user,
               message: message,
               refresh_pages: refresh
             ),
           {:ok, files} <- put_board_files(board, version, user),
           {:ok, install} <-
             install |> Ecto.Changeset.change(version: version.version) |> Repo.update() do
        %{
          install: install,
          board: Boards.get_board!(board.id),
          created: false,
          upgraded: true,
          version: version,
          report: put_in(report, [:added, "files"], files)
        }
      else
        {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(changeset_message(cs))
        {:error, message} -> Repo.rollback(message)
      end
    end)
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
          upgraded: false,
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
