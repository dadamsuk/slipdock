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

  @actions ~w(create rename delete map unmap)

  @impl true
  def name, do: "manage_vault"

  @impl true
  def title, do: "Change a vault"

  @impl true
  def description,
    do:
      "create a vault (name), rename it (vault, name), delete it (vault, confirm: true; " <>
        "pages are kept), map a vault path to a board's wiki or one of its folders " <>
        "(vault, path, board, folder) or unmap one (vault, path). A board belongs to one vault."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        action: %{type: "string", enum: @actions},
        vault: %{type: "string", description: "Vault id or name."},
        name: %{type: "string", description: "The vault's (new) name."},
        path: %{type: "string", description: "Vault path, e.g. / or /Jobs."},
        board: %{type: "string", description: "Board id, code or name (map)."},
        folder: %{type: "string", description: "A folder on that board (map); default its root."},
        confirm: %{type: "boolean", description: "Must be true to delete a vault."}
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
        with {:ok, _} <- Args.refusal(Vaults.delete_vault(vault)),
             do: {:ok, %{deleted: V.vault(vault)}}
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
         {:ok, _} <-
           Args.refusal(
             Vaults.add_mapping(vault, user, %{path: path, board: board, folder: folder})
           ),
         {:ok, vault} <- Args.refusal(Vaults.get_vault(user, vault.id)),
         do: {:ok, %{vault: V.vault(vault)}}
  end

  defp act("unmap", args, user, _context) do
    with {:ok, vault} <- vault(args, user),
         {:ok, path} <- Args.required(args, "path"),
         {:ok, _} <- Args.refusal(Vaults.remove_mapping(vault, path)),
         {:ok, vault} <- Args.refusal(Vaults.get_vault(user, vault.id)),
         do: {:ok, %{vault: V.vault(vault)}}
  end

  defp vault(args, user) do
    with {:ok, ref} <- Args.required(args, "vault"),
         do: Args.refusal(Vaults.get_vault(user, ref))
  end

  defp folder(_board, nil), do: {:ok, nil}
  defp folder(board, ref), do: Args.refusal(Wiki.find_folder(board, ref))
end
