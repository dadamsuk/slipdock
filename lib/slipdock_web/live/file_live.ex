defmodule SlipdockWeb.FileLive do
  @moduledoc """
  A wiki file that is not a page, on a page of its own at `/files/:id`:
  where a link to a file opened in a new tab, or copied, lands. Inside the
  wiki a file opens in a panel beside the page instead (#768). The viewer
  itself is `SlipdockWeb.FileViewer`'s.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.Wiki.{Files, WikiFile}
  alias SlipdockWeb.FileViewer

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case FileViewer.load(socket.assigns.current_user, id) do
      {:ok, shown} ->
        # Reached through a share (#817): no board to go back to, or to name.
        member =
          Slipdock.Access.can_read?(
            Slipdock.Access.board_permission(socket.assigns.current_user, shown.file.board)
          )

        {:ok, socket |> assign(shown) |> assign(page_title: shown.file.name, member: member)}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "That file isn't there, or isn't yours to see.")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp back(%WikiFile{board_id: board_id, folder_id: nil}), do: ~p"/boards/#{board_id}/wiki"

  defp back(%WikiFile{board_id: board_id, folder_id: folder_id}),
    do: ~p"/boards/#{board_id}/wiki?#{[folder: folder_id]}"

  defp shared_back(%WikiFile{folder_id: nil}), do: ~p"/shared"
  defp shared_back(%WikiFile{folder_id: id}), do: ~p"/shared/folders/#{id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:wiki}
      page_jumps={@page_jumps}
    >
      <div id="file-viewer" data-kind={@kind} class="flex h-full min-h-0 flex-col">
        <div class="flex items-center gap-3 border-b border-base-300 px-4 py-2">
          <.link :if={@member} navigate={back(@file)} class="btn btn-ghost btn-sm" id="file-back">
            <.icon name="hero-arrow-left" class="size-4" /> {@file.board.name}
          </.link>
          <.link
            :if={not @member}
            navigate={shared_back(@file)}
            class="btn btn-ghost btn-sm"
            id="file-back"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Shared with me
          </.link>
          <h1 class="min-w-0 flex-1 truncate text-sm font-semibold">{@file.name}</h1>
          <span class="text-xs text-base-content/60">{FileViewer.size(@file.size)}</span>
          <a href={Files.url(@file)} class="btn btn-ghost btn-sm" id="file-download" download>
            <.icon name="hero-arrow-down-tray" class="size-4" /> Download
          </a>
        </div>
        <div class="min-h-0 flex-1 overflow-auto p-4">
          <FileViewer.viewer
            kind={@kind}
            file={@file}
            {Map.take(assigns, [:tree, :text, :table, :transcript, :problem])}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
