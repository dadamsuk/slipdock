defmodule SlipdockWeb.MCP.Tools.ManageWiki do
  @moduledoc """
  Changing the caller's wiki (W-2201): its settings, and moving a folder
  between its boards. One tool with an `action`, because each tool costs
  every session context. A wiki has no name, so there is no renaming it.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Vaults, Wiki}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @actions ~w(set move_folder)

  @impl true
  def name, do: "manage_wiki"

  @impl true
  def title, do: "Change your wiki"

  @impl true
  def description,
    do:
      "set your wiki's shortcut or recordings_folder, or move_folder: a folder (board, " <>
        "folder) and what is in it to another board (to_board, parent; contents: only what is " <>
        "in it). Codes and history kept; dry_run reports."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        action: %{type: "string", enum: @actions},
        shortcut: %{type: "string", description: "set: the key after b that opens your wiki."},
        recordings_folder: %{
          type: "string",
          description: "set: a My Drive folder its meeting recordings play from; \"\" for none."
        },
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
      if Enum.member?(@actions, action),
        do: act(action, args, user, context),
        else: {:error, "action must be one of #{Enum.join(@actions, ", ")}"}
    end
  end

  defp act("set", args, user, _context) do
    wiki = Vaults.root(user)

    with {:ok, shortcut} <- Args.optional(args, "shortcut"),
         {:ok, folder} <- Args.optional(args, "recordings_folder"),
         {:ok, wiki} <- if(shortcut, do: set_shortcut(wiki, shortcut), else: {:ok, wiki}),
         {:ok, wiki} <- if(folder, do: set_recordings(wiki, folder), else: {:ok, wiki}),
         do: {:ok, %{wiki: V.wiki(wiki, user)}}
  end

  # A folder of one board becoming another's (#745).
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

  defp set_shortcut(wiki, shortcut) do
    case Vaults.set_shortcut(wiki, shortcut) do
      {:ok, wiki} -> {:ok, wiki}
      {:error, %Ecto.Changeset{} = cs} -> {:error, "shortcut #{changeset_error(cs, :shortcut)}"}
    end
  end

  defp set_recordings(wiki, folder) do
    case Vaults.set_recordings_folder(wiki, folder) do
      {:ok, wiki} -> {:ok, wiki}
      {:error, reason} -> {:error, "recordings_folder: #{reason}"}
    end
  end

  defp changeset_error(cs, field),
    do: cs.errors[field] |> Kernel.||({"is invalid", []}) |> elem(0)

  defp folder(_board, nil), do: {:ok, nil}
  defp folder(board, ref), do: Args.refusal(Wiki.find_folder(board, ref))
end
