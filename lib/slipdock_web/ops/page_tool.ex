defmodule SlipdockWeb.Ops.PageTool do
  @moduledoc """
  An AI tool over a wiki page (#1539), defined once (#3188):
  `Slipdock.Wiki.PageTools` on the caller's AI key, answering
  `{page, answer}` and writing nothing, so reading the page is enough.

  Before it, REST named the page by its id or code alone and MCP took a
  `board` for a slug or title too: both take it now. A page the caller
  can't read was REST's 403 and MCP's "not there": now it is not there on
  both (404), as a page code reaches any page and a 403 would say it exists.
  An unknown tool is refused by the cast (400) on both.
  """
  @behaviour SlipdockWeb.Ops.Op

  import SlipdockWeb.Ops.Shared, only: [fetch_page: 4]

  alias Slipdock.Wiki.PageTools

  @impl true
  def definition do
    %{
      name: "page_tool",
      title: "Run an AI tool over a page",
      summary:
        "Runs a model over a wiki page on your AI key and returns the answer; writes nothing. " <>
          "tool: summarise, key_points, actions, titles or improve.",
      verb: :post,
      path: "/api/pages/:id/ai",
      permission: {:page, :read},
      writes?: false,
      params: [
        %{
          name: "page",
          type: :string,
          required: true,
          in_path: "id",
          doc: "Page code like W-31, or a slug or title with board."
        },
        %{name: "board", type: :string, doc: "The board, when page is a slug or title."},
        %{name: "tool", type: {:enum, PageTools.names()}, required: true}
      ],
      cli: %{
        command: "page ai",
        positional: ["page", "tool"],
        flags: %{"board" => %{param: "board"}}
      }
    }
  end

  @impl true
  def run(%{"page" => ref, "tool" => tool} = params, auth) do
    with {:ok, page} <- fetch_page(auth, ref, params["board"], :read),
         {:ok, answer} <-
           PageTools.run(tool, %{title: page.title, body: page.body}, auth.assigns.current_user) do
      {:ok, %{page: page.code, answer: answer}}
    end
  end
end
