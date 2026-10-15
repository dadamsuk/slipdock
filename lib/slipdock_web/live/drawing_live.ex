defmodule SlipdockWeb.DrawingLive do
  @moduledoc """
  An Excalidraw drawing, open in the Excalidraw editor (W-103 R5.2): the
  MIT-licensed React component, loaded by the `ExcalidrawEditor` hook only
  on this page (assets/js/excalidraw_editor.js, the bundle built by
  assets/excalidraw/build.sh). Readers get it to look round; writers can
  change it and save.

  The browser asks for the scene once it has the editor (`load`), and sends
  the whole scene back as JSON to save (`save`). The server writes it in the
  shape it was read in — a `.excalidraw.md` page keeps its encoding and its
  prose, a `.excalidraw` file stays JSON — so Obsidian's plugin goes on
  editing it (`Slipdock.Wiki.Excalidraw`). A page is saved against the hash
  it was loaded at, so a change made meanwhile (a sync, another tab) is
  reported rather than overwritten.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, Repo, Wiki}
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.{Drawings, Excalidraw, Files, Page, WikiFile}
  alias SlipdockWeb.Wiki.Renderer

  @impl true
  def mount(%{"kind" => kind, "id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with {n, ""} <- Integer.parse(id),
         drawing when not is_nil(drawing) <- fetch(kind, n),
         true <- Drawings.readable?(drawing, user) do
      board = Repo.get!(Board, drawing.board_id)

      {:ok,
       assign(socket,
         drawing: drawing,
         board: board,
         can_write: writable?(drawing, user),
         page_title: title(drawing),
         back: back(drawing, user)
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That drawing isn't there, or isn't yours to see.")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp fetch("page", id) do
    case Repo.get(Page, id) do
      %Page{} = page -> if Excalidraw.page?(page), do: page
      nil -> nil
    end
  end

  defp fetch("file", id) do
    case Repo.get(WikiFile, id) do
      %WikiFile{} = file -> if Excalidraw.name?(file.name), do: file
      nil -> nil
    end
  end

  defp fetch(_kind, _id), do: nil

  defp writable?(%Page{} = page, user), do: Access.can_write?(Access.page_permission(user, page))

  defp writable?(%WikiFile{} = file, user),
    do: Access.can_write?(Access.file_permission(user, file))

  defp title(%Page{title: title}), do: title
  defp title(%WikiFile{name: name}), do: name

  # Somebody it was shared with goes back to their Shared view (#817): the
  # board's wiki is not theirs to open.
  defp back(drawing, user) do
    if Access.can_read?(Access.board_permission(user, Repo.get!(Board, drawing.board_id))),
      do: back(drawing),
      else: shared_back(drawing)
  end

  defp back(%Page{} = page), do: Renderer.page_path(page)
  defp back(%WikiFile{board_id: board_id}), do: ~p"/boards/#{board_id}/wiki"

  defp shared_back(%Page{id: id}), do: ~p"/shared/pages/#{id}"
  defp shared_back(%WikiFile{folder_id: nil}), do: ~p"/shared"
  defp shared_back(%WikiFile{folder_id: id}), do: ~p"/shared/folders/#{id}"

  ## Events -------------------------------------------------------------------

  @impl true
  def handle_event("load", _params, socket) do
    drawing = reload(socket.assigns.drawing)

    case load(drawing, socket.assigns.current_user) do
      {:ok, reply} ->
        {:reply, Map.put(reply, :view_only, not socket.assigns.can_write),
         assign(socket, drawing: drawing)}

      :error ->
        {:reply, %{error: "This drawing can't be read: its scene is missing or damaged."}, socket}
    end
  end

  def handle_event("save", %{"json" => json} = params, socket) when is_binary(json) do
    if socket.assigns.can_write do
      case save(socket.assigns.drawing, json, params["base"], socket.assigns.current_user) do
        {:ok, saved} ->
          {:reply, %{ok: true, base: base(saved)}, assign(socket, drawing: saved)}

        {:error, message} ->
          {:reply, %{error: message}, socket}
      end
    else
      {:reply, %{error: "You can look at this drawing but not change it."}, socket}
    end
  end

  def handle_event("save", _params, socket),
    do: {:reply, %{error: "Nothing was sent to save."}, socket}

  defp reload(%Page{id: id}), do: Repo.get!(Page, id)
  defp reload(%WikiFile{id: id}), do: Repo.get!(WikiFile, id)

  # The scene as the file holds it (not re-encoded, so nothing is reordered),
  # the images a note links rather than carries, and what to save against.
  defp load(%Page{} = page, user) do
    with {:ok, %{json: json, links: links}} <- Excalidraw.parse_markdown(page.body),
         {:ok, _scene, images} <- Drawings.scene(page, user) do
      files =
        for {id, url} <- images, into: %{} do
          mime = url |> String.split([":", ";"]) |> Enum.at(1)
          {id, %{id: id, dataURL: url, mimeType: mime, created: 0}}
        end

      {:ok, %{json: json, files: files, linked: Map.keys(links), base: base(page)}}
    end
  end

  defp load(%WikiFile{} = file, _user) do
    with {:ok, json} <- File.read(Files.disk_path(file)),
         {:ok, _scene} <- Excalidraw.parse_json(json) do
      {:ok, %{json: json, files: %{}, linked: [], base: base(file)}}
    else
      _ -> :error
    end
  end

  defp base(%Page{content_hash: hash}), do: hash
  defp base(%WikiFile{sha256: hash}), do: hash

  defp save(%Page{} = page, json, base, user) do
    current = Repo.get!(Page, page.id)

    with {:ok, body} <- written(Excalidraw.write_markdown(current.body, json)),
         {:ok, saved} <-
           Wiki.update_page(current, %{"body" => body}, user: user, via: "web", base_hash: base) do
      {:ok, saved}
    else
      {:error, :conflict, _} ->
        {:error,
         "This drawing was changed somewhere else since you opened it. Reload to see that version; your changes here are not saved."}

      {:error, _status, message} when is_binary(message) ->
        {:error, message}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, _} ->
        {:error, "The drawing couldn't be saved."}
    end
  end

  defp save(%WikiFile{} = file, json, base, _user) do
    current = Repo.get!(WikiFile, file.id)

    cond do
      base not in [nil, ""] and base != current.sha256 ->
        {:error,
         "This drawing was changed somewhere else since you opened it. Reload to see that version; your changes here are not saved."}

      Excalidraw.write_json(json) == :error ->
        {:error, "That isn't an Excalidraw scene, so it wasn't saved."}

      true ->
        path = Path.join(System.tmp_dir!(), "drawing-#{System.unique_integer([:positive])}")
        File.write!(path, json)

        try do
          case Files.replace(current, %{}, path) do
            {:ok, saved} -> {:ok, saved}
            {:error, _} -> {:error, "The drawing couldn't be saved."}
          end
        after
          File.rm(path)
        end
    end
  end

  defp written({:ok, body}), do: {:ok, body}
  defp written(:error), do: {:error, "That isn't an Excalidraw scene, so it wasn't saved."}

  ## Render -------------------------------------------------------------------

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
      <div
        id="drawing-editor"
        phx-hook="ExcalidrawEditor"
        data-vendor="/vendor/excalidraw/"
        data-can-write={to_string(@can_write)}
        class="flex h-full min-h-0 flex-col"
      >
        <div class="flex items-center gap-3 border-b border-base-300 px-4 py-2">
          <.link navigate={@back} class="btn btn-ghost btn-sm" id="drawing-back">
            <.icon name="hero-arrow-left" class="size-4" /> Back
          </.link>
          <h1 class="min-w-0 flex-1 truncate text-sm font-semibold">{@page_title}</h1>
          <span data-drawing-status class="text-xs text-base-content/60" aria-live="polite">
            Loading the editor…
          </span>
          <button
            :if={@can_write}
            type="button"
            data-drawing-save
            class="btn btn-primary btn-sm"
            disabled
            id="drawing-save"
          >
            Save
          </button>
        </div>
        <div id="drawing-canvas" phx-update="ignore" class="min-h-[28rem] flex-1"></div>
      </div>
    </Layouts.app>
    """
  end
end
