defmodule SlipdockWeb.MCP.Tools.ManageAutomation do
  @moduledoc """
  Adding, changing and deleting a board's automation rules, through the same
  `SlipdockWeb.API.AutomationWrites` the HTTP API uses. One tool with an
  `action`, as `manage_vault` is, because three tools would cost every
  session context. Rules act on everyone's cards, so only the board's owner
  may touch them.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Automations
  alias SlipdockWeb.API.{AutomationWrites, Authorize}
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @actions ~w(create update delete pause resume)

  @impl true
  def name, do: "manage_automation"

  @impl true
  def title, do: "Change a board's automations"

  @impl true
  def description,
    do:
      "Board owner only. create a rule on a board from spec (trigger, conditions, actions — " <>
        "list_automations with vocabulary: true has the grammar), preset with params, or text " <>
        "(a sentence the server's model turns into a spec; needs an AI key); name and scope " <>
        "optional. update a rule (rule: id or name) with any of name, scope, enabled, spec, or " <>
        "text to rewrite it. delete one (rule, confirm: true); update enabled: false turns " <>
        "it off instead. pause holds runner work with a reason (a pool, or the whole tree)."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        action: %{type: "string", enum: @actions},
        board: %{type: "string", description: "Board id, code or name."},
        rule: %{type: "string", description: "update/delete: the rule's id or name."},
        name: %{type: "string"},
        spec: %{
          type: "object",
          description: "{trigger: {type, ...}, conditions: [...], actions: [{type, ...}]}."
        },
        preset: %{type: "string", description: "create: a preset key, from list_automations."},
        params: %{type: "object", description: "create: the preset's fields."},
        text: %{type: "string", description: "The rule in a sentence, for the model."},
        scope: %{
          type: "string",
          enum: Automations.Rule.scopes(),
          description: "board: its own cards (default); tree: sub-boards' cards too."
        },
        enabled: %{type: "boolean"},
        confirm: %{type: "boolean", description: "Must be true to delete a rule."},
        pool: %{
          type: "string",
          description:
            "pause: hold one runner pool's jobs and list_top sends; without it, the whole tree."
        },
        reason: %{
          type: "string",
          description: "pause: why (required). Only a person can resume, in the app or the CLI."
        }
      },
      required: ["action", "board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def destructive?, do: true

  @impl true
  def call(args, %{user: user} = context) do
    with {:ok, action} <- Args.required(args, "action"),
         :ok <- known(action),
         {:ok, ref} <- Args.required(args, "board"),
         {:ok, board} <- owned_board(ref, context) do
      act(action, board, args, user, context)
    end
  end

  defp act("pause", board, args, user, context) do
    with {:ok, pool} <- Args.optional(args, "pool"),
         {:ok, reason} <- Args.required(args, "reason"),
         {:ok, pause} <-
           Args.refusal(
             Slipdock.Runners.pause(
               board,
               %{"pool" => pool, "reason" => reason},
               user,
               Slipdock.Actor.mcp(context)
             )
           ) do
      {:ok, %{pause: V.pause(pause)}}
    end
  end

  # Refused: an agent may pull the brake but not let it off (#1116).
  defp act("resume", board, args, user, context) do
    with {:ok, pool} <- Args.optional(args, "pool"),
         {:ok, pause} <-
           Args.refusal(Slipdock.Runners.resume(board, pool, user, Slipdock.Actor.mcp(context))) do
      {:ok, %{pause: V.pause(pause)}}
    end
  end

  defp act(action, board, args, user, _context), do: act(action, board, args, user)

  defp known(action) when action in @actions, do: :ok
  defp known(_), do: {:error, "action must be one of #{Enum.join(@actions, ", ")}"}

  defp act("create", board, args, user) do
    with {:ok, params} <- params(args),
         {:ok, rule} <- Args.refusal(AutomationWrites.build(board, params, user)) do
      {:ok, %{automation: V.automation(rule)}}
    end
  end

  defp act("update", board, args, user) do
    with {:ok, ref} <- Args.required(args, "rule"),
         {:ok, rule} <- rule(board, ref),
         {:ok, params} <- params(args),
         {:ok, rule} <- Args.refusal(AutomationWrites.change(rule, params, user)) do
      {:ok, %{automation: V.automation(rule)}}
    end
  end

  defp act("delete", board, args, _user) do
    with {:ok, ref} <- Args.required(args, "rule"),
         {:ok, rule} <- rule(board, ref),
         :ok <-
           Args.confirmed(args, "To stop it without losing it, update it with enabled: false"),
         {:ok, _} <- Args.refusal(Automations.delete_rule(rule)) do
      {:ok, %{deleted: true, automation: rule.id, name: rule.name}}
    end
  end

  # The arguments AutomationWrites reads, checked for type first so a wrong
  # one is named rather than silently ignored.
  defp params(args) do
    with {:ok, name} <- Args.optional(args, "name"),
         {:ok, text} <- Args.optional(args, "text"),
         {:ok, preset} <- Args.optional(args, "preset"),
         {:ok, scope} <- Args.optional(args, "scope"),
         {:ok, enabled} <- Args.boolean(args, "enabled"),
         {:ok, spec} <- object(args, "spec"),
         {:ok, preset_params} <- object(args, "params") do
      {:ok,
       %{
         "name" => name,
         "text" => text,
         "preset" => preset,
         "scope" => scope,
         "enabled" => enabled,
         "spec" => spec,
         "params" => preset_params
       }
       |> Map.reject(fn {_, v} -> is_nil(v) end)}
    end
  end

  defp object(args, key) do
    case args[key] do
      nil -> {:ok, nil}
      map when is_map(map) -> {:ok, map}
      _ -> {:error, "#{key} must be an object"}
    end
  end

  @doc false
  # The board `ref` names, if the token may run its automations: its owner's,
  # and a write token, as `GET /api/boards/:board/automations` needs too.
  # Shared with `list_automations`.
  def owned_board(ref, context) do
    case Authorize.fetch_board(Args.auth(context), ref, :owner) do
      {:ok, board} ->
        {:ok, board}

      {:error, :forbidden, "you don't own" <> _ = message} ->
        {:error, message <> ": only a board's owner may see or change its automations"}

      other ->
        Args.refusal(other)
    end
  end

  @doc false
  # A rule on `board` by id or name, or an error naming the rules it has.
  def rule(board, ref) do
    case Automations.find_rule(board, ref) do
      {:ok, rule} ->
        {:ok, rule}

      {:error, :not_found} ->
        names =
          case Automations.list_rules(board.id) do
            [] -> "it has none"
            rules -> "its rules are: " <> Enum.map_join(rules, ", ", &"#{&1.id} “#{&1.name}”")
          end

        {:error, "#{board.name} has no automation “#{ref}”; #{names}"}
    end
  end
end
