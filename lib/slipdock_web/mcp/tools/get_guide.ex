defmodule SlipdockWeb.MCP.Tools.GetGuide do
  @moduledoc """
  The agent guide, cut from the same text `GET /api/guide` serves, never a copy.
  The whole of it is more than a client will show in one tool result, so by
  default this gives the short guide and names the other sections, and
  `section` asks for one of them (or `"all"`).

  `board` adds the `skills` part of that board's guide (#2063): the skills
  enabled there from the registry, each with its pinned text, which the plan
  skill uses for a Playbook stage that names one. A board the caller can't
  read is refused, never listed.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias SlipdockWeb.API.{Authorize, SkillRegistryJSON}
  alias SlipdockWeb.APIGuide
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "get_guide"

  @impl true
  def title, do: "Read the guide"

  @impl true
  def description,
    do:
      "How to work this server's boards: epics and subcards, picking the next card, what to " <>
        "write back. Read it once at the start of a session. Gives the short guide, naming " <>
        "the other sections; board adds that board's enabled skills."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        section: %{
          type: "string",
          description:
            "One section by name, e.g. automations, runners, wiki, recipes, endpoints; " <>
              "\"all\" for the whole guide. Left out, the short guide."
        },
        board: %{
          type: "string",
          description:
            "A board id, code or name: adds `skills`, the skills enabled there with " <>
              "their pinned text (what the plan skill uses for a stage naming one)."
        }
      },
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, %{user: user, token: token, base_url: base_url} = context) do
    opts = [base_url: base_url, user: user, token: token]

    with {:ok, key} <- Args.optional(args, "section"),
         {:ok, skills} <- skills(args, context),
         {:ok, text} <- guide(key, opts) do
      {:ok, Map.merge(%{guide: text}, skills)}
    end
  end

  defp guide(nil, opts), do: {:ok, APIGuide.short(opts)}
  defp guide(key, opts), do: APIGuide.section(String.downcase(key), opts)

  # The board's enabled skills, when one is named: the same list
  # `GET /api/boards/:board/skills` gives.
  defp skills(args, context) do
    case Args.optional(args, "board") do
      {:ok, nil} ->
        {:ok, %{}}

      {:ok, ref} ->
        with {:ok, board} <- Args.refusal(Authorize.fetch_board(Args.auth(context), ref, :read)),
             do: {:ok, SkillRegistryJSON.board_skills(board)}

      error ->
        error
    end
  end
end
