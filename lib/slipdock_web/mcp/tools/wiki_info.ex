defmodule SlipdockWeb.MCP.Tools.WikiInfo do
  @moduledoc """
  The caller's one wiki (W-2201, see `Slipdock.Vaults`): what it is and where
  its Knowledge Base is; with a `path`, which board in it that path lands in;
  with a `link`, the page a `[[link]]` finds; with `changes_since`, the feed.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Vaults
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "wiki_info"

  @impl true
  def title, do: "Your wiki"

  @impl true
  def description,
    do:
      "Your wiki: your Knowledge Base first, then a folder per board. With path, the board a " <>
        "wiki path falls in; with link, the page a [[link]] finds; with changes_since, what " <>
        "changed after a cursor."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "A wiki path to locate, e.g. /Projects/Acme.md."},
        link: %{
          type: "string",
          description: "A link's words to resolve, e.g. Note or Folder/Note."
        },
        changes_since: %{
          type: "integer",
          description: "What changed after this cursor (0 for everything kept)."
        }
      },
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, %{user: user} = context) do
    {:ok, _} = Slipdock.Wiki.KnowledgeBase.ensure(user)
    wiki = Vaults.root(user)

    case args do
      %{"changes_since" => since} -> changes(wiki, since, user, context)
      _ -> lookup(wiki, args, user)
    end
  end

  defp changes(wiki, since, user, context) do
    with :ok <- cursor(since),
         do:
           {:ok,
            Slipdock.Wiki.Changes.since(wiki, since, user, limit: 200, token: context[:token])}
  end

  defp cursor(since) when is_integer(since) and since >= 0, do: :ok
  defp cursor(_), do: {:error, "changes_since is a cursor: a whole number, 0 or more"}

  defp lookup(wiki, args, user) do
    with {:ok, path} <- Args.optional(args, "path"),
         {:ok, link} <- Args.optional(args, "link") do
      cond do
        link ->
          with {:ok, page, path} <- Args.refusal(Vaults.resolve_link(wiki, link, user)),
               do:
                 {:ok,
                  %{
                    page: Map.take(V.page_summary(page), [:id, :code, :title, :board_id, :url]),
                    path: "/" <> path
                  }}

        path ->
          with {:ok, board_id, rest} <- Args.refusal(Vaults.locate(wiki, path)),
               do: {:ok, %{board: V.vault_board(wiki, board_id), rest: rest}}

        true ->
          {:ok, %{wiki: V.wiki(wiki, user)}}
      end
    end
  end
end
