defmodule SlipdockWeb.AccountLive.DataComponent do
  @moduledoc """
  The Import & export tab: work leaving and work arriving — the whole-account
  zip, and boards as files another Slipdock can read.
  """
  use SlipdockWeb, :live_component

  import Ecto.Query, only: [from: 2]

  alias Slipdock.Importers

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Set up once: the upload is registered a single time, and a later update
    # from the parent must not forget what was picked or imported.
    if Map.has_key?(socket.assigns, :own_boards),
      do: {:ok, socket},
      else: {:ok, load(socket)}
  end

  defp load(socket) do
    socket
    |> assign(
      own_boards: own_boards(socket.assigns.current_user),
      picked_boards: [],
      with_archived: false,
      import_report: nil,
      import_error: nil
    )
    |> allow_upload(:board_document,
      accept: ~w(.json application/json),
      max_entries: 1,
      # The same ceiling the API's body parser puts on `POST /api/import`.
      max_file_size: 8_000_000
    )
  end

  # The boards that can travel: the ones this person **owns**. A board shared
  # with you is somebody else's to hand on.
  defp own_boards(user) do
    Slipdock.Repo.all(
      from(b in Slipdock.Boards.Board,
        where: b.owner_id == ^user.id and is_nil(b.parent_card_id),
        order_by: [asc: b.name],
        select: %{id: b.id, name: b.name, code: b.code, archived: not is_nil(b.archived_at)}
      )
    )
  end

  defp import_error(reason),
    do: Importers.error_message(reason) || "That file could not be imported."

  defp upload_error_text(:too_large), do: "That file is too big."
  defp upload_error_text(:not_accepted), do: "A board document is a .json file."
  defp upload_error_text(:too_many_files), do: "One file at a time."
  defp upload_error_text(other), do: "That file could not be read (#{inspect(other)})."

  # The query string behind the download link, so the picker and the link
  # cannot drift apart.
  defp boards_download_path(picked, with_archived?) do
    params =
      %{}
      |> then(&if picked == [], do: &1, else: Map.put(&1, "boards", Enum.join(picked, ",")))
      |> then(&if with_archived?, do: Map.put(&1, "archived", "all"), else: &1)

    ~p"/account/boards.json?#{params}"
  end

  @impl true
  def handle_event("pick_board", %{"id" => id}, socket) do
    case SlipdockWeb.Params.id(id) do
      nil ->
        {:noreply, socket}

      id ->
        picked = socket.assigns.picked_boards
        picked = if id in picked, do: List.delete(picked, id), else: [id | picked]
        {:noreply, assign(socket, picked_boards: picked)}
    end
  end

  def handle_event("pick_all_boards", _params, socket),
    do: {:noreply, assign(socket, picked_boards: [])}

  def handle_event("toggle_archived", _params, socket),
    do: {:noreply, assign(socket, with_archived: !socket.assigns.with_archived)}

  def handle_event("validate_board_document", _params, socket),
    do: {:noreply, assign(socket, import_error: nil, import_report: nil)}

  def handle_event("cancel_board_document", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :board_document, ref)}

  def handle_event("import_boards", _params, socket) do
    user = socket.assigns.current_user

    case consume_uploaded_entries(socket, :board_document, fn %{path: path}, _entry ->
           {:ok, Importers.import(user, File.read!(path))}
         end) do
      [{:ok, report}] ->
        send(self(), {:flash, :info, "Imported #{report.cards} card(s)."})

        {:noreply,
         assign(socket, import_report: report, import_error: nil, own_boards: own_boards(user))}

      [{:error, reason}] ->
        {:noreply, assign(socket, import_error: import_error(reason), import_report: nil)}

      [] ->
        {:noreply, assign(socket, import_error: "Choose a file first.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h2 class="text-lg font-semibold">Your data</h2>
        <p class="mt-1 text-sm text-base-content/60">
          Everything you have here, as a zip: the boards you own with their cards, your wiki
          pages as Markdown, and anything you wrote on other people's boards.
        </p>
        <a href={~p"/account/export.zip"} class="btn btn-primary btn-sm mt-4">
          <.icon name="hero-arrow-down-tray" class="size-4" /> Download everything
        </a>
        <p class="mt-4 text-sm text-base-content/60">
          To close your account, ask an admin. Boards only you can see go with you; a board
          you have shared is handed to whoever else works on it rather than deleted out from
          under them.
        </p>
      </section>

      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h2 class="text-lg font-semibold">Move boards between servers</h2>
        <p class="mt-1 text-sm text-base-content/60">
          A board as one file that another Slipdock can read back: its lists, cards and
          subcards, tags, checklists, comments, custom fields, what waits on what, and the
          wiki. The zip above is for reading your work somewhere else; this is for moving it.
        </p>

        <h3 class="mt-5 text-sm font-medium">Take boards out</h3>
        <p class="mt-1 text-xs text-base-content/60">
          Only boards you own — a board shared with you is somebody else's to hand on.
        </p>

        <div :if={@own_boards == []} class="mt-3 text-sm text-base-content/50">
          You don't own a board yet, so there is nothing to take.
        </div>

        <div :if={@own_boards != []} class="mt-3 flex flex-wrap gap-2">
          <button
            type="button"
            phx-click="pick_all_boards"
            phx-target={@myself}
            class={["btn btn-xs", (@picked_boards == [] && "btn-primary") || "btn-outline"]}
          >
            All of them
          </button>
          <button
            :for={board <- @own_boards}
            type="button"
            phx-click="pick_board"
            phx-target={@myself}
            phx-value-id={board.id}
            class={[
              "btn btn-xs",
              (board.id in @picked_boards && "btn-primary") || "btn-outline"
            ]}
          >
            {board.name}
            <span :if={board.archived} class="opacity-60">· archived</span>
          </button>
        </div>

        <label
          :if={@own_boards != []}
          class="mt-3 flex cursor-pointer items-start gap-2 text-sm"
        >
          <input
            type="checkbox"
            checked={@with_archived}
            phx-click="toggle_archived"
            phx-target={@myself}
            class="checkbox checkbox-sm mt-0.5"
          />
          <span>
            <span class="block">Include what is archived</span>
            <span class="block text-xs text-base-content/60">
              Archived cards, archived wiki pages and archived boards. Left out otherwise.
            </span>
          </span>
        </label>

        <a
          :if={@own_boards != []}
          href={boards_download_path(@picked_boards, @with_archived)}
          class="btn btn-primary btn-sm mt-4"
        >
          <.icon name="hero-arrow-down-tray" class="size-4" />
          {if @picked_boards == [],
            do: "Download every board you own",
            else: "Download #{length(@picked_boards)} board(s)"}
        </a>

        <div class="mt-6 border-t border-base-content/10 pt-5">
          <h3 class="text-sm font-medium">Bring boards in</h3>
          <p class="mt-1 text-xs text-base-content/60">
            A file like the one above, from this server or another one — or a Trello
            board, exported from Trello as JSON (Menu → Print, export and share). It always makes
            <span class="font-medium">new</span>
            boards — it never merges into one you already have, because deciding which card
            is “the same card” is how an import quietly destroys work.
          </p>

          <form
            id="import-boards"
            phx-submit="import_boards"
            phx-target={@myself}
            phx-change="validate_board_document"
            class="mt-3"
          >
            <.live_file_input
              upload={@uploads.board_document}
              class="file-input file-input-sm w-full max-w-sm"
            />

            <div
              :for={entry <- @uploads.board_document.entries}
              class="mt-2 flex items-center gap-3 text-sm"
            >
              <span class="font-mono text-xs">{entry.client_name}</span>
              <button
                type="button"
                phx-click="cancel_board_document"
                phx-target={@myself}
                phx-value-ref={entry.ref}
                class="btn btn-ghost btn-xs"
              >
                Remove
              </button>
            </div>

            <p
              :for={error <- upload_errors(@uploads.board_document)}
              class="mt-2 text-sm text-error"
            >
              {upload_error_text(error)}
            </p>

            <button
              type="submit"
              disabled={@uploads.board_document.entries == []}
              class="btn btn-primary btn-sm mt-3"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Import
            </button>
          </form>

          <p :if={@import_error} class="mt-3 text-sm text-error">{@import_error}</p>

          <div :if={@import_report} class="mt-3 rounded-xl bg-base-200 p-4 text-sm">
            <p class="font-medium">
              {@import_report.cards} card(s) and {@import_report.pages} page(s) came in.
            </p>
            <ul class="mt-2 space-y-1">
              <li :for={board <- @import_report.boards}>
                <.link navigate={~p"/boards/#{board.id}"} class="link">{board.name}</.link>
                <span class="font-mono text-xs text-base-content/50">{board.code}</span>
              </li>
            </ul>
            <ul
              :if={@import_report.skipped != []}
              class="mt-3 space-y-1 text-xs text-base-content/60"
            >
              <li :for={note <- @import_report.skipped}>{note}</li>
            </ul>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
