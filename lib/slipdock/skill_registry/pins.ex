defmodule Slipdock.SkillRegistry.Pins do
  @moduledoc """
  Enabling registry entries on a board, pinned (#2062, spec W-2513 §Enabling
  per board, §Which stages name it). Called through `Slipdock.SkillRegistry`.

  - **Enable**: a board writer enables an entry they can see, giving the
    `content_hash` of the text they read. If the entry has changed since,
    it is refused: they read it again first. The text is copied onto the
    enablement (`Slipdock.SkillRegistry.Enablement`), which is what agents
    get from then on.
  - **Changed upstream**: a refresh that changes an enabled entry changes
    the entry, not the enablement. `status/1` says `:changed`, `diff/1`
    gives the lines that differ, and the pinned text is still served.
  - **Re-pin**: a writer who has read the diff re-pins with the new hash;
    a hash that isn't the entry's current one is refused the same way.
  - **Stages**: a Playbook stage names a skill with a `skill: <name>` line
    under its heading. `naming/1` lists, for every board a user reads, the
    stages that name one, whether it is enabled there, and whether it is a
    skill Slipdock ships; one that is neither is flagged.

  A sub-board's enabled skills are its root board's.
  """

  import Ecto.Query

  alias Slipdock.{Access, Boards, Handbook, Repo, Skills}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.SkillRegistry.{Enablement, Entry}

  @type status :: :current | :changed | :removed

  ## Reading -----------------------------------------------------------------

  @doc "The skills enabled on `board`'s tree, by name, with their entries."
  @spec enabled(Board.t()) :: [Enablement.t()]
  def enabled(%Board{} = board) do
    root = root(board)

    from(e in Enablement,
      where: e.board_id == ^root.id,
      order_by: [asc: e.name],
      preload: [entry: :source]
    )
    |> Repo.all()
  end

  @doc "One enabled skill on `board`'s tree, by name, or nil."
  @spec get_enabled(Board.t(), String.t()) :: Enablement.t() | nil
  def get_enabled(%Board{} = board, name) do
    root = root(board)

    from(e in Enablement,
      where: e.board_id == ^root.id and e.name == ^name,
      preload: [entry: :source]
    )
    |> Repo.one()
  end

  @doc """
  Where `entry` is enabled, on the boards `user` reads: each enablement
  with its board, and whether `user` may change it (`writer`).
  """
  @spec enabled_where(User.t(), Entry.t()) :: [%{enablement: Enablement.t(), writer: boolean()}]
  def enabled_where(%User{} = user, %Entry{id: entry_id}) do
    boards = Access.list_boards(user, wiki: false)
    by_id = Map.new(boards, &{&1.id, &1})

    from(e in Enablement,
      where: e.entry_id == ^entry_id and e.board_id in ^Map.keys(by_id),
      order_by: [asc: e.board_id],
      preload: [entry: :source]
    )
    |> Repo.all()
    |> Enum.map(fn e ->
      board = by_id[e.board_id]
      %{enablement: %{e | board: board}, writer: writer(user, board) == :ok}
    end)
  end

  @doc "The boards `user` may enable skills on: the root boards they write to."
  @spec writable_boards(User.t()) :: [Board.t()]
  def writable_boards(%User{} = user) do
    user
    |> Access.list_boards(wiki: false)
    |> Enum.filter(&(writer(user, &1) == :ok))
  end

  @doc """
  An enablement by id, with its board and entry, on a board `user` reads;
  nil otherwise, so a guessed id says nothing about a board they can't see.
  """
  @spec get_enablement(User.t(), integer() | String.t()) :: Enablement.t() | nil
  def get_enablement(%User{} = user, id) do
    with %Enablement{} = e <- Repo.get(Enablement, id),
         e = Repo.preload(e, [:board, entry: :source]),
         true <- Access.can_read?(Access.board_permission(user, e.board)) do
      e
    else
      _ -> nil
    end
  end

  @doc """
  Whether the pinned text is still the entry's: `:current`, `:changed`
  (a refresh changed the entry; the pinned text is still served) or
  `:removed` (the entry has gone from its source).
  """
  @spec status(Enablement.t()) :: status
  def status(%Enablement{entry: nil}), do: :removed
  def status(%Enablement{entry_id: nil}), do: :removed
  def status(%Enablement{entry: %Entry{content_hash: hash}, pinned_hash: hash}), do: :current
  def status(%Enablement{entry: %Entry{}}), do: :changed

  @doc """
  The lines that differ between the pinned text and the entry's text now,
  as `List.myers_difference/2` gives them: `[{:eq | :del | :ins, [line]}]`.
  Empty when the entry has gone.
  """
  @spec diff(Enablement.t()) :: [{:eq | :del | :ins, [String.t()]}]
  def diff(%Enablement{entry: %Entry{body: body}, pinned_body: pinned}),
    do: List.myers_difference(String.split(pinned, "\n"), String.split(body, "\n"))

  def diff(%Enablement{}), do: []

  ## Writing -----------------------------------------------------------------

  @doc """
  Enables `entry` on `board`'s tree for `user`, pinned to `seen_hash`: the
  hash of the text they read. Refused unless they may write to the board,
  if the entry has changed since they read it, or if a skill of that name
  is already enabled there.
  """
  @spec enable(User.t(), Board.t(), Entry.t(), String.t()) ::
          {:ok, Enablement.t()} | {:error, String.t()}
  def enable(%User{} = user, %Board{} = board, %Entry{} = entry, seen_hash) do
    entry = Repo.preload(entry, :source)

    # The board's row read again: the struct an open page kept can name an
    # owner the board no longer has (#2999).
    with %Board{} = board <- Repo.reload(board) || {:error, "That board has gone."},
         root = root(board),
         :ok <- writer(user, root),
         :ok <- seen(entry, seen_hash),
         :ok <- free(root, entry) do
      %Enablement{board_id: root.id}
      |> pin(entry, user)
      |> Repo.insert()
      |> saved(entry.name)
    end
  end

  @doc """
  Re-pins `enablement` to its entry's text now, for a writer who has read
  the diff and gives the hash they saw. Refused for a reader, for a hash
  that isn't the entry's current one, and for an entry that has gone.
  """
  @spec repin(User.t(), Enablement.t(), String.t()) ::
          {:ok, Enablement.t()} | {:error, String.t()}
  def repin(%User{} = user, %Enablement{} = enablement, seen_hash) do
    enablement = Repo.preload(enablement, [:board, entry: :source], force: true)

    with :ok <- writer(user, enablement.board),
         %Entry{} = entry <- enablement.entry || {:error, gone(enablement)},
         :ok <- seen(entry, seen_hash) do
      enablement
      |> pin(entry, user)
      |> Repo.update()
      |> saved(entry.name)
    end
  end

  @doc "Disables `enablement`, for a writer on its board."
  @spec disable(User.t(), Enablement.t()) :: {:ok, Enablement.t()} | {:error, String.t()}
  def disable(%User{} = user, %Enablement{} = enablement) do
    enablement = Repo.preload(enablement, :board)

    with :ok <- writer(user, enablement.board) do
      case Repo.delete(enablement) do
        {:ok, gone} -> {:ok, gone}
        {:error, _} -> {:error, "#{enablement.name} could not be disabled."}
      end
    end
  end

  ## Which stages name it ----------------------------------------------------

  @doc """
  The stages of `board`'s Playbook that name a skill, in page order:
  `[%{stage: "Grill", skill: "grilling"}]`. Empty when the tree has no
  handbook, or its Playbook names none.
  """
  @spec stages(Board.t()) :: [%{stage: String.t(), skill: String.t()}]
  def stages(%Board{} = board) do
    with %{pages: pages} <- Handbook.find(board),
         %{body: body} when is_binary(body) <- Enum.find(pages, &(Handbook.key(&1) == "playbook")) do
      stage_lines(body)
    else
      _ -> []
    end
  end

  @doc """
  The `skill:` lines of a Playbook's text, under the `##` stage each sits
  in. A name is letters, digits, `.`, `_`, `-` and `:`, ending in a letter
  or digit (so a sentence's full stop isn't part of it), optionally in
  backticks; a placeholder such as `skill: <its name>` names nothing.
  """
  @spec stage_lines(String.t()) :: [%{stage: String.t(), skill: String.t()}]
  def stage_lines(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({nil, false, []}, &stage_line/2)
    |> elem(2)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  @skill_line ~r/(?:^|[\s`(])skill:\s*`?([A-Za-z0-9](?:[A-Za-z0-9._:\-]*[A-Za-z0-9])?)`?/

  defp stage_line(line, {stage, fenced, acc}) do
    cond do
      String.starts_with?(String.trim_leading(line), "```") ->
        {stage, not fenced, acc}

      fenced ->
        {stage, fenced, acc}

      String.starts_with?(line, "## ") ->
        {String.trim(String.trim_leading(line, "## ")), false, acc}

      stage == nil ->
        {stage, fenced, acc}

      true ->
        {stage, fenced, named(line, stage, acc)}
    end
  end

  defp named(line, stage, acc) do
    @skill_line
    |> Regex.scan(line, capture: :all_but_first)
    |> Enum.reduce(acc, fn [name], acc -> [%{stage: stage, skill: name} | acc] end)
  end

  @doc """
  For every board `user` reads whose Playbook names a skill: the board and
  each such stage, with the skill enabled there for it (or nil), whether
  Slipdock ships a skill of that name, and `flagged` when it is neither.
  """
  @spec naming(User.t()) :: [%{board: Board.t(), stages: [map()]}]
  def naming(%User{} = user) do
    user
    |> Access.list_boards(wiki: false)
    |> Enum.flat_map(fn board ->
      case stages(board) do
        [] -> []
        stages -> [%{board: board, stages: annotate(board, stages)}]
      end
    end)
  end

  @doc "`naming/1` narrowed to the stages naming `name`."
  @spec naming(User.t(), String.t()) :: [%{board: Board.t(), stages: [map()]}]
  def naming(%User{} = user, name) do
    user
    |> naming()
    |> Enum.flat_map(fn %{stages: stages} = row ->
      case Enum.filter(stages, &(&1.skill == name)) do
        [] -> []
        named -> [%{row | stages: named}]
      end
    end)
  end

  defp annotate(board, stages) do
    by_name = board |> enabled() |> Map.new(&{&1.name, &1})

    Enum.map(stages, fn %{skill: skill} = stage ->
      enablement = by_name[skill]
      shipped = Skills.get(skill) != nil

      Map.merge(stage, %{enabled: enablement, shipped: shipped, flagged: !enablement and !shipped})
    end)
  end

  ## Helpers -----------------------------------------------------------------

  defp root(%Board{root_id: nil} = board), do: board
  defp root(%Board{root_id: id}), do: Boards.get_board!(id)

  defp writer(user, board) do
    if Access.can_write?(Access.board_permission(user, board)),
      do: :ok,
      else: {:error, "Only somebody who can write to #{board.name} changes its skills."}
  end

  defp seen(%Entry{content_hash: hash}, hash) when is_binary(hash), do: :ok

  defp seen(%Entry{name: name}, _seen),
    do: {:error, "#{name} has changed since you read it. Read it again, then enable it."}

  defp free(root, entry) do
    case get_enabled(root, entry.name) do
      nil ->
        :ok

      %Enablement{entry_id: id} when id == entry.id ->
        {:error, "#{entry.name} is already enabled on #{root.name}."}

      %Enablement{source_name: from} ->
        {:error,
         "A skill named #{entry.name} is already enabled on #{root.name}, from #{from}. Disable it first."}
    end
  end

  defp gone(enablement),
    do: "#{enablement.name} has gone from its source, so there is nothing newer to pin."

  # The entry's text now, pinned for `user`; the ids are changes, never cast.
  defp pin(enablement, entry, user) do
    enablement
    |> Enablement.changeset(pin_attrs(entry))
    |> Ecto.Changeset.put_change(:entry_id, entry.id)
    |> Ecto.Changeset.put_change(:enabled_by_id, user.id)
  end

  defp pin_attrs(entry) do
    %{
      name: entry.name,
      description: entry.description,
      source_name: entry.source.name,
      source_url: entry.source.url,
      licence: entry.licence || entry.source.licence,
      version: entry.version,
      pinned_hash: entry.content_hash,
      pinned_body: entry.body,
      pinned_at: DateTime.utc_now(:second)
    }
  end

  defp saved({:ok, enablement}, _name),
    do: {:ok, Repo.preload(enablement, [entry: :source], force: true)}

  defp saved({:error, %Ecto.Changeset{}}, name),
    do: {:error, "#{name} could not be enabled: a skill of that name is already enabled here."}
end
