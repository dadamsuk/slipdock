defmodule SlipdockWeb.MCP.Tools.SkillRegistry do
  @moduledoc """
  The skills registry over MCP (#2072, spec W-2513): what the Skills page
  (`/skills`) and `/api/skill-*` do, with the same permissions. One tool
  with an `action`, because each tool costs every session context.

  - `sources`, `source`, `add`, `refresh`, `remove`: the caller's skill
    sources and the seeds (an admin adds one with `seed`). Adding or refreshing fetches from the web, so
    those two are the only actions that leave the server.
  - `entry`: one skill in full, its `content_hash`, where it is enabled and
    which Playbook stages name it. Read it before enabling it.
  - `enable`, `repin`, `disable`: a board writer pins an entry to a board
    with the `hash` they read, re-pins it after reading its diff, or takes
    it off. The board's agents get the pinned text.
  - `stages`: every Playbook stage the caller reads that names a skill,
    with what it gets.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.SkillRegistry
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.SkillRegistryJSON, as: JSON
  alias SlipdockWeb.MCP.Args

  @reads ~w(sources source entry stages)
  @writes ~w(add refresh remove enable repin disable)
  @actions @reads ++ @writes

  @impl true
  def name, do: "skill_registry"

  @impl true
  def title, do: "Skills registry"

  @impl true
  def description,
    do:
      "Skills fetched from outside Slipdock. sources/source/add/refresh/remove a source; " <>
        "entry: one skill in full, with its content_hash; enable/repin/disable it on a " <>
        "board (writer, pinned to that hash); stages: Playbook stages naming a skill."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        action: %{type: "string", enum: @actions},
        url: %{
          type: "string",
          description:
            "add: a GitHub repository, a folder or file in one, or a SKILL.md at an https URL."
        },
        seed: %{
          type: "boolean",
          description: "add: for everyone on the server (a seed); admins only."
        },
        source: %{type: "integer", description: "source, refresh, remove: the source's id."},
        entry: %{
          type: "integer",
          description: "entry, enable: the skill's id (from a source's entries)."
        },
        board: %{type: "string", description: "enable, repin, disable: board id, code or name."},
        name: %{type: "string", description: "repin, disable: the skill's name on the board."},
        hash: %{
          type: "string",
          description:
            "enable, repin: the content_hash of the text you read (from entry); any other is refused."
        }
      },
      required: ["action"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def writes?(args), do: Enum.member?(@writes, args["action"])

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

  defp act("sources", _args, user, _context),
    do: {:ok, %{sources: Enum.map(SkillRegistry.list_sources(user), &JSON.source(&1, user))}}

  defp act("source", args, user, _context) do
    with {:ok, source} <- source(args, user), do: {:ok, %{source: JSON.source(source, user)}}
  end

  defp act("add", args, user, _context) do
    with {:ok, url} <- Args.required(args, "url"),
         {:ok, seed} <- Args.boolean(args, "seed", false),
         {:ok, source} <- Args.refusal(SkillRegistry.add_source(user, url, seed: seed)),
         do: {:ok, %{source: JSON.source(source, user)}}
  end

  defp act("refresh", args, user, _context) do
    with {:ok, source} <- source(args, user),
         {:ok, source, changes} <- Args.refusal(SkillRegistry.refresh_source(user, source)),
         do: {:ok, %{source: JSON.source(source, user), changes: changes}}
  end

  defp act("remove", args, user, _context) do
    with {:ok, source} <- source(args, user),
         {:ok, removed} <- Args.refusal(SkillRegistry.remove_source(user, source)),
         do: {:ok, %{deleted: %{id: removed.id, name: removed.name, url: removed.url}}}
  end

  defp act("entry", args, user, _context) do
    with {:ok, id} <- id(args, "entry") do
      case SkillRegistry.get_entry(user, id) do
        nil -> {:error, "no skill you can see has id #{id}"}
        entry -> {:ok, %{entry: JSON.entry(entry, user)}}
      end
    end
  end

  defp act("stages", _args, user, _context),
    do: {:ok, %{boards: JSON.stages(SkillRegistry.naming(user))}}

  defp act("enable", args, user, context) do
    with {:ok, board} <- board(args, context),
         {:ok, id} <- id(args, "entry"),
         {:ok, hash} <- Args.required(args, "hash"),
         {:ok, e} <- Args.refusal(SkillRegistry.enable(user, board, id, hash)),
         do: {:ok, %{skill: JSON.enablement(e, text: true)}}
  end

  defp act("repin", args, user, context) do
    with {:ok, board} <- board(args, context),
         {:ok, e} <- enabled(board, args),
         {:ok, hash} <- Args.required(args, "hash"),
         {:ok, e} <- Args.refusal(SkillRegistry.repin(user, e, hash)),
         do: {:ok, %{skill: JSON.enablement(e, text: true)}}
  end

  defp act("disable", args, user, context) do
    with {:ok, board} <- board(args, context),
         {:ok, e} <- enabled(board, args),
         {:ok, _} <- Args.refusal(SkillRegistry.disable(user, e)),
         do: {:ok, %{disabled: %{name: e.name, board: board.code || board.id}}}
  end

  defp source(args, user) do
    with {:ok, id} <- id(args, "source") do
      case SkillRegistry.get_source(user, id) do
        nil -> {:error, "no skill source you can see has id #{id}"}
        source -> {:ok, source}
      end
    end
  end

  defp board(args, context) do
    with {:ok, ref} <- Args.required(args, "board"),
         do: Args.refusal(Authorize.fetch_board(Args.auth(context), ref, :write))
  end

  defp enabled(board, args) do
    with {:ok, name} <- Args.required(args, "name") do
      case SkillRegistry.get_enabled(board, name) do
        nil -> {:error, "no skill named #{name} is enabled on #{board.name}"}
        e -> {:ok, e}
      end
    end
  end

  defp id(args, key) do
    case args[key] do
      n when is_integer(n) ->
        {:ok, n}

      s when is_binary(s) ->
        case Integer.parse(String.trim(s)) do
          {n, ""} -> {:ok, n}
          _ -> {:error, "#{key} must be an id"}
        end

      nil ->
        {:error, "#{key} is required"}

      _ ->
        {:error, "#{key} must be an id"}
    end
  end
end
