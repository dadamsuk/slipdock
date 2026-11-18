defmodule SlipdockWeb.Ops.QuickNote do
  @moduledoc """
  A quick note (#1538), defined once (#3188): the text is saved as a page in
  the person's wiki, which `Slipdock.Wiki.QuickNote` names and files, and
  the answer says where it went.

  Before it, REST took a blank or missing `text` to `QuickNote.save/3`
  (422, "A note needs something in it.") while MCP's schema required it:
  now both refuse it in the cast (400, "text is required"). The way it came
  in (`api`, `cli`, `mcp`) is the caller's actor's, on every surface.
  """
  @behaviour SlipdockWeb.Ops.Op

  import SlipdockWeb.Ops.Shared, only: [via: 1]

  alias Slipdock.Wiki.QuickNote
  alias SlipdockWeb.API.Authorize

  @impl true
  def definition do
    %{
      name: "quick_note",
      title: "Save a quick note",
      summary:
        "Saves text as a note in the person's wiki. The server names it " <>
          "(date, time, a title from the content) and picks the folder, and says where it went. " <>
          "Use write_page to choose the board and title.",
      verb: :post,
      path: "/api/notes",
      permission: {:wiki, :write},
      writes?: true,
      status: :created,
      params: [
        %{name: "text", type: :string, required: true, doc: "The note, in Markdown."}
      ],
      cli: %{
        command: "note",
        positional: ["text..."],
        # With no words, the text is `--body TEXT` (`-`, stdin) or `--file F`.
        flags: %{
          "body" => %{param: "text", read: :stdin},
          "file" => %{param: "text", read: :file}
        }
      }
    }
  end

  @impl true
  def run(%{"text" => text}, auth) do
    allow = &(Authorize.board(auth, &1, :write) == :ok)

    with {:ok, note} <-
           QuickNote.save(auth.assigns.current_user, text, via: via(auth), allow: allow) do
      {:ok, %{note: json(note)}}
    end
  end

  @doc "A saved note as every surface gives it."
  def json(%{page: page, location: location, placed_by: placed_by}) do
    %{code: page.code, title: page.title, location: "/" <> location, placed_by: placed_by}
  end
end
