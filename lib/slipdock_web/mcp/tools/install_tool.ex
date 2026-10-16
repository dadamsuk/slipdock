defmodule SlipdockWeb.MCP.Tools.InstallTool do
  @moduledoc """
  Installs a Tool's board for the caller (#961): the server builds the lists,
  folders, tags, page skeletons and rules from the Tool's blueprint, so a
  setup skill calls this first and then fills the pages in. Installing again
  returns the board already made.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Tools
  alias SlipdockWeb.API.ToolJSON
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "install_tool"

  @impl true
  def title, do: "Install a Tool's board"

  @impl true
  def description,
    do:
      "Builds the board a Tool (see list_tools) comes with — lists, folders, tags, page " <>
        "skeletons, rules — and returns its code. Already installed: returns that board, " <>
        "adding what a newer version brings without touching edited pages."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        tool: %{type: "string", description: "The Tool's name, as list_tools gives it."},
        version: %{type: "string", description: "A version other than the latest."},
        board_name: %{
          type: "string",
          description: "The new board's name; the Tool's title otherwise."
        }
      },
      required: ["tool"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, %{user: user, token: token} = context) do
    with {:ok, ref} <- Args.required(args, "tool"),
         {:ok, version} <- Args.optional(args, "version"),
         {:ok, board_name} <- Args.optional(args, "board_name"),
         :ok <- unscoped(token),
         {:ok, tool} <- found(Tools.fetch(user, ref), ref),
         {:ok, result} <-
           installed(Tools.install_board(user, tool, version: version, name: board_name), ref) do
      {:ok, ToolJSON.install(result, context.base_url)}
    end
  end

  defp found({:ok, tool}, _ref), do: {:ok, tool}

  defp found(_, ref),
    do: {:error, "no Tool you can see is called #{inspect(ref)} — see list_tools"}

  defp installed({:ok, result}, _ref), do: {:ok, result}

  defp installed({:error, :not_found}, ref),
    do: {:error, "#{ref} has no such version you can see"}

  defp installed(other, _ref), do: Args.refusal(other)

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
end
