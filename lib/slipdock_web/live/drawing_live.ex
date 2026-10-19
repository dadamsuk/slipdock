defmodule SlipdockWeb.DrawingLive do
  @moduledoc """
  An Excalidraw drawing, open in the Excalidraw editor (W-103 R5.2): the
  MIT-licensed React component, loaded by the `ExcalidrawEditor` hook only
  on this page (assets/js/excalidraw_editor.js, the bundle built by
  assets/excalidraw/build.sh). Readers get it to look round; writers can
  change it, and so can several of them at once (#821, W-1730).

  Once connected the view joins the drawing's `Slipdock.Wiki.DrawingSession`,
  which holds the live scene and saves it by itself, in the shape it was read
  in — a `.excalidraw.md` page keeps its encoding and its prose, a
  `.excalidraw` file stays JSON — so Obsidian's plugin goes on editing it.
  The browser asks for the scene once it has the editor (`load`), sends the
  elements it changed (`delta`), and the whole scene after a reconnect
  (`resync`); what the others draw comes to it as `drawing:remote`.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.{Drawings, DrawingSession, Excalidraw, Page, WikiFile}
  alias SlipdockWeb.Presence
  alias SlipdockWeb.Wiki.Renderer

  @impl true
  def mount(%{"kind" => kind, "id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with {n, ""} <- Integer.parse(id),
         drawing when not is_nil(drawing) <- fetch(kind, n),
         true <- Drawings.readable?(drawing, user) do
      board = Repo.get!(Board, drawing.board_id)

      socket =
        assign(socket,
          drawing: drawing,
          board: board,
          can_write: Drawings.writable?(drawing, user),
          page_title: title(drawing),
          back: back(drawing, user),
          session: nil,
          people: [],
          pointer_at: nil
        )

      {:ok, if(connected?(socket), do: socket |> join_session() |> arrive(), else: socket)}
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

  ## The session ------------------------------------------------------------

  # Once connected, the view is one of the drawing's editors: it joins the
  # session (starting it if nobody else has the drawing open), hears what the
  # others draw, and passes it to the browser.
  defp join_session(socket) do
    case DrawingSession.join(key(socket.assigns.drawing), socket.assigns.current_user) do
      {:ok, pid, %{can_write: can_write}} ->
        Process.monitor(pid)
        assign(socket, session: pid, can_write: can_write)

      {:error, _} ->
        assign(socket, session: nil)
    end
  end

  ## Who else is here ------------------------------------------------------

  # Each open tab is one presence on the drawing's topic, with what the others
  # need to draw it: a name, initials, a colour, and whether it may only look.
  # Pointers go over the same topic straight to the other tabs, never through
  # the session, so nothing of them is ever saved.
  defp arrive(%{assigns: %{session: nil}} = socket), do: socket

  defp arrive(socket) do
    user = socket.assigns.current_user
    topic = topic(socket.assigns.drawing)
    Phoenix.PubSub.subscribe(Slipdock.PubSub, topic)

    {:ok, _} =
      Presence.track(self(), topic, socket.id || inspect(self()), %{
        user_id: user.id,
        name: User.display_name(user),
        initials: User.initials(user),
        colour: Presence.colour(user.id),
        viewing: not socket.assigns.can_write
      })

    people(socket)
  end

  defp topic(drawing) do
    {kind, id} = key(drawing)
    "drawing:#{kind}:#{id}"
  end

  # Everybody present: for the header, one avatar a person, and for the
  # editor, one collaborator a tab — bar this one.
  defp people(socket) do
    me = socket.id || inspect(self())
    present = Presence.list(topic(socket.assigns.drawing))

    tabs =
      for {id, %{metas: [meta | _]}} <- present, id != me do
        %{id: id, name: meta.name, colour: meta.colour, viewing: meta.viewing}
      end

    people =
      present
      |> Enum.map(fn {_id, %{metas: [meta | _]}} -> meta end)
      |> Enum.group_by(& &1.user_id)
      |> Enum.map(fn {_, metas} ->
        # Somebody with one tab drawing and another looking is drawing.
        %{hd(metas) | viewing: Enum.all?(metas, & &1.viewing)}
      end)
      |> Enum.sort_by(&{&1.user_id != socket.assigns.current_user.id, &1.name})

    socket
    |> assign(people: people)
    |> push_event("drawing:people", %{people: tabs})
  end

  # About twenty a second from each tab at most, whatever the browser sends.
  @pointer_ms 40

  defp pointer(socket, params) do
    now = System.monotonic_time(:millisecond)

    if socket.assigns.pointer_at && now - socket.assigns.pointer_at < @pointer_ms do
      socket
    else
      Phoenix.PubSub.broadcast_from(
        Slipdock.PubSub,
        self(),
        topic(socket.assigns.drawing),
        {:drawing_pointer, socket.id || inspect(self()), pointer_payload(params)}
      )

      assign(socket, pointer_at: now)
    end
  end

  # Only what a cursor needs, of the right types, so nothing else rides along.
  defp pointer_payload(params) do
    %{
      x: number(params["x"]),
      y: number(params["y"]),
      tool: if(params["tool"] == "laser", do: "laser", else: "pointer"),
      button: if(params["button"] == "down", do: "down", else: "up"),
      selected: for(id <- List.wrap(params["selected"]), is_binary(id), do: id) |> Enum.take(500)
    }
  end

  defp number(n) when is_number(n), do: n
  defp number(_), do: 0

  defp key(%Page{id: id}), do: {:page, id}
  defp key(%WikiFile{id: id}), do: {:file, id}

  @impl true
  def handle_info({:drawing_session, :elements, elements, files}, socket),
    do: {:noreply, push_event(socket, "drawing:remote", %{elements: elements, files: files})}

  def handle_info({:drawing_session, :saved, _base}, socket),
    do: {:noreply, push_event(socket, "drawing:saved", %{})}

  def handle_info({:drawing_session, level, text}, socket) when level in [:warning, :error],
    do: {:noreply, push_event(socket, "drawing:notice", %{level: level, text: text})}

  # The session went (it crashed, or stopped as this view was joining):
  # start again from the last save, and have the browser send what it has.
  def handle_info({:DOWN, _ref, :process, pid, _}, %{assigns: %{session: pid}} = socket) do
    socket = join_session(socket)

    if socket.assigns.session,
      do: {:noreply, push_event(socket, "drawing:resync", %{})},
      else: {:noreply, push_navigate(socket, to: socket.assigns.back)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _}, socket), do: {:noreply, socket}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, people(socket)}

  def handle_info({:drawing_pointer, id, pointer}, socket),
    do: {:noreply, push_event(socket, "drawing:pointer", Map.put(pointer, :id, id))}

  ## Events -------------------------------------------------------------------

  @impl true
  def handle_event("pointer", params, socket) when is_map(params),
    do: {:noreply, pointer(socket, params)}

  def handle_event(_event, _params, %{assigns: %{session: nil}} = socket),
    do: {:reply, %{error: "This drawing can't be opened just now."}, socket}

  def handle_event("load", _params, socket) do
    drawing = reload(socket.assigns.drawing)
    scene = DrawingSession.scene(socket.assigns.session)

    case images(drawing, socket.assigns.current_user) do
      {:ok, linked, files} ->
        {:reply,
         %{
           json: Jason.encode!(scene),
           files: files,
           linked: linked,
           view_only: not socket.assigns.can_write
         }, assign(socket, drawing: drawing)}

      :error ->
        {:reply, %{error: "This drawing can't be read: its scene is missing or damaged."}, socket}
    end
  end

  def handle_event("delta", %{"elements" => elements} = params, socket) when is_list(elements) do
    case DrawingSession.push(socket.assigns.session, elements, files(params)) do
      {:ok, stale} ->
        if params["flush"], do: DrawingSession.flush(socket.assigns.session)
        {:reply, %{stale: stale}, socket}

      {:error, reason} ->
        {:reply, %{error: refusal(reason)}, socket}
    end
  end

  def handle_event("resync", %{"elements" => elements} = params, socket) when is_list(elements) do
    pushed =
      if elements == [] and files(params) == %{},
        do: {:ok, []},
        else: DrawingSession.push(socket.assigns.session, elements, files(params))

    case pushed do
      {:ok, _} ->
        scene = DrawingSession.scene(socket.assigns.session)
        {:reply, %{elements: scene["elements"], files: scene["files"] || %{}}, socket}

      {:error, reason} ->
        {:reply, %{error: refusal(reason)}, socket}
    end
  end

  def handle_event("flush", _params, socket) do
    DrawingSession.flush(socket.assigns.session)
    {:reply, %{ok: true}, socket}
  end

  def handle_event(event, _params, socket) when event in ["delta", "resync"],
    do: {:reply, %{error: "Nothing was sent."}, socket}

  defp files(%{"files" => files}) when is_map(files), do: files
  defp files(_params), do: %{}

  defp refusal(:read_only), do: "You can look at this drawing but not change it."
  defp refusal(:not_joined), do: "This drawing can't be changed from here just now. Reload it."

  defp reload(%Page{id: id}), do: Repo.get!(Page, id)
  defp reload(%WikiFile{id: id}), do: Repo.get!(WikiFile, id)

  # The images a note links rather than carries, as `reader` may see them:
  # given to the editor to show, and never sent back.
  defp images(%Page{} = page, user) do
    with {:ok, %{links: links}} <- Excalidraw.parse_markdown(page.body),
         {:ok, _scene, images} <- Drawings.scene(page, user) do
      files =
        for {id, url} <- images, into: %{} do
          mime = url |> String.split([":", ";"]) |> Enum.at(1)
          {id, %{id: id, dataURL: url, mimeType: mime, created: 0}}
        end

      {:ok, Map.keys(links), files}
    end
  end

  defp images(%WikiFile{}, _user), do: {:ok, [], %{}}

  ## Render -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      waiting_count={@waiting_count}
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
          <div id="drawing-people" class="flex -space-x-1">
            <span
              :for={person <- @people}
              data-person={person.user_id}
              title={if person.viewing, do: "#{person.name} (viewing)", else: person.name}
              class={[
                "inline-flex size-7 items-center justify-center rounded-full text-2xs font-semibold text-white ring-2 ring-base-100",
                person.viewing && "opacity-60"
              ]}
              style={"background-color: #{person.colour}"}
            >
              {person.initials}
            </span>
          </div>
          <span data-drawing-status class="text-xs text-base-content/60" aria-live="polite">
            Loading the editor…
          </span>
        </div>
        <div id="drawing-canvas" phx-update="ignore" class="min-h-[28rem] flex-1"></div>
      </div>
    </Layouts.app>
    """
  end
end
