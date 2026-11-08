defmodule Slipdock.SkillRegistry do
  @moduledoc """
  The external skills registry (#2059, spec W-2513): skill collections a user
  points the server at, fetched and kept so a board's agents can be given
  their text without anything installed locally.

  A **source** is a URL a user added (see `Slipdock.SkillRegistry.GitHub` for
  the shapes it takes). Adding one fetches it, through `Slipdock.Egress`
  (`Slipdock.SkillRegistry.Fetch`), and stores each SKILL.md under it as an
  **entry**, with its front matter's name and description, its text, the
  commit sha (or ETag) as its version, the repository's licence and when it
  was fetched. What a fetch skips — a SKILL.md with no name, one too large,
  more files than a source may hold — is kept on the source as `report`.

  A source belongs to the user who added it, who alone refreshes or removes
  it. One with no owner is a seed: every user sees it, and only an admin
  changes it (`add_seed/2`). A new server starts with a few seeds
  (`Slipdock.SkillRegistry.Seeds`). Nothing here runs a skill: an entry is
  text.

  Caps, under `config :slipdock, :skill_registry`: `max_file_bytes` (256 KB)
  for each file, `max_entries` (50) for each source.
  """

  import Ecto.Query

  alias Slipdock.Accounts
  alias Slipdock.Accounts.User
  alias Slipdock.Repo
  alias Slipdock.SkillRegistry.{Entry, Fetch, GitHub, Parse, Pins, Source}

  @max_file_bytes 256_000
  @max_entries 50

  @type changes :: %{
          added: [String.t()],
          changed: [String.t()],
          removed: [String.t()],
          unchanged: [String.t()]
        }

  ## Reading ---------------------------------------------------------------

  @doc "The sources `user` sees: their own and the seeds, by name, with entries."
  @spec list_sources(User.t()) :: [Source.t()]
  def list_sources(%User{id: user_id}) do
    from(s in Source,
      where: s.owner_id == ^user_id or is_nil(s.owner_id),
      order_by: [asc: is_nil(s.owner_id), asc: s.name, asc: s.id],
      preload: :entries
    )
    |> Repo.all()
  end

  @doc "A source `user` sees, with its entries, or nil."
  @spec get_source(User.t(), integer() | String.t()) :: Source.t() | nil
  def get_source(%User{id: user_id}, id) do
    from(s in Source,
      where: s.id == ^id and (s.owner_id == ^user_id or is_nil(s.owner_id)),
      preload: :entries
    )
    |> Repo.one()
  end

  @doc "An entry from a source `user` sees, with its source, or nil."
  @spec get_entry(User.t(), integer() | String.t()) :: Entry.t() | nil
  def get_entry(%User{id: user_id}, id) do
    from(e in Entry,
      join: s in assoc(e, :source),
      where: e.id == ^id and (s.owner_id == ^user_id or is_nil(s.owner_id)),
      preload: [source: s]
    )
    |> Repo.one()
  end

  @doc "Whether `user` may refresh or remove `source`: its owner, or an admin for a seed."
  @spec can_manage?(User.t() | nil, Source.t()) :: boolean()
  def can_manage?(%User{id: id}, %Source{owner_id: id}) when not is_nil(id), do: true
  def can_manage?(%User{} = user, %Source{owner_id: nil}), do: Accounts.admin?(user)
  def can_manage?(_user, _source), do: false

  ## Writing ---------------------------------------------------------------

  @doc """
  Adds the source at `url` for `user` (nil for a seed): fetches it and stores
  its entries. `{:error, sentence}` when it can't be fetched, holds no skill
  that can be read, or is already one of the user's sources. With `seed:
  true` it is a seed instead, and only an admin may (`add_seed/2`).
  """
  @spec add_source(User.t() | nil, String.t(), keyword()) ::
          {:ok, Source.t()} | {:error, String.t()}
  def add_source(user, url, opts \\ []) do
    if opts[:seed], do: add_seed(user, url), else: add_own(user, url)
  end

  defp add_own(user, url) when is_binary(url) do
    url = String.trim(url)
    owner_id = user && user.id

    if exists?(owner_id, url) do
      {:error, "#{url} is already one of #{if user, do: "your sources", else: "the seeds"}."}
    else
      with {:ok, fetched} <- fetch(url), do: store(owner_id, url, fetched)
    end
  end

  defp add_own(_user, _url), do: {:error, "A source needs a URL."}

  @doc """
  Adds the source at `url` as a seed (#2075): owned by no one, seen by every
  user, enabled nowhere. Only an admin may; `add_source(user, url, seed:
  true)` comes here. The seeds a new server starts with are
  `Slipdock.SkillRegistry.Seeds`.
  """
  @spec add_seed(User.t(), String.t()) :: {:ok, Source.t()} | {:error, String.t()}
  def add_seed(%User{} = user, url) do
    if Accounts.admin?(user),
      do: add_own(nil, url),
      else: {:error, "Only an admin can add a source for everyone."}
  end

  def add_seed(_user, _url), do: {:error, "Only an admin can add a source for everyone."}

  defp store(owner_id, url, fetched) do
    Repo.transaction(fn ->
      source =
        %Source{owner_id: owner_id}
        |> Source.changeset(source_attrs(url, fetched))
        |> Repo.insert()
        |> or_rollback()

      Enum.each(fetched.entries, &insert_entry(source, &1))
      Repo.preload(source, :entries, force: true)
    end)
  end

  @doc """
  Fetches `source` again. Entries are matched by path: one whose text changed
  is updated in place, a new one added, one no longer there removed. Returns
  the names in each group. Refused for a user who can't manage it; a failed
  fetch leaves the source as it was.
  """
  @spec refresh_source(User.t(), Source.t()) ::
          {:ok, Source.t(), changes} | {:error, String.t()}
  def refresh_source(user, %Source{} = source) do
    with :ok <- manage(user, source),
         {:ok, fetched} <- fetch(source.url) do
      Repo.transaction(fn ->
        source = Repo.preload(source, :entries, force: true)

        updated =
          source
          |> Source.changeset(source_attrs(source.url, fetched))
          |> Repo.update()
          |> or_rollback()

        changes = apply_entries(updated, source.entries, fetched.entries)
        {Repo.preload(updated, :entries, force: true), changes}
      end)
      |> case do
        {:ok, {source, changes}} -> {:ok, source, changes}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Deletes `source` and its entries. Refused for a user who can't manage it."
  @spec remove_source(User.t(), Source.t()) :: {:ok, Source.t()} | {:error, String.t()}
  def remove_source(user, %Source{} = source) do
    with :ok <- manage(user, source) do
      case Repo.delete(source) do
        {:ok, source} -> {:ok, source}
        {:error, _} -> {:error, "#{source.name} could not be removed."}
      end
    end
  end

  ## Enabled on a board (#2062) -------------------------------------------

  @doc """
  Enables the entry `entry_id` on `board`'s tree for `user`, pinned to
  `seen_hash`, the hash of the text they read (`Slipdock.SkillRegistry.Pins`).
  The entry must be one `user` sees.
  """
  @spec enable(User.t(), Slipdock.Boards.Board.t(), integer() | String.t(), String.t()) ::
          {:ok, Slipdock.SkillRegistry.Enablement.t()} | {:error, String.t()}
  def enable(user, board, entry_id, seen_hash) do
    case get_entry(user, entry_id) do
      nil -> {:error, "That skill isn't one you can see."}
      entry -> Pins.enable(user, board, entry, seen_hash)
    end
  end

  defdelegate repin(user, enablement, seen_hash), to: Pins
  defdelegate disable(user, enablement), to: Pins
  defdelegate enabled(board), to: Pins
  defdelegate get_enabled(board, name), to: Pins
  defdelegate status(enablement), to: Pins
  defdelegate diff(enablement), to: Pins
  defdelegate stages(board), to: Pins
  defdelegate naming(user), to: Pins
  defdelegate naming(user, name), to: Pins
  defdelegate enabled_where(user, entry), to: Pins
  defdelegate writable_boards(user), to: Pins
  defdelegate get_enablement(user, id), to: Pins

  ## The fetch -------------------------------------------------------------

  @doc """
  Fetches what `url` points at, storing nothing: `{:ok, %{kind, name, licence,
  version, report, entries}}` or `{:error, sentence}`.
  """
  @spec fetch(String.t()) :: {:ok, map()} | {:error, String.t()}
  def fetch(url) do
    case GitHub.target(url) do
      {:ok, target} -> fetch_target(target, url)
      {:error, reason} -> {:error, "#{url} #{reason}."}
    end
  end

  defp fetch_target({:file, url}, _url) do
    with {:ok, %{body: body, etag: etag}} <- file(url, url),
         {:ok, parsed} <- parse(body, nil, url) do
      version = etag || "sha256:" <> String.slice(hash(body), 0, 12)
      entry = entry_attrs(parsed, path_of(url), body, version, nil)
      {:ok, fetched("file", short_url(url), nil, version, [entry], [])}
    end
  end

  defp fetch_target({:repo_file, t}, url) do
    with {:ok, repo} <- repo(t.owner, t.repo, t.ref, tree: false),
         raw = GitHub.raw_url(t.owner, t.repo, repo.sha, t.path),
         {:ok, %{body: body}} <- file(raw, url),
         {:ok, parsed} <- parse(body, nil, url) do
      entry = entry_attrs(parsed, t.path, body, repo.sha, repo.licence)
      {:ok, fetched("file", "#{repo.name}/#{t.path}", repo.licence, repo.sha, [entry], [])}
    end
  end

  defp fetch_target({:repo, t}, url) do
    with {:ok, repo} <- repo(t.owner, t.repo, t.ref, []) do
      prefix = String.trim(t.path, "/")
      name = if prefix == "", do: repo.name, else: "#{repo.name}/#{prefix}"
      files = Enum.filter(repo.files, &under?(&1.path, prefix))
      skills = files |> Enum.filter(&(basename(&1.path) == "SKILL.md")) |> Enum.sort_by(& &1.path)

      {picked, fallback, report} = pick(skills, files, prefix, t.repo)
      report = if repo.truncated, do: [truncated() | report], else: report

      {entries, skipped} = fetch_files(picked, t, repo, fallback)

      case entries do
        [] -> {:error, nothing_readable(url, report ++ skipped)}
        _ -> {:ok, fetched("github", name, repo.licence, repo.sha, entries, report ++ skipped)}
      end
    end
  end

  defp repo(owner, name, ref, opts) do
    case GitHub.repository(owner, name, ref, opts) do
      {:ok, repo} -> {:ok, repo}
      {:error, reason} -> {:error, sentence(reason)}
    end
  end

  # SKILL.md files up to the cap; with none, the README at the prefix.
  defp pick([], files, prefix, repo_name) do
    readme =
      Enum.find(files, fn file ->
        dirname(file.path) == prefix and String.downcase(basename(file.path)) == "readme.md"
      end)

    fallback = if prefix == "", do: repo_name, else: basename(prefix)
    {List.wrap(readme), fallback, []}
  end

  defp pick(skills, _files, _prefix, _repo_name) do
    max = max_entries()
    {picked, rest} = Enum.split(skills, max)

    report =
      if rest == [],
        do: [],
        else: ["#{length(rest)} more SKILL.md files were left out (at most #{max} per source)."]

    {picked, nil, report}
  end

  defp fetch_files(files, t, repo, fallback) do
    max = max_file_bytes()

    files
    |> Enum.map(fn file ->
      with :ok <- small_enough(file, max),
           {:ok, %{body: body}} <-
             file(GitHub.raw_url(t.owner, t.repo, repo.sha, file.path), file.path),
           {:ok, parsed} <- parse(body, fallback, file.path) do
        {:ok, entry_attrs(parsed, file.path, body, repo.sha, repo.licence)}
      end
    end)
    |> Enum.split_with(&match?({:ok, _}, &1))
    |> then(fn {ok, skipped} ->
      {Enum.map(ok, &elem(&1, 1)), Enum.map(skipped, fn {:error, why} -> skipped(why) end)}
    end)
  end

  defp small_enough(%{size: size, path: path}, max) when size > max,
    do: {:error, "#{path} is larger than #{Fetch.size(max)}."}

  defp small_enough(_file, _max), do: :ok

  defp file(url, label) do
    case Fetch.get(url, max_bytes: max_file_bytes()) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, "#{label} #{reason}."}
    end
  end

  defp parse(body, fallback, label) do
    case Parse.entry(body, fallback) do
      {:ok, parsed} -> {:ok, parsed}
      {:skip, reason} -> {:error, "#{label} #{reason}."}
    end
  end

  defp skipped(sentence), do: String.replace_suffix(sentence, ".", ", so it was skipped.")

  defp nothing_readable(url, []), do: "#{url} has no SKILL.md and no README."

  defp nothing_readable(url, report),
    do: "#{url} has no skill Slipdock could read: #{Enum.join(report, " ")}"

  defp truncated, do: "GitHub listed only part of the repository, so some skills may be missing."

  defp fetched(kind, name, licence, version, entries, report),
    do: %{
      kind: kind,
      name: name,
      licence: licence,
      version: version,
      entries: entries,
      report: report
    }

  defp entry_attrs(parsed, path, body, version, licence) do
    %{
      path: path,
      name: parsed.name,
      description: parsed.description,
      body: body,
      content_hash: hash(body),
      version: version,
      licence: licence
    }
  end

  ## Storing ---------------------------------------------------------------

  defp source_attrs(url, fetched) do
    fetched
    |> Map.take([:kind, :name, :licence, :version, :report])
    |> Map.merge(%{url: url, fetched_at: now()})
  end

  defp insert_entry(source, attrs) do
    %Entry{source_id: source.id}
    |> Entry.changeset(Map.put(attrs, :fetched_at, now()))
    |> Repo.insert()
    |> or_rollback()
  end

  defp apply_entries(source, existing, fetched) do
    by_path = Map.new(existing, &{&1.path, &1})
    fetched_paths = MapSet.new(fetched, & &1.path)
    changes = %{added: [], changed: [], removed: [], unchanged: []}

    changes =
      Enum.reduce(fetched, changes, fn attrs, acc ->
        add(acc, upsert_entry(source, by_path[attrs.path], attrs), attrs.name)
      end)

    existing
    |> Enum.reject(&MapSet.member?(fetched_paths, &1.path))
    |> Enum.reduce(changes, fn entry, acc ->
      Repo.delete!(entry)
      add(acc, :removed, entry.name)
    end)
    |> Map.new(fn {group, names} -> {group, Enum.reverse(names)} end)
  end

  defp upsert_entry(source, nil, attrs) do
    insert_entry(source, attrs)
    :added
  end

  defp upsert_entry(_source, entry, attrs) do
    entry |> Entry.changeset(Map.put(attrs, :fetched_at, now())) |> Repo.update!()
    if entry.content_hash == attrs.content_hash, do: :unchanged, else: :changed
  end

  defp add(changes, group, name), do: Map.update!(changes, group, &[name | &1])

  defp or_rollback({:ok, record}), do: record

  defp or_rollback({:error, %Ecto.Changeset{} = changeset}) do
    message =
      Enum.map_join(changeset.errors, "; ", fn {field, {text, _}} -> "#{field} #{text}" end)

    Repo.rollback("The source could not be saved: #{message}.")
  end

  defp exists?(nil, url),
    do: Repo.exists?(from s in Source, where: is_nil(s.owner_id) and s.url == ^url)

  defp exists?(id, url),
    do: Repo.exists?(from s in Source, where: s.owner_id == ^id and s.url == ^url)

  defp manage(user, source) do
    if can_manage?(user, source),
      do: :ok,
      else: {:error, "Only whoever added #{source.name} can change it."}
  end

  ## Helpers ---------------------------------------------------------------

  defp under?(_path, ""), do: true
  defp under?(path, prefix), do: String.starts_with?(path, prefix <> "/")

  defp basename(path), do: path |> String.split("/") |> List.last()

  defp dirname(path) do
    case path |> String.split("/") |> Enum.drop(-1) do
      [] -> ""
      parts -> Enum.join(parts, "/")
    end
  end

  defp path_of(url), do: URI.parse(url).path |> to_string() |> String.trim_leading("/")

  defp short_url(url) do
    uri = URI.parse(url)
    "#{uri.host}#{uri.path}"
  end

  defp sentence(reason) do
    if String.ends_with?(reason, "."), do: reason, else: reason <> "."
  end

  defp hash(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp max_file_bytes, do: config()[:max_file_bytes] || @max_file_bytes
  defp max_entries, do: config()[:max_entries] || @max_entries
  defp config, do: Slipdock.Config.get(:skill_registry, [])
end
