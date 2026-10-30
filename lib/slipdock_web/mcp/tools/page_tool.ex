defmodule SlipdockWeb.MCP.Tools.PageTool do
  @moduledoc "An AI tool over a wiki page: `Slipdock.Wiki.PageTools`, as a tool."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Wiki.PageTools
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Tools.ReadPage

  @impl true
  def name, do: "page_tool"

  @impl true
  def title, do: "Run an AI tool over a page"

  @impl true
  def description,
    do:
      "Runs a model over a wiki page on your AI key and returns the answer; writes nothing. " <>
        "tool: summarise, key_points, actions, titles or improve."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        page: %{
          type: "string",
          description: "Page code like W-31, or a slug or title with board."
        },
        board: %{type: "string", description: "The board, when page is a slug or title."},
        tool: %{type: "string", enum: PageTools.names()}
      },
      required: ["page", "tool"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "page"),
         {:ok, tool} <- Args.required(args, "tool"),
         {:ok, board} <- Args.optional(args, "board"),
         {:ok, page} <- ReadPage.find(ref, board, auth),
         :ok <- ReadPage.check(page, auth, :read),
         {:ok, answer} <-
           Args.refusal(PageTools.run(tool, %{title: page.title, body: page.body}, context.user)) do
      {:ok, %{page: page.code, answer: answer}}
    end
  end
end
