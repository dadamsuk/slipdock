defmodule SlipdockWeb.MCP.Tools.ManageVault do
  @moduledoc """
  Changing the vault's settings (see `Slipdock.Vaults`), and moving a folder
  between boards. One tool with an `action`, because each tool costs every
  session context.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Vaults, Wiki}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @actions ~w(rename move_folder)

  @impl true
  def name, do: "manage_vault"

  @impl true
  def title, do: "Change a vault"

  @impl true
  def description,
    do:
      "rename the vault (vault, name), or move_folder: a folder (board, folder) with what is " <>
        "in it to another board (to_board, optional parent; contents: true moves only what is " <>
        "in it). Pages keep codes and history; dry_run reports it."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        action: %{type: "string", enum: @actions},
        vault: %{type: "string", description: "Vault id or name."},
        name: %{type: "string", description: "The vault's (new) name."},
        board: %{
          type: "string",
          description: "Board id, code or name: the folder's board."
        },
        folder: %{
          type: "string",
          description: "The folder on that board to move."
        },
        to_board: %{type: "string", description: "move_folder: the board it goes to."},
        parent: %{
          type: "string",
          description: "move_folder: a folder on to_board to put it in; default its top."
        },
        contents: %{
          type: "boolean",
          description: "move_folder: move what is in the folder, not the folder itself."
        },
        dry_run: %{
          type: "boolean",
          description: "move_folder: report what would move, change nothing."
        }
      },
      required: ["action"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def destructive?, do: true

  @impl true
  def call(args, %{user: user} = context) do
    with {:ok, action} <- Args.required(args, "action") do
      if action in @actions,
        do: act(action, args, user, context),
        else: {:error, "action must be one of #{Enum.join(@actions, ", ")}"}
    end
  end

  defp act("rename", args, user, _context) do
    with {:ok, vault} <- vault(args, user),
         {:ok, name} <- Args.required(args, "name"),
         {:ok, vault} <- Args.refusal(Vaults.update_vault(vault, %{"name" => name})),
         do: {:ok, %{vault: V.vault(vault, user)}}
  end

  # Not a vault's own change: a folder of one board becoming another's (#745).
  defp act("move_folder", args, user, context) do
    auth = Args.auth(context)

    with {:ok, board_ref} <- Args.required(args, "board"),
         {:ok, folder_ref} <- Args.required(args, "folder"),
         {:ok, to_ref} <- Args.required(args, "to_board"),
         {:ok, parent_ref} <- Args.optional(args, "parent"),
         {:ok, contents} <- Args.boolean(args, "contents", false),
         {:ok, dry_run} <- Args.boolean(args, "dry_run", false),
         {:ok, source} <- Args.refusal(Authorize.fetch_board(auth, board_ref, :write)),
         {:ok, folder} <- Args.refusal(Wiki.find_folder(source, folder_ref)),
         {:ok, target} <- Args.refusal(Authorize.fetch_board(auth, to_ref, :write)),
         {:ok, parent} <- folder(target, parent_ref) do
      opts = [parent: parent, contents: contents]

      if dry_run do
        with {:ok, report} <-
               Args.refusal(Wiki.FolderMove.preview(folder, target, user, opts)),
             do: {:ok, %{dry_run: true, board: target.code, report: report}}
      else
        with {:ok, %{folder: moved, report: report}} <-
               Args.refusal(Wiki.FolderMove.to_board(folder, target, user, opts)),
             do: {:ok, %{folder: moved && V.folder(moved), board: target.code, report: report}}
      end
    end
  end

  defp vault(args, user) do
    with {:ok, ref} <- Args.required(args, "vault"),
         do: Args.refusal(Vaults.get_vault(user, ref))
  end

  defp folder(_board, nil), do: {:ok, nil}
  defp folder(board, ref), do: Args.refusal(Wiki.find_folder(board, ref))
end
