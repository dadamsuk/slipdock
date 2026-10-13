defmodule SlipdockWeb.MCP.Tools.ManageVault do
  @moduledoc """
  Making, renaming and deleting a vault, and mapping vault paths onto board
  wikis (see `Slipdock.Vaults`). One tool with an `action`, because each of
  these is a line of work and six tools would cost every session context.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Vaults, Wiki}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @actions ~w(create rename delete map unmap move_folder split)

  @impl true
  def name, do: "manage_vault"

  @impl true
  def title, do: "Change a vault"

  @impl true
  def description,
    do:
      "create a vault (name), rename it (vault, name), delete it (vault, confirm: true; " <>
        "pages are kept), map a vault path to a board's wiki or one of its folders " <>
        "(vault, path, board, folder) or unmap one (vault, path). A board belongs to one vault. " <>
        "dry_run: true with map or unmap says which pages it brings in, takes over or takes " <>
        "out, and changes nothing. move_folder moves a folder (board, folder) with its subfolders, " <>
        "pages and files to another board you can write to (to_board, optional parent folder " <>
        "there; contents: true moves only what is in it): pages keep codes and history; " <>
        "dry_run reports what moves and what can't be carried. split gives the folder at a vault " <>
        "path its own board in one step (vault, path, board — or new_board to make one): its " <>
        "contents move there and the path is mapped onto it, notes keeping their vault paths; " <>
        "dry_run first."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        action: %{type: "string", enum: @actions},
        vault: %{type: "string", description: "Vault id or name."},
        name: %{type: "string", description: "The vault's (new) name."},
        path: %{type: "string", description: "Vault path, e.g. / or /Jobs."},
        board: %{
          type: "string",
          description: "Board id, code or name (map; move_folder: the folder's board)."
        },
        folder: %{
          type: "string",
          description:
            "A folder on that board (map: default its root; move_folder: the one to move)."
        },
        to_board: %{type: "string", description: "move_folder: the board it goes to."},
        new_board: %{type: "string", description: "split: make a board of this name for it."},
        parent: %{
          type: "string",
          description: "move_folder: a folder on to_board to put it in; default its top."
        },
        contents: %{
          type: "boolean",
          description: "move_folder: move what is in the folder, not the folder itself."
        },
        confirm: %{type: "boolean", description: "Must be true to delete a vault."},
        dry_run: %{
          type: "boolean",
          description: "map/unmap: say which pages would move, change nothing."
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

  defp act("create", args, user, _context) do
    with {:ok, name} <- Args.required(args, "name"),
         {:ok, vault} <- Args.refusal(Vaults.create_vault(user, %{"name" => name})),
         do: {:ok, %{vault: V.vault(vault)}}
  end

  defp act("rename", args, user, _context) do
    with {:ok, vault} <- vault(args, user),
         {:ok, name} <- Args.required(args, "name"),
         {:ok, vault} <- Args.refusal(Vaults.update_vault(vault, %{"name" => name})),
         do: {:ok, %{vault: V.vault(vault)}}
  end

  defp act("delete", args, user, _context) do
    with {:ok, vault} <- vault(args, user),
         {:ok, confirmed} <- Args.boolean(args, "confirm", false) do
      if confirmed do
        # Rendered first, so the reply still counts what it held.
        deleted = V.vault(vault)

        with {:ok, _} <- Args.refusal(Vaults.delete_vault(vault)),
             do: {:ok, %{deleted: deleted}}
      else
        {:error, "deleting a vault removes its mappings (not its pages); send confirm: true"}
      end
    end
  end

  defp act("map", args, user, context) do
    with {:ok, vault} <- vault(args, user),
         {:ok, path} <- Args.optional(args, "path"),
         {:ok, board_ref} <- Args.required(args, "board"),
         {:ok, folder_ref} <- Args.optional(args, "folder"),
         {:ok, board} <-
           Args.refusal(Authorize.fetch_board(Args.auth(context), board_ref, :write)),
         {:ok, folder} <- folder(board, folder_ref),
         {:ok, dry_run} <- Args.boolean(args, "dry_run", false) do
      attrs = %{path: path, board: board, folder: folder}

      if dry_run do
        with {:ok, preview} <- Args.refusal(Vaults.preview_mapping(vault, user, attrs)),
             do: {:ok, %{dry_run: true, preview: preview}}
      else
        with {:ok, _} <- Args.refusal(Vaults.add_mapping(vault, user, attrs)),
             {:ok, vault} <- Args.refusal(Vaults.get_vault(user, vault.id)),
             do: {:ok, %{vault: V.vault(vault)}}
      end
    end
  end

  defp act("unmap", args, user, _context) do
    with {:ok, vault} <- vault(args, user),
         {:ok, path} <- Args.required(args, "path"),
         {:ok, dry_run} <- Args.boolean(args, "dry_run", false) do
      if dry_run do
        with {:ok, preview} <- Args.refusal(Vaults.preview_unmapping(vault, path)),
             do: {:ok, %{dry_run: true, preview: preview}}
      else
        with {:ok, _} <- Args.refusal(Vaults.remove_mapping(vault, path)),
             {:ok, vault} <- Args.refusal(Vaults.get_vault(user, vault.id)),
             do: {:ok, %{vault: V.vault(vault)}}
      end
    end
  end

  # Not a vault's own change, but the one that makes a vault's layout
  # possible: a folder of one board becoming another's (#745).
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

  # A vault folder becomes its own board's, and its path that board (#747).
  defp act("split", args, user, context) do
    with {:ok, vault} <- vault(args, user),
         {:ok, path} <- Args.required(args, "path"),
         {:ok, new_board} <- Args.optional(args, "new_board"),
         {:ok, board_ref} <- Args.optional(args, "board"),
         {:ok, dry_run} <- Args.boolean(args, "dry_run", false),
         {:ok, target} <- split_target(new_board, board_ref, context) do
      if dry_run do
        with {:ok, preview} <- Args.refusal(Vaults.Split.preview(vault, user, path, target)),
             do: {:ok, %{dry_run: true, preview: preview}}
      else
        with {:ok, result} <- Args.refusal(Vaults.Split.run(vault, user, path, target)),
             {:ok, vault} <- Args.refusal(Vaults.get_vault(user, vault.id)) do
          {board, result} = Map.pop(result, :board)

          {:ok,
           %{
             result: result,
             board: %{id: board.id, code: board.code, name: board.name},
             vault: V.vault(vault)
           }}
        end
      end
    end
  end

  defp split_target(name, _ref, _context) when is_binary(name), do: {:ok, {:new, name}}

  defp split_target(nil, ref, context) when is_binary(ref),
    do: Args.refusal(Authorize.fetch_board(Args.auth(context), ref, :write))

  defp split_target(_name, _ref, _context),
    do: {:error, "say which board: board, or new_board to make one"}

  defp vault(args, user) do
    with {:ok, ref} <- Args.required(args, "vault"),
         do: Args.refusal(Vaults.get_vault(user, ref))
  end

  defp folder(_board, nil), do: {:ok, nil}
  defp folder(board, ref), do: Args.refusal(Wiki.find_folder(board, ref))
end
