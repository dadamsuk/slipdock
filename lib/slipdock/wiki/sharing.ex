defmodule Slipdock.Wiki.Sharing do
  @moduledoc """
  What somebody may do with a wiki page, file or folder that was *shared*
  with them, as against one on a board they can write to (#816).

  A writer on the board keeps everything they have always had: every check
  here answers `:ok` for them, and so it does for anybody who reaches the
  thing some other way than a share (a board reader, a card's writer),
  whose answer stays the caller's own permission check. The rules are for a **sharee writer** — whose
  write comes only from a grant on the page or on a folder above it (see
  `Slipdock.Access.share_permission/2`):

    * **may** edit what is shared, rename it, make pages, files, drawings and
      subfolders inside a shared folder, and move things about within the
      shared subtree;
    * **may not** delete, archive or restore anything; move anything out of
      the share, to the board's top or to another board; reorganise the
      folders above it; change or pass on the share (a grant, or a public
      link); or turn on encryption.
    * A sharee of a single page (no folder grant) edits and renames it, and
      cannot move it at all.

  New things are made on the owner's board, so they count against the
  owner's quota (`Slipdock.Quota` counts by board), and record the sharee as
  their creator.

  Every refusal is `{:error, :shared, code, message}`: the API answers it as
  a 403 with `"error": code` (`shared_no_delete`, …), the MCP tools and the
  views with the message. The codes are in `codes/0`.

  The wiki's contexts call `check/3` themselves where they know who is
  writing (making a page, moving one); the API, the MCP tools and the views
  call it for the actions that take no writer (archiving, deleting).
  """

  import Ecto.Query, only: [from: 2]

  alias Slipdock.{Access, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.{Folder, Page, WikiFile}

  @codes %{
    "shared_read_only" => "It was shared with you to read, not to change.",
    "shared_no_delete" =>
      "It was shared with you: only people who can edit its board can delete, archive or restore it.",
    "shared_no_move" => "A page shared with you on its own can be edited and renamed, not moved.",
    "shared_no_move_out" =>
      "It was shared with you: it can only be moved to somewhere else inside the shared folder.",
    "shared_no_create" =>
      "You can only make things inside a folder that was shared with you to edit.",
    "shared_no_reshare" =>
      "It was shared with you: only people who can edit its board can share it, or publish it.",
    "shared_no_encrypt" => "It was shared with you: only its board's writers can encrypt it.",
    "shared_no_organise" =>
      "It was shared with you: only its board's writers can reorganise its folders."
  }

  @doc "Every refusal code, with the message it comes with."
  def codes, do: @codes

  @type action ::
          :edit
          | :delete
          | :share
          | :encrypt
          | :organise
          | {:move, Folder.t() | nil | {:board, integer}}
          | {:create, Folder.t() | integer | nil}

  @type item :: Page.t() | Folder.t() | WikiFile.t()

  @doc """
  `:ok` when `user` may do `action` to `item`, or the refusal. For
  `{:create, folder}` the item is the board the thing is made on.

  `nil` for a user is the system (a sync, an import), which these rules do
  not narrow.
  """
  @spec check(User.t() | nil, action, item | Board.t()) ::
          :ok | {:error, :shared, String.t(), String.t()}
  def check(user, _action, _item) when not is_struct(user, User), do: :ok

  def check(%User{} = user, {:create, folder}, %Board{} = board) do
    cond do
      board_writer?(user, board.id) -> :ok
      inside_share?(user, folder, board.id) -> :ok
      # Somebody with nothing shared on this board is not a sharee: what they
      # may make here is the caller's to decide, as it always was.
      not shares_on_board?(user, board.id) -> :ok
      true -> refuse("shared_no_create")
    end
  end

  def check(%User{} = user, action, item) do
    cond do
      board_writer?(user, item.board_id) -> :ok
      # Reached some other way (a board reader, a card's writer): not ours.
      Access.share_permission(user, item) == :none -> :ok
      true -> sharee(user, action, item)
    end
  end

  @doc "Whether the user writes on the board itself, rather than through a share."
  def board_writer?(%User{} = user, board_id),
    do: Access.can_write?(Access.board_permission(user, Repo.get!(Board, board_id)))

  # Whether anything on the board — a page, a folder — is shared with them.
  defp shares_on_board?(user, board_id) do
    group_ids = Slipdock.Accounts.group_ids_for(user)

    Repo.exists?(
      from(g in Slipdock.Access.Grant,
        left_join: p in Page,
        on: p.id == g.page_id,
        left_join: f in Folder,
        on: f.id == g.folder_id,
        where: g.user_id == ^user.id or g.group_id in ^group_ids,
        where: p.board_id == ^board_id or f.board_id == ^board_id
      )
    )
  end

  @doc "A refusal for `code`, as `check/3` gives it."
  def refuse(code), do: {:error, :shared, code, Map.fetch!(@codes, code)}

  # A sharee whose write comes from the share. What they can only read they
  # cannot change at all.
  defp sharee(user, action, item) do
    if write?(Access.share_permission(user, item)),
      do: sharee_writer(user, action, item),
      else: refuse("shared_read_only")
  end

  defp sharee_writer(_user, :edit, _item), do: :ok
  defp sharee_writer(_user, :delete, _item), do: refuse("shared_no_delete")
  defp sharee_writer(_user, :share, _item), do: refuse("shared_no_reshare")
  defp sharee_writer(_user, :encrypt, _item), do: refuse("shared_no_encrypt")
  defp sharee_writer(_user, :organise, _item), do: refuse("shared_no_organise")

  defp sharee_writer(user, {:move, target}, item) do
    cond do
      # Shared on its own, a page stays where its owner put it.
      not in_shared_folder?(user, item) -> refuse("shared_no_move")
      not inside_share?(user, target, item.board_id) -> refuse("shared_no_move_out")
      true -> :ok
    end
  end

  # Whether the item's place is inside a folder shared with the user to
  # edit: a page's or file's home folder, a folder's parent. A folder shared
  # itself is the top of the share, and its parent is the owner's, so it
  # does not move.
  defp in_shared_folder?(user, %Page{folder_id: id}), do: write_in?(user, id)
  defp in_shared_folder?(user, %WikiFile{folder_id: id}), do: write_in?(user, id)
  defp in_shared_folder?(user, %Folder{parent_id: id}), do: write_in?(user, id)

  defp inside_share?(_user, nil, _board_id), do: false
  defp inside_share?(_user, {:board, _}, _board_id), do: false

  defp inside_share?(user, %Folder{} = folder, board_id),
    do: folder.board_id == board_id and write_in?(user, folder.id)

  defp inside_share?(user, id, board_id) when is_integer(id) do
    case Repo.get(Folder, id) do
      %Folder{} = folder -> inside_share?(user, folder, board_id)
      nil -> false
    end
  end

  defp write_in?(_user, nil), do: false
  defp write_in?(user, folder_id), do: write?(Access.folder_grant_level(user, folder_id))

  defp write?(level), do: Access.can_write?(level)
end
