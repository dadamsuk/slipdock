defmodule SlipdockWeb.MCP.Tools.CreateTag do
  @moduledoc """
  A new tag on a board, for cards to wear. Tags live on the root of the
  board tree, so one made on a sub-board is shared by the whole tree.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "create_tag"

  @impl true
  def title, do: "Add a tag"

  @impl true
  def description,
    do:
      "Adds a tag to a board (shared by its sub-boards), so create_card and update_card " <>
        "can put it on cards. A tag of that name already there is returned, not doubled."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        name: %{type: "string", description: "At most 30 characters."},
        color: %{type: "string", enum: Slipdock.Palette.names()}
      },
      required: ["board", "name"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, name} <- Args.required(args, "name"),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :write)) do
      # Tags are found by name, so a second of the same name would never be
      # reached; asking again for one that exists is answered with it.
      # (By name only: `Boards.find_tag/2` would take "2026" for an id.)
      wanted = name |> String.trim() |> String.downcase()
      existing = board |> Slipdock.Boards.Board.root_id() |> Boards.list_tags()

      case Enum.find(existing, &(String.downcase(&1.name) == wanted)) do
        %{} = tag ->
          {:ok, %{tag: SlipdockWeb.API.JSON.tag(tag), created: false}}

        nil ->
          attrs = args |> Map.take(["color"]) |> Map.put("name", name)

          with {:ok, tag} <- Args.refusal(Boards.create_tag(board, attrs)) do
            {:ok, %{tag: SlipdockWeb.API.JSON.tag(tag), created: true}}
          end
      end
    end
  end
end
