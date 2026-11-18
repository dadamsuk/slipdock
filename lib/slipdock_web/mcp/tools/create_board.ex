defmodule SlipdockWeb.MCP.Tools.CreateBoard do
  @moduledoc """
  A new board of the caller's own. A token confined to some boards may not
  make one: it could not reach the board it made.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.{Args, Tools}
  alias SlipdockWeb.Ops

  # The params it shares with `POST /api/boards` (`Ops.NewBoard`): all it
  # takes. REST's also take shortcut, color, kind, simple, and columns (the
  # old name for lists).
  @shared ~w(name code description template lists save_template)

  @doc false
  def shared, do: @shared

  @impl true
  def name, do: "create_board"

  @impl true
  def title, do: "Create a board"

  @impl true
  def description,
    do:
      "Creates a board of your own, with the lists of a template (default " <>
        "Backlog, To Do, In Progress, Done) or lists of its own, which save_template " <>
        "can keep as a new template. list_boards first: don't make one twice."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{},
      required: ["name"],
      additionalProperties: false
    }
    # Every param it takes is POST /api/boards's, from its definition (#3361).
    |> Map.update!(:properties, &Map.merge(&1, Ops.params_from(Ops.NewBoard, @shared)))
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, %{user: user} = context) do
    auth = Args.auth(context)

    with {:ok, name} <- Args.required(args, "name"),
         {:ok, template_ref} <- Args.optional(args, "template"),
         {:ok, lists} <- Args.strings(args, "lists"),
         {:ok, save_as} <- Args.optional(args, "save_template"),
         :ok <- Args.refusal(Authorize.unconfined(auth, "create boards")),
         {:ok, template} <- template(user, template_ref),
         attrs = args |> Map.take(~w(code description)) |> Map.put("name", name),
         {:ok, board} <-
           Args.refusal(
             Boards.create_board(attrs,
               template: template,
               owner_id: user.id,
               columns: lists,
               save_template: save_as
             )
           ) do
      {:ok,
       Map.put(
         Tools.ListBoards.summary(board, user),
         :url,
         context.base_url <> "/boards/#{board.id}"
       )}
    end
  end

  defp template(_user, nil), do: {:ok, nil}

  defp template(user, ref) do
    case Boards.Templates.find_template(user, ref) do
      {:ok, t} ->
        {:ok, t}

      _ ->
        names = Enum.map_join(Boards.Templates.list_templates(user), ", ", & &1.name)
        {:error, "no template called #{inspect(ref)}; there are: #{names}"}
    end
  end
end
