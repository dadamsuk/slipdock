defmodule Slipdock.Wiki.Move do
  @moduledoc """
  Moving a page to another board of its vault (W-103 R11.8, and change #5 in
  the PRD's list of changes to existing behaviour).

  A page that moves keeps what is its own: its code (`W-31`, so every link and
  commit message naming it still finds it), its revisions, comments, status
  updates, checklist, web links, votes, attachments, the links it makes and
  the placements in other folders that it has (R12.4). The pages under it go
  with it, as they do when it is archived.

  What belongs to its board cannot simply go along, so each is carried across
  where the target board has a match and dropped where it has none:

    * tags, by name, to the target board's tags;
    * custom field values, by the field's key, to the target board's fields;
    * pinned cards stay pinned when the card is in the target board's tree;
    * its assignee, when they can open the target board;
    * its place in one of the board's lists, never (lists are the board's);
    * its parent page, which stays behind: the page lands at the top.

  `preview/3` says all of that before anything moves, and `to_board/5` does
  it in one transaction. A whole folder moves with `Slipdock.Wiki.FolderMove`,
  which carries its pages across the same way.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo, Vaults, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Column, FieldDefinition, FieldValue, Tag}
  alias Slipdock.Wiki.{Changes, Folder, Link, Page, Placement}

  @type report :: %{
          pages: pos_integer,
          tags: %{carried: [String.t()], dropped: [String.t()]},
          fields: %{carried: [String.t()], dropped: [String.t()]},
          pins: %{carried: [String.t()], dropped: [String.t()]},
          assignee: %{carried: String.t() | nil, dropped: String.t() | nil},
          list: String.t() | nil,
          parent: String.t() | nil
        }

  @doc """
  What moving `page` to `target` would carry across and what it would drop,
  for `user` — or why it cannot move at all.
  """
  @spec preview(Page.t(), Board.t(), User.t()) :: {:ok, report} | {:error, atom, String.t()}
  def preview(%Page{} = page, %Board{} = target, %User{} = user) do
    with :ok <- check(page, target, user) do
      pages = [page | Wiki.descendants(page)]
      ids = Enum.map(pages, & &1.id)
      {tags, _map} = tag_plan(ids, target)
      {fields, _map} = field_plan(ids, target)
      pins = pin_plan(ids, target)

      {:ok,
       %{
         pages: length(pages),
         tags: tags,
         fields: fields,
         pins: Map.take(pins, [:carried, :dropped]),
         assignee: assignee_plan(page, target),
         list: list_of(page),
         parent:
           page.parent_id &&
             Repo.one(from(p in Page, where: p.id == ^page.parent_id, select: p.title))
       }}
    end
  end

  @doc """
  Moves `page`, and the pages under it, to `target` — filed in `folder` (a
  folder on `target`, or nil for its top) — carrying across what `preview/3`
  says it carries. `{:ok, page}` with the page as it now is.
  """
  def to_board(%Page{} = page, %Board{} = target, folder, %User{} = user, opts \\ []) do
    with :ok <- check(page, target, user),
         :ok <- check_folder(folder, target) do
      source_id = page.board_id
      pages = [page | Wiki.descendants(page)]
      ids = Enum.map(pages, & &1.id)
      folder_id = folder && folder.id

      result =
        Repo.transaction(fn ->
          Enum.each(pages, fn p ->
            p
            |> Ecto.Changeset.change(
              board_id: target.id,
              slug: free_slug(p, target),
              # The page itself lands at the top of the target, in the folder
              # asked for; the pages under it keep their parent and follow it
              # into that folder, so the tree draws them where they were.
              parent_id: if(p.id == page.id, do: nil, else: p.parent_id),
              folder_id: folder_id,
              column_id: nil,
              board_position: 0,
              assignee_id: if(reader?(p.assignee_id, target), do: p.assignee_id)
            )
            |> Repo.update!()
          end)

          {_report, tag_map} = tag_plan(ids, target)
          retag(ids, tag_map)
          {_report, field_map} = field_plan(ids, target)
          refield(ids, field_map)
          unpin(pin_plan(ids, target).unpin)

          # A placement in the folder the page now lives in would be its home
          # twice over.
          if folder_id,
            do:
              Repo.delete_all(
                from(pl in Placement, where: pl.page_id in ^ids and pl.folder_id == ^folder_id)
              )

          Repo.get!(Page, page.id)
        end)

      with {:ok, moved} <- result do
        for id <- ids, board <- [source_id, target.id], do: Changes.record(board, "page", id)
        Wiki.broadcast_board(source_id)
        Wiki.broadcast_board(target.id)
        log_move(moved, source_id, target, opts)
        {:ok, moved}
      end
    end
  end

  ## Checks --------------------------------------------------------------------

  defp check(%Page{board_id: id}, %Board{id: id}, _user),
    do: {:error, :unprocessable_entity, "the page is on that board already"}

  defp check(%Page{} = page, %Board{} = target, user) do
    source = Repo.get!(Board, page.board_id)
    vault = Vaults.for_board(source)

    cond do
      is_nil(vault) or vault_id(Vaults.for_board(target)) != vault.id ->
        {:error, :unprocessable_entity, "a page moves only between boards in the same vault"}

      not (writer?(user, source) and writer?(user, target)) ->
        {:error, :forbidden, "you need to be able to edit both boards"}

      true ->
        :ok
    end
  end

  defp vault_id(nil), do: nil
  defp vault_id(%{id: id}), do: id

  defp check_folder(nil, _target), do: :ok
  defp check_folder(%Folder{board_id: id}, %Board{id: id}), do: :ok

  defp check_folder(_folder, _target),
    do: {:error, :unprocessable_entity, "that folder is not on that board"}

  defp writer?(user, board), do: Access.can_write?(Access.board_permission(user, board))

  @doc false
  def reader?(nil, _board), do: false

  def reader?(user_id, board) do
    case Repo.get(User, user_id) do
      nil -> false
      user -> Access.can_read?(Access.board_permission(user, board))
    end
  end

  ## What is carried ------------------------------------------------------------

  # The pages' tags, matched by name (case aside) to the target's.
  @doc false
  def tag_plan(ids, target) do
    tags =
      from(t in Tag,
        join: pt in "page_tags",
        on: pt.tag_id == t.id,
        where: pt.page_id in ^ids,
        distinct: true,
        select: t
      )
      |> Repo.all()

    theirs =
      from(t in Tag, where: t.board_id == ^Board.root_id(target))
      |> Repo.all()
      |> Map.new(&{String.downcase(&1.name), &1})

    map = Map.new(tags, &{&1.id, theirs[String.downcase(&1.name)]})

    {%{
       carried: for(t <- tags, map[t.id], do: t.name) |> Enum.sort(),
       dropped: for(t <- tags, is_nil(map[t.id]), do: t.name) |> Enum.sort()
     }, map}
  end

  @doc false
  def retag(ids, map) do
    rows =
      from(pt in "page_tags", where: pt.page_id in ^ids, select: {pt.page_id, pt.tag_id})
      |> Repo.all()

    Repo.delete_all(from(pt in "page_tags", where: pt.page_id in ^ids))

    new =
      for {page_id, tag_id} <- rows,
          %Tag{id: to} <- [map[tag_id]],
          uniq: true,
          do: %{page_id: page_id, tag_id: to}

    if new != [], do: Repo.insert_all("page_tags", new, on_conflict: :nothing)
  end

  # Custom field values, matched by the field's key.
  @doc false
  def field_plan(ids, target) do
    fields =
      from(f in FieldDefinition,
        join: v in FieldValue,
        on: v.field_id == f.id,
        where: v.page_id in ^ids,
        distinct: true,
        select: f
      )
      |> Repo.all()

    theirs =
      from(f in FieldDefinition, where: f.board_id == ^Board.root_id(target))
      |> Repo.all()
      |> Map.new(&{&1.key, &1})

    map =
      Map.new(
        fields,
        &{&1.id, theirs[&1.key] && theirs[&1.key].kind == &1.kind && theirs[&1.key]}
      )

    {%{
       carried: for(f <- fields, map[f.id], do: f.name) |> Enum.sort(),
       dropped: for(f <- fields, !map[f.id], do: f.name) |> Enum.sort()
     }, map}
  end

  @doc false
  def refield(ids, map) do
    Enum.each(map, fn
      {from, %FieldDefinition{id: to}} ->
        Repo.update_all(from(v in FieldValue, where: v.page_id in ^ids and v.field_id == ^from),
          set: [field_id: to]
        )

      {from, _none} ->
        Repo.delete_all(from(v in FieldValue, where: v.page_id in ^ids and v.field_id == ^from))
    end)
  end

  # Cards the pages are pinned to: kept when the card is in the target's tree.
  @doc false
  def pin_plan(ids, target) do
    root = Board.root_id(target)

    pins =
      from(l in Link,
        join: c in assoc(l, :target_card),
        join: b in Board,
        on: b.id == c.board_id,
        where: l.page_id in ^ids and l.pinned,
        select: {l.id, c.title, coalesce(b.root_id, b.id)}
      )
      |> Repo.all()

    {kept, dropped} = Enum.split_with(pins, fn {_id, _title, r} -> r == root end)

    %{
      carried: kept |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort(),
      dropped: dropped |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort(),
      unpin: Enum.map(dropped, &elem(&1, 0))
    }
  end

  @doc false
  def unpin([]), do: :ok
  def unpin(ids), do: Repo.update_all(from(l in Link, where: l.id in ^ids), set: [pinned: false])

  defp assignee_plan(%Page{assignee_id: nil}, _target), do: %{carried: nil, dropped: nil}

  defp assignee_plan(%Page{assignee_id: id}, target) do
    name = Repo.one(from(u in User, where: u.id == ^id, select: coalesce(u.name, u.email)))

    if reader?(id, target),
      do: %{carried: name, dropped: nil},
      else: %{carried: nil, dropped: name}
  end

  defp list_of(%Page{column_id: nil}), do: nil

  defp list_of(%Page{column_id: id}),
    do: Repo.one(from(c in Column, where: c.id == ^id, select: c.name))

  # A slug taken on the target gets the page's code on the end, which no
  # other page has.
  @doc false
  def free_slug(%Page{} = page, target) do
    taken? =
      Repo.exists?(from(p in Page, where: p.board_id == ^target.id and p.slug == ^page.slug))

    if taken?, do: page.slug <> "-" <> String.downcase(page.code || "#{page.id}"), else: page.slug
  end

  defp log_move(page, source_id, target, _opts) do
    source = Repo.get(Board, source_id)

    Repo.insert(%Slipdock.Boards.Activity{
      board_id: target.id,
      page_id: page.id,
      kind: "page_moved",
      message: "moved “#{page.title}” here from #{source && source.name}"
    })
  end
end
