defmodule Slipdock.Wiki.Drawings do
  @moduledoc """
  A new Excalidraw drawing from the wiki's tree (W-103 R11.10's "new
  drawing"): a page written the way Obsidian's Excalidraw plugin writes one,
  so a synced vault opens it as a drawing. Its file is `<name>.excalidraw.md`
  and its front matter says `excalidraw-plugin: parsed`.

  Viewing and editing it in Slipdock itself is R5 (phase 4); until then it
  reads as the plugin's own Markdown.
  """

  alias Slipdock.Boards.Board
  alias Slipdock.Wiki

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
