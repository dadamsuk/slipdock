defmodule SlipdockWeb.API.SharedJSON do
  @moduledoc """
  The Shared with me tree (`Slipdock.Wiki.SharedTree`) as JSON, the same for
  `GET /api/shared` and the MCP `list_pages` tool's `shared: true`: owners,
  each with folders (and everything in them) and pages, every item with
  the reader's level and where it opens. Nothing of the boards they are on.
  """
  alias Slipdock.Accounts.User
  alias Slipdock.Wiki

  def tree(groups) do
    Enum.map(groups, fn %{owner: owner, items: items} ->
      %{owner: person(owner), items: Enum.map(items, &shared_node/1)}
    end)
  end

  def person(%User{} = u), do: %{id: u.id, email: u.email, name: u.name}

  defp shared_node(%{kind: :page, page: page, level: level}), do: page_node(page, level)

  defp shared_node(%{kind: :folder} = n) do
    %{
      kind: "folder",
      id: n.folder.id,
      name: n.folder.name,
      level: n.level,
      url: "/shared/folders/#{n.folder.id}",
      folders: Enum.map(n.folders, &shared_node/1),
      pages: Enum.map(n.pages, &page_node(&1, n.level)),
      files:
        Enum.map(
          n.files,
          &%{kind: "file", id: &1.id, name: &1.name, url: Wiki.Files.open_path(&1)}
        )
    }
  end

  defp page_node(page, level),
    do: %{
      kind: "page",
      id: page.id,
      code: page.code,
      title: page.title,
      level: level,
      url: "/shared/pages/#{page.id}"
    }
end
