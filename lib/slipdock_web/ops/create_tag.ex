defmodule SlipdockWeb.Ops.CreateTag do
  @moduledoc """
  A new tag on a board, for cards to wear, defined once (#3187). Tags live
  on the root of the board tree, so one made on a sub-board is shared by the
  whole tree, and making one asks write on the root (#2990).

  Before it, MCP answered a tag already there by that name (in any case)
  with it, `created: false`, while REST made a second whose name differed
  only in case, or refused one the same (422). Tags are found by name, so a
  second would never be reached: now both answer the one there, and REST
  says 200 for it where a new one is 201. Both answer `{tag, created}`.
  """
  @behaviour SlipdockWeb.Ops.Op

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  @impl true
  def definition do
    %{
      name: "create_tag",
      title: "Add a tag",
      summary:
        "Adds a tag to a board (shared by its sub-boards), so create_card and update_card " <>
          "can put it on cards. A tag of that name already there is returned, not doubled. " <>
          "Making a new one needs edit access to the tree's root board.",
      verb: :post,
      path: "/api/boards/:board/tags",
      permission: {:board, :write},
      writes?: true,
      status: &if(&1.created, do: :created, else: :ok),
      params: [
        %{
          name: "board",
          type: :string,
          required: true,
          in_path: "board",
          doc: "Board id, code or name."
        },
        %{name: "name", type: :string, required: true, doc: "At most 30 characters."},
        %{name: "color", type: {:enum, Slipdock.Palette.names()}}
      ],
      cli: %{
        command: "new-tag",
        positional: ["board", "name..."],
        flags: %{"color" => %{param: "color"}}
      }
    }
  end

  @impl true
  def run(%{"board" => ref, "name" => name} = params, auth) do
    with {:ok, board} <- Authorize.fetch_board(auth, ref, :write) do
      # By name only: `Boards.find_tag/2` would take "2026" for an id.
      wanted = String.downcase(name)
      existing = board |> Boards.Board.root_id() |> Boards.Tags.list_tags()

      case Enum.find(existing, &(String.downcase(&1.name) == wanted)) do
        %{} = tag -> {:ok, %{tag: V.tag(tag), created: false}}
        nil -> create(board, Map.take(params, ["name", "color"]), auth)
      end
    end
  end

  # A new one changes the tree's list, which is the root's: that asks write
  # on the root as well (#2990).
  defp create(board, attrs, auth) do
    with :ok <- Authorize.tags(auth, board),
         {:ok, tag} <- Boards.Tags.create_tag(board, attrs) do
      {:ok, %{tag: V.tag(tag), created: true}}
    end
  end
end
