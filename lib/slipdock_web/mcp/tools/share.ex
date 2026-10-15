defmodule SlipdockWeb.MCP.Tools.Share do
  @moduledoc """
  Shares a wiki page or folder with a person or group, or takes a share
  back (#820) — `POST`/`DELETE /api/pages/:id/grants` and
  `/api/folders/:id/grants` in one tool, to keep the set small. With
  neither `with` nor `group` it lists who has it.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.Sharing
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "share"

  @impl true
  def title, do: "Share a page or folder"

  @impl true
  def description,
    do:
      "Shares a wiki page (code) or a folder (with its board) with a person by email or a group, " <>
        "read or write; a folder shares everything in it. off = true takes it back. Neither " <>
        "with nor group lists who has it. Only the board's writers share; a sharee gets " <>
        "shared_no_reshare."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        page: %{type: "string", description: "Page code like W-31 (or a slug with board)."},
        folder: %{type: "string", description: "Folder name, path or id (with board)."},
        board: %{type: "string", description: "The folder's (or slug's) board."},
        with: %{type: "string", description: "Email of the person to share with."},
        group: %{type: "string", description: "A group of yours, by name or id."},
        level: %{type: "string", enum: ["read", "write"], description: "Default read."},
        off: %{type: "boolean", description: "Take the share back instead."}
      },
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    user = context.user

    with {:ok, item} <- item(args, Args.auth(context), user),
         {:ok, off} <- Args.boolean(args, "off", false) do
      who = %{"email" => args["with"], "group" => args["group"]}

      result =
        cond do
          is_nil(args["with"]) and is_nil(args["group"]) -> Sharing.grants(user, item)
          off -> Sharing.unshare(user, item, who)
          true -> Sharing.share(user, item, who, args["level"] || "read")
        end

      case Args.refusal(result) do
        {:ok, _} -> {:ok, %{shared_with: Enum.map(Access.list_grants(item), &grant/1)}}
        error -> error
      end
    end
  end

  defp item(%{"page" => ref} = args, auth, user) when is_binary(ref) do
    found =
      case args["board"] do
        nil ->
          Wiki.find_page(ref, as: user)

        board_ref ->
          with {:ok, board} <- Authorize.fetch_board(auth, board_ref, :read),
               do: Wiki.find_page(board, ref)
      end

    case found do
      {:ok, page} ->
        if Access.can_read?(Access.page_permission(user, page)),
          do: {:ok, page},
          else: {:error, "no page you can see matches that"}

      _ ->
        {:error, "no page you can see matches that"}
    end
  end

  defp item(%{"folder" => ref} = args, auth, user) when is_binary(ref) do
    by_id =
      case Integer.parse(ref) do
        {id, ""} -> Wiki.get_folder(id)
        _ -> nil
      end

    folder =
      by_id ||
        with board_ref when is_binary(board_ref) <- args["board"],
             {:ok, board} <- Authorize.fetch_board(auth, board_ref, :read),
             {:ok, folder} <- Wiki.find_folder(board, ref),
             do: folder,
             else: (_ -> nil)

    if folder && Access.can_read?(Access.folder_permission(user, folder)),
      do: {:ok, folder},
      else: {:error, "no folder you can see matches that"}
  end

  defp item(_args, _auth, _user), do: {:error, "say which: page (a code) or folder (with board)"}

  defp grant(g) do
    %{
      level: g.level,
      person: g.user && g.user.email,
      group: g.group && g.group.name
    }
  end
end
