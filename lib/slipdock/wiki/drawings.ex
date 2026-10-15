defmodule Slipdock.Wiki.Drawings do
  @moduledoc """
  Excalidraw drawings in a wiki (W-103 R5): finding the one a page embeds,
  drawing its preview, and making a new one.

  A drawing is either a page — the plugin's `<name>.excalidraw.md`, front
  matter `excalidraw-plugin: parsed` — or a `.excalidraw` wiki file. The
  format itself is `Slipdock.Wiki.Excalidraw`.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Excalidraw, Files, Links, Page, WikiFile}

  # Images a drawing links rather than carries are put into its preview, up
  # to this size each; past it they are drawn as a placeholder.
  @max_inline_image 5 * 1024 * 1024

  @front_matter "---\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n---\n"

  @body """
  ==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠==

  # Excalidraw Data

  ## Text Elements
  %%
  ## Drawing
  ```json
  {"type":"excalidraw","version":2,"source":"https://slipdock.us","elements":[],"appState":{"gridSize":null,"viewBackgroundColor":"#ffffff"},"files":{}}
  ```
  %%
  """

  @doc """
  The drawing `![[target]]` names, as `reader` may see it: a `.excalidraw`
  wiki file, or the page whose file is `target` (`.md` or not), found the
  way any link is and then by its file name.
  """
  @spec resolve(Board.t(), String.t(), User.t() | nil) ::
          {:file, WikiFile.t()} | {:page, Page.t()} | nil
  def resolve(%Board{} = board, target, reader) do
    name = target |> String.trim() |> String.replace_suffix(".md", "")

    with nil <- file(board, name, reader),
         nil <- linked_page(board, name, reader) do
      named_page(board, name, reader)
    end
  end

  defp file(board, name, reader) do
    case Files.resolve(board, name, reader) do
      %WikiFile{} = file -> {:file, file}
      nil -> nil
    end
  end

  defp linked_page(board, name, reader) do
    ref = %{kind: :page, target: name, board: nil, raw: "[[#{name}]]", count: 1}

    case Links.resolve(board, [ref], as: reader) do
      [%{to: {:page, %Page{} = page}}] -> if Excalidraw.page?(page), do: {:page, page}
      _ -> nil
    end
  end

  defp named_page(board, name, reader) do
    base = name |> String.split("/") |> List.last() |> String.downcase()

    from(p in Page,
      where: p.board_id == ^board.id and is_nil(p.archived_at),
      where: fragment("lower(?)", p.file_name) == ^base,
      order_by: p.id,
      limit: 1
    )
    |> Repo.one()
    |> case do
      %Page{} = page -> if readable?(page, reader), do: {:page, page}
      nil -> nil
    end
  end

  @doc "Whether `reader` may see the drawing (nil is the system)."
  def readable?(_drawing, nil), do: true

  def readable?(%Page{archived_at: nil} = page, %User{} = reader),
    do: Wiki.visible?(page, Access.page_permission(reader, page))

  def readable?(%WikiFile{archived_at: nil} = file, %User{} = reader),
    do: Access.can_read?(Access.file_permission(reader, file))

  def readable?(_drawing, _reader), do: false

  @doc """
  The scene in a drawing, and the images it links rather than carries, as
  `fileId => data URL`, for `reader`.
  """
  @spec scene(Page.t() | WikiFile.t(), User.t() | nil) :: {:ok, map, map} | :error
  def scene(%Page{} = page, reader) do
    with {:ok, %{scene: scene, links: links}} <- Excalidraw.parse_markdown(page.body) do
      board = Repo.get!(Board, page.board_id)
      {:ok, scene, linked_images(board, links, reader)}
    end
  end

  def scene(%WikiFile{} = file, _reader) do
    with {:ok, json} <- File.read(Files.disk_path(file)),
         {:ok, scene} <- Excalidraw.parse_json(json) do
      {:ok, scene, %{}}
    else
      _ -> :error
    end
  end

  @doc "The drawing's preview as an SVG document, or `:error` if it cannot be read."
  @spec svg(Page.t() | WikiFile.t(), User.t() | nil) :: {:ok, String.t()} | :error
  def svg(drawing, reader) do
    with {:ok, scene, images} <- scene(drawing, reader) do
      {:ok, Excalidraw.SVG.render(scene, images)}
    end
  end

  @doc """
  Where a drawing's preview is served, with its hash so a changed drawing
  is fetched again and an unchanged one comes from the browser's cache.
  """
  def preview_url(%Page{id: id, content_hash: hash}),
    do: "/wiki-drawings/page/#{id}?v=#{String.slice(hash || "", 0, 12)}"

  def preview_url(%WikiFile{id: id, sha256: hash}),
    do: "/wiki-drawings/file/#{id}?v=#{String.slice(hash || "", 0, 12)}"

  defp linked_images(board, links, reader) do
    for {id, target} <- links,
        %WikiFile{} = file <- [Files.resolve(board, target, reader)],
        WikiFile.image?(file) and file.size <= @max_inline_image,
        {:ok, bytes} <- [File.read(Files.disk_path(file))],
        into: %{},
        do: {id, "data:#{file.content_type};base64," <> Base.encode64(bytes)}
  end

  @doc """
  Makes an empty drawing on `board`, in `folder` (or at the top), named the
  way the plugin names one: `Drawing 2026-10-13 09.41.07`.
  """
  def create(%Board{} = board, folder, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() end)
    title = "Drawing " <> Calendar.strftime(now, "%Y-%m-%d %H.%M.%S")

    Wiki.create_page(
      board,
      %{
        "title" => title,
        "file_name" => title <> ".excalidraw",
        "front_matter" => @front_matter,
        "body" => @body,
        "folder_id" => folder && folder.id
      },
      Keyword.take(opts, [:user, :via])
    )
  end
end
