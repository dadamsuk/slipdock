defmodule SlipdockWeb.MCP.Tools.ListTools do
  @moduledoc """
  The Tools the caller can see (#964) — their own, the ones shared with
  them, and the ones listed for everyone — with the board each install
  made, so a Tool's skill finds its board by its install rather than by
  searching for a page title. With `tool`, one Tool in full; with `file`
  too, one file of it as text (#1156), so a stub skill can read its
  procedure from the latest version at run time.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Tools
  alias SlipdockWeb.API.ToolJSON
  alias SlipdockWeb.MCP.Args

  # Text of one file, read into a tool result; a bigger one is for the API.
  @max_text 200_000

  @impl true
  def name, do: "list_tools"

  @impl true
  def title, do: "List Tools"

  @impl true
  def description,
    do:
      "Tools on this server you can install (yours, shared, listed), each with the board " <>
        "your install made. With tool: that Tool's board blueprint, skills and files. With " <>
        "tool and file (a path in the package, like skills/<skill>/SKILL.md or " <>
        "files/notes.md): that file's text, from the latest version unless version says."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        tool: %{type: "string", description: "One Tool's name, for all of it."},
        version: %{type: "string", description: "With tool: a version other than the latest."},
        file: %{
          type: "string",
          description: "With tool: one file's path in the package, for its text."
        }
      },
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, %{user: user}) do
    with {:ok, ref} <- Args.optional(args, "tool"),
         {:ok, number} <- Args.optional(args, "version"),
         {:ok, path} <- Args.optional(args, "file") do
      case ref do
        nil when is_binary(path) ->
          {:error, "file needs tool: the Tool whose file it is"}

        nil ->
          {:ok, %{tools: Enum.map(Tools.list_for(user), &ToolJSON.listing(&1, user))}}

        ref ->
          with {:ok, tool} <- Tools.fetch(user, ref),
               %{} = version <- Tools.visible_version(user, tool, number) do
            if path,
              do: file(tool, version, path),
              else: {:ok, %{tool: ToolJSON.show(tool, version, user)}}
          else
            _ -> {:error, "no Tool you can see is called #{inspect(ref)} at that version"}
          end
      end
    end
  end

  defp file(tool, version, path) do
    path = path |> String.trim() |> String.trim_leading("/")
    url = "/api/tools/#{tool.slug}/files/#{path}?version=#{version.version}"

    case Tools.file(version, path) do
      nil ->
        {:error,
         "#{tool.slug} #{version.version} has no file #{path} — list_tools with tool gives " <>
           "its skills and files"}

      %{content: bytes} = f ->
        cond do
          not String.valid?(bytes) ->
            {:error, "#{path} is not text: fetch it from #{url} with a token"}

          byte_size(bytes) > @max_text ->
            {:error, "#{path} is #{byte_size(bytes)} bytes, too big to read here: fetch #{url}"}

          true ->
            {:ok,
             %{
               tool: tool.slug,
               version: version.version,
               path: path,
               size: f.size,
               sha256: f.sha256,
               text: bytes
             }}
        end
    end
  end
end
