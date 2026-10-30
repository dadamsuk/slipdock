defmodule SlipdockWeb.MCP.Tools.QuickNote do
  @moduledoc "A quick note: `Slipdock.Wiki.QuickNote`."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Wiki.QuickNote
  alias SlipdockWeb.API.{Authorize, NoteController}
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "quick_note"

  @impl true
  def title, do: "Save a quick note"

  @impl true
  def description,
    do:
      "Saves text as a note in the person's main vault. The server names it " <>
        "(date, time, a title from the content) and picks the folder, and says where it went. " <>
        "Use write_page to choose the board and title."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{text: %{type: "string", description: "The note, in Markdown."}},
      required: ["text"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)
    allow = &(Authorize.board(auth, &1, :write) == :ok)

    with {:ok, text} <- Args.required(args, "text"),
         {:ok, note} <-
           Args.refusal(QuickNote.save(context.user, text, via: "mcp", allow: allow)) do
      {:ok, %{note: NoteController.json(note)}}
    end
  end
end
