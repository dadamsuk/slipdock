defmodule SlipdockWeb.MCP.Tools.ListAutomations do
  @moduledoc """
  A board's automation rules, or one of them, as `GET
  /api/boards/:board/automations` gives them; with `vocabulary: true`, the
  spec grammar and the ready-made presets too, so a client can write a rule
  for `manage_automation` without guessing.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Automations
  alias Slipdock.Automations.{Presets, Spec}
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Tools.ManageAutomation

  @impl true
  def name, do: "list_automations"

  @impl true
  def title, do: "List a board's automations"

  @impl true
  def description,
    do:
      "A board's automation rules (its owner only): each one's trigger, spec, whether it is " <>
        "on, and how often it has run. rule gives one by id or name. vocabulary: true adds " <>
        "every trigger, condition and action a spec may use, and the ready-made presets."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        rule: %{type: "string", description: "One rule, by id or name."},
        vocabulary: %{
          type: "boolean",
          description: "Also give the spec grammar and the presets (default false)."
        }
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, rule_ref} <- Args.optional(args, "rule"),
         {:ok, vocabulary} <- Args.boolean(args, "vocabulary", false),
         {:ok, board} <- ManageAutomation.owned_board(ref, context),
         {:ok, data} <- rules(board, rule_ref) do
      {:ok,
       data
       |> Map.put(:board_id, board.id)
       |> then(
         &if(vocabulary,
           do: Map.merge(&1, %{vocabulary: Spec.vocabulary(), presets: Presets.all()}),
           else: &1
         )
       )}
    end
  end

  defp rules(board, nil),
    do: {:ok, %{automations: Enum.map(Automations.list_rules(board.id), &V.automation/1)}}

  defp rules(board, ref) do
    with {:ok, rule} <- ManageAutomation.rule(board, ref),
         do: {:ok, %{automation: V.automation(rule)}}
  end
end
