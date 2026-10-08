defmodule SlipdockWeb.MCP.Tools.GetGuide do
  @moduledoc """
  The agent guide, cut from the same text `GET /api/guide` serves, never a copy.
  The whole of it is more than a client will show in one tool result, so by
  default this gives the short guide and names the other sections, and
  `section` asks for one of them (or `"all"`).
  """
  @behaviour SlipdockWeb.MCP.Tool

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
        "write back. Read it once at the start of a session, before changing anything. " <>
        "Gives the short guide; it ends with the other sections, one call each."

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
        }
      },
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, %{user: user, token: token, base_url: base_url}) do
    opts = [base_url: base_url, user: user, token: token]

    with {:ok, key} <- Args.optional(args, "section") do
      case key do
        nil ->
          {:ok, %{guide: APIGuide.short(opts)}}

        key ->
          with {:ok, text} <- APIGuide.section(String.downcase(key), opts),
               do: {:ok, %{guide: text}}
      end
    end
  end
end
