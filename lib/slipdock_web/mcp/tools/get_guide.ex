defmodule SlipdockWeb.MCP.Tools.GetGuide do
  @moduledoc "The agent guide: the same text `GET /api/guide` serves, never a copy."
  @behaviour SlipdockWeb.MCP.Tool

  @impl true
  def name, do: "get_guide"

  @impl true
  def title, do: "Read the guide"

  @impl true
  def description,
    do:
      "How to work this server's boards: epics and subcards, picking the next card, what to " <>
        "write back. Read it once at the start of a session, before changing anything."

  @impl true
  def input_schema, do: %{type: "object", properties: %{}, additionalProperties: false}

  @impl true
  def read_only?, do: true

  @impl true
  def call(_args, %{user: user, token: token, base_url: base_url}) do
    {:ok, %{guide: SlipdockWeb.APIGuide.markdown(base_url: base_url, user: user, token: token)}}
  end
end
