defmodule SlipdockWeb.MCP.Tools.CreateBoard do
  @moduledoc """
  A new board of the caller's own. A token confined to some boards may not
  make one: it could not reach the board it made.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.MCP.{Args, Tools}

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
      properties: %{
        name: %{type: "string"},
        code: %{type: "string", description: "Short slug; made from the name if left out."},
        description: %{type: "string"},
        template: %{type: "string", description: "Template name or id for its lists."},
        lists: %{
          type: "array",
          items: %{type: "string"},
          description:
            "The board's own list names, in order, instead of a template's. Names like " <>
              "To Do, In Progress and Done are given those roles."
        },
        save_template: %{
          type: "string",
          description: "Also keep the board's lists as a template with this name."
        }
      },
      required: ["name"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, %{user: user, token: token} = context) do
    with {:ok, name} <- Args.required(args, "name"),
         {:ok, template_ref} <- Args.optional(args, "template"),
         {:ok, lists} <- Args.strings(args, "lists"),
         {:ok, save_as} <- Args.optional(args, "save_template"),
         :ok <- unscoped(token),
         {:ok, template} <- template(template_ref),
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

  defp unscoped(token) do
    case Map.get(token, :scope_boards) || [] do
      [] ->
        :ok

      _ ->
        {:error,
         "this API token's scope doesn't allow it to create boards: it is confined to " <>
           "some boards (see Account → API tokens). Don't retry."}
    end
  end

  defp template(nil), do: {:ok, nil}

  defp template(ref) do
    case Boards.find_template(ref) do
      {:ok, t} ->
        {:ok, t}

      _ ->
        names = Enum.map_join(Boards.list_templates(), ", ", & &1.name)
        {:error, "no template called #{inspect(ref)}; there are: #{names}"}
    end
  end
end
