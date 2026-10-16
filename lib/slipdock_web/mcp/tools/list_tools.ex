defmodule SlipdockWeb.MCP.Tools.ListTools do
  @moduledoc """
  The Tools the caller can see (#964) — their own, the ones shared with
  them, and the ones listed for everyone — with the board each install
  made, so a Tool's skill finds its board by its install rather than by
  searching for a page title. With `tool`, one Tool in full.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Tools
  alias SlipdockWeb.API.ToolJSON
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "list_tools"

  @impl true
  def title, do: "List Tools"

  @impl true
  def description,
    do:
      "Tools on this server you can install (yours, shared, listed), each with the board " <>
        "your install made. With tool: that Tool's board blueprint, skills and files."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        tool: %{type: "string", description: "One Tool's name, for all of it."},
        version: %{type: "string", description: "With tool: a version other than the latest."}
      },
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, %{user: user}) do
    with {:ok, ref} <- Args.optional(args, "tool"),
         {:ok, number} <- Args.optional(args, "version") do
      case ref do
        nil ->
          {:ok, %{tools: Enum.map(Tools.list_for(user), &ToolJSON.listing(&1, user))}}

        ref ->
          with {:ok, tool} <- Tools.fetch(user, ref),
               %{} = version <- Tools.visible_version(user, tool, number) do
            {:ok, %{tool: ToolJSON.show(tool, version, user)}}
          else
            _ -> {:error, "no Tool you can see is called #{inspect(ref)} at that version"}
          end
      end
    end
  end
end
