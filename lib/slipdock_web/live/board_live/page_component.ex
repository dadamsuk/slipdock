defmodule SlipdockWeb.BoardLive.PageComponent do
  @moduledoc """
  The panel for a wiki page placed on the board: everything a card's
  sidebar sets, for a document, and the same checklist, comments, status,
  links, fields and votes a card has (`BoardLive.ItemEvents`). Opened by
  `?page=<id>` over whatever view is showing; the document itself is one
  click away.

  The board hands it the page's id. It loads the page itself, only if it is
  placed on this board, and works out from the page what the reader may do:
  reading is enough to look and vote, anything else needs write access to
  the page.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.ItemComponents
  import SlipdockWeb.BoardLive.Helpers
  import SlipdockWeb.BoardLive.Items

  alias Slipdock.{Access, Accounts, Dates, Palette, Wiki}
  alias Slipdock.Boards.Card
  alias SlipdockWeb.BoardLive.ItemEvents

  @own_events ~w(close_page page_change page_toggle_flag page_toggle_tag unplace_page
    comment_change)
  @events @own_events ++ ItemEvents.events()
  # What a reader may do: close the panel. (Typing into a comment box they
  # can't post from changes nothing either.)
  @read_events ~w(close_page comment_change)

  @doc false
  # For the test that every `handle_event/3` clause is in the list.
  def events, do: @events

  @impl true
  def mount(socket), do: {:ok, assign(socket, item: nil, form: nil, form_key: 0)}

  @impl true
  def update(assigns, socket) do
    %{board: board, current_user: user, page_id: page_id} = assigns

    socket =
      assign(socket,
        board: board,
        current_user: user,
        page_id: page_id,
        users: assigns.users,
        close_path: assigns.close_path,
        board_can_write: Access.can_write?(Access.board_permission(user, board))
      )

    {:ok, load(socket)}
  end

  # The page as it is now, and what this reader may do with it.
  defp load(socket) do
    %{board: board, current_user: user, page_id: page_id} = socket.assigns

    case load_placed_page(board, page_id) do
      {:ok, page} ->
        assign(socket,
          item: page,
          form: to_form(Wiki.change_page(page, %{})),
          can_read: true,
          can_write: Access.can_write?(Access.page_permission(user, page))
        )

      _ ->
        assign(socket, item: nil, form: nil, can_read: false, can_write: false)
    end
  end

  # Something about the page changed: the board shows it too.
  defp changed(socket) do
    send(self(), :reload_board)
    load(socket)
  end

  @impl true
  def handle_event(event, _params, socket) when event not in @events,
    do: {:noreply, flash(socket, :error, "That isn't something this page can do.")}

  def handle_event(event, _params, %{assigns: %{item: nil}} = socket) when event != "close_page",
    do: {:noreply, socket}

  def handle_event(event, _params, %{assigns: %{can_write: false}} = socket)
      when event not in @read_events,
      do: {:noreply, flash(socket, :error, "You have read-only access to that page.")}

  def handle_event(event, params, socket) do
    if event in @own_events,
      do: event(event, params, socket),
      else: ItemEvents.handle(event, params, socket, &load/1)
  end

  defp event("comment_change", _params, socket), do: {:noreply, socket}

  defp event("close_page", _params, socket),
    do: {:noreply, push_patch(socket, to: socket.assigns.close_path)}

  # The facets, changed from the panel. Everything a card's sidebar sets, a
  # page's sets the same way.
  defp event("page_change", %{"page" => params}, socket) do
    with %Slipdock.Wiki.Page{} = page <- socket.assigns.item,
         true <- socket.assigns.can_write do
      attrs =
        params
        |> Map.take(~w(title summary priority start_date due_date date_precision completed
                       percent_complete color assignee_id status))
        |> Map.new(fn
          {k, ""} when k in ~w(start_date due_date percent_complete assignee_id color) -> {k, nil}
          pair -> pair
        end)

      with {:ok, attrs} <- scope_assignees(attrs, page, socket.assigns.current_user),
           {:ok, _} <-
             Wiki.update_page(Wiki.get_page!(page.id), attrs,
               user: socket.assigns.current_user,
               via: "web"
             ) do
        {:noreply, changed(socket)}
      else
        :error ->
          {:noreply, flash(socket, :error, "That person can't be put on this page.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          # A rejected facet has to say so: silently keeping the old value is
          # how you spend a minute wondering why the select will not stick.
          {:noreply,
           socket
           |> assign(form: to_form(changeset, action: :validate))
           |> flash(:error, changeset_message(changeset))}

        _ ->
          {:noreply, socket}
      end
    else
      _ -> {:noreply, flash(socket, :error, "You have read-only access to that page.")}
    end
  end

  defp event("page_toggle_flag", %{"flag" => flag}, socket) do
    with %Slipdock.Wiki.Page{} = page <- socket.assigns.item,
         true <- socket.assigns.can_write do
      flags =
        if flag in page.flags, do: List.delete(page.flags, flag), else: page.flags ++ [flag]

      {:ok, _} =
        Wiki.update_page(Wiki.get_page!(page.id), %{"flags" => flags},
          user: socket.assigns.current_user,
          via: "web"
        )

      {:noreply, changed(socket)}
    else
      _ -> {:noreply, flash(socket, :error, "You have read-only access to that page.")}
    end
  end

  defp event("page_toggle_tag", %{"id" => tag_id}, socket) do
    with %Slipdock.Wiki.Page{} = page <- socket.assigns.item,
         true <- socket.assigns.can_write,
         %{} = tag <- Enum.find(socket.assigns.board.tags, &(to_string(&1.id) == tag_id)) do
      current = Wiki.tags(page)

      tags =
        if Enum.any?(current, &(&1.id == tag.id)),
          do: Enum.reject(current, &(&1.id == tag.id)),
          else: current ++ [tag]

      {:ok, _} = Wiki.set_tags(page, tags)
      {:noreply, changed(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Only the page this panel shows, and only by somebody who could put it
  # there: write access to the board as well as to the page.
  defp event("unplace_page", %{"id" => id}, socket) do
    with %{board_can_write: true, item: %{id: page_id} = page} <- socket.assigns,
         true <- to_string(page_id) == to_string(id),
         {:ok, _} <- Wiki.unplace(page) do
      {:noreply,
       socket
       |> flash(:info, "Took “#{page.title}” off the board. It is still in the wiki.")
       |> changed()}
    else
      _ -> {:noreply, flash(socket, :error, "That page couldn't be taken off the board.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-page">
      <.page_modal
        :if={@item}
        page={@item}
        form={@form}
        board={@board}
        users={@users}
        can_write={@can_write}
        current_user={@current_user}
        form_key={@form_key}
        target={@myself}
      />
    </div>
    """
  end

  attr :page, :any, required: true
  attr :form, :any, required: true
  attr :board, :any, required: true
  attr :users, :list, required: true
  attr :can_write, :boolean, required: true
  attr :current_user, :any, default: nil
  attr :form_key, :integer, default: 0
  attr :target, :any, required: true

  # A page's panel is the card's panel without the card's *body*: the
  # document is a click away and is where the writing happens. Everything
  # else a card's panel says — where it stands, and what has been said about
  # it — a page says here, with the same components and the same events.
  defp page_modal(assigns) do
    assigns = assign(assigns, tags: Wiki.tags(assigns.page))

    ~H"""
    <.modal id="page-panel" on_close={JS.push("close_page", target: @target)} size="md">
      <div class="space-y-4 p-4 sm:p-6">
        <div class="flex items-start gap-3">
          <.icon name="hero-document-text" class="mt-1 size-5 shrink-0 text-primary/70" />
          <div class="min-w-0 flex-1">
            <h2 class="text-lg font-semibold leading-snug">{@page.title}</h2>
            <p class="mt-0.5 text-xs text-base-content/50">
              <span class="font-mono">{@page.code}</span>
              <span :if={@page.summary}> · {@page.summary}</span>
            </p>
          </div>
          <.link
            navigate={~p"/boards/#{@board}/wiki/#{@page.slug}"}
            class="btn btn-primary btn-sm shrink-0 gap-1.5"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open the document
          </.link>
        </div>

        <p :if={not @can_write} class="rounded-lg bg-base-200 px-3 py-2 text-sm text-base-content/60">
          You have read-only access to this page.
        </p>

        <.form
          :if={@can_write}
          phx-target={@target}
          for={@form}
          id="page-panel-form"
          phx-change="page_change"
          class="space-y-3"
        >
          <div class="grid gap-3 sm:grid-cols-2">
            <.input
              field={@form[:priority]}
              type="select"
              label="Priority"
              options={priority_options()}
            />
            <.input
              field={@form[:assignee_id]}
              type="select"
              label="Assignee"
              options={[
                {"Nobody", ""}
                | Enum.map(
                    assignee_options(@users, @page.assignee_id),
                    &{Accounts.User.display_name(&1), &1.id}
                  )
              ]}
            />
            <.input field={@form[:start_date]} type="date" label="Start" />
            <.input field={@form[:due_date]} type="date" label="Due" />
            <.input
              field={@form[:date_precision]}
              type="select"
              label="Date precision"
              options={Enum.map(Dates.precisions(), fn {k, l} -> {l, k} end)}
            />
            <.input
              field={@form[:percent_complete]}
              type="number"
              label="% complete"
              min="0"
              max="100"
            />
            <.input
              field={@form[:color]}
              type="select"
              label="Cover colour"
              options={[{"None", ""} | Enum.map(Palette.names(), &{String.capitalize(&1), &1})]}
            />
            <.input
              field={@form[:status]}
              type="select"
              label="Visibility"
              options={[{"Published", "published"}, {"Draft — writers only", "draft"}]}
            />
          </div>
          <label class="flex items-center gap-2 text-sm">
            <input type="hidden" name="page[completed]" value="false" />
            <input
              type="checkbox"
              name="page[completed]"
              value="true"
              checked={@page.completed}
              class="checkbox checkbox-sm"
            /> Written
          </label>
        </.form>

        <div class="space-y-1.5">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Flags</p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={flag <- Card.flags()}
              phx-target={@target}
              type="button"
              disabled={not @can_write}
              phx-click="page_toggle_flag"
              phx-value-flag={flag}
              class={[
                "chip gap-1",
                if(flag in @page.flags, do: "bg-primary/15 text-primary", else: "chip-line")
              ]}
            >
              <.flag_icon flag={flag} class="size-3.5" /> {flag}
            </button>
          </div>
        </div>

        <div :if={@board.tags != []} class="space-y-1.5">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Tags</p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={tag <- @board.tags}
              phx-target={@target}
              type="button"
              disabled={not @can_write}
              phx-click="page_toggle_tag"
              phx-value-id={tag.id}
              class={[
                "chip",
                if(Enum.any?(@tags, &(&1.id == tag.id)),
                  do: Palette.chip(tag.color),
                  else: "chip-line"
                )
              ]}
            >
              {tag.name}
            </button>
          </div>
        </div>

        <%!-- The card contents a page carries. Same components the card panel
              draws, same events: a page is read here exactly as a card is. --%>
        <div class="space-y-5 border-t border-base-300 pt-4">
          <.status_section target={@target} item={@page} can_write={@can_write} form_key={@form_key} />
          <.checklist_section
            target={@target}
            item={@page}
            can_write={@can_write}
            form_key={@form_key}
          />
          <.urls_section target={@target} item={@page} can_write={@can_write} form_key={@form_key} />
          <.fields_section target={@target} item={@page} board={@board} can_write={@can_write} />
          <.vote_box
            target={@target}
            item={@page}
            board={@board}
            current_user={@current_user}
            can_write={@can_write}
          />
          <.comments_section
            target={@target}
            item={@page}
            board={@board}
            current_user={@current_user}
            can_write={@can_write}
            form_key={@form_key}
          />
        </div>

        <div class="flex flex-wrap items-center gap-2 border-t border-base-300 pt-3 text-sm">
          <span class="text-base-content/50">
            In {column_name(@board, @page.column_id) || "no list"}
          </span>
          <button
            :if={@can_write and @page.column_id}
            phx-target={@target}
            type="button"
            phx-click="unplace_page"
            phx-value-id={@page.id}
            class="btn btn-ghost btn-xs"
          >
            Take it off the board
          </button>
        </div>
      </div>
    </.modal>
    """
  end
end
