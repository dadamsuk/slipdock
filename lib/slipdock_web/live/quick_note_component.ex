defmodule SlipdockWeb.QuickNoteComponent do
  @moduledoc """
  The quick note overlay (#1538), drawn by the layout on every authenticated
  page. The header's button and Shift-Alt-N send it `toggle` by selector, so
  no page has to know it is there.

  Saving goes through `Slipdock.Wiki.QuickNote` in a task, because it asks a
  model. What was typed stays until the save has worked, and stays through
  closing the overlay, so a slip of Escape or a failed save loses nothing.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents, only: [modal: 1]

  alias Slipdock.Wiki.QuickNote

  @impl true
  def mount(socket) do
    {:ok, assign(socket, open?: false, busy?: false, text: "", error: nil, saved: nil, key: 0)}
  end

  @impl true
  def handle_event("toggle", _params, %{assigns: %{busy?: true}} = socket), do: {:noreply, socket}

  def handle_event("toggle", _params, socket) do
    {:noreply, assign(socket, open?: not socket.assigns.open?, saved: nil, error: nil)}
  end

  def handle_event("close", _params, %{assigns: %{busy?: true}} = socket), do: {:noreply, socket}
  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open?: false)}

  def handle_event("type", %{"text" => text}, socket), do: {:noreply, assign(socket, text: text)}

  def handle_event("save", %{"text" => text}, socket) do
    user = socket.assigns.current_user

    cond do
      socket.assigns.busy? ->
        {:noreply, socket}

      String.trim(text) == "" ->
        {:noreply, assign(socket, text: text, error: "Write something first.")}

      true ->
        {:noreply,
         socket
         |> assign(busy?: true, text: text, error: nil, saved: nil)
         |> start_async(:save, fn -> QuickNote.save(user, text) end)}
    end
  end

  @impl true
  def handle_async(:save, {:ok, {:ok, saved}}, socket) do
    # A new key gives an empty textarea, ready for the next note.
    {:noreply, assign(socket, busy?: false, text: "", saved: saved, key: socket.assigns.key + 1)}
  end

  def handle_async(:save, {:ok, error}, socket) do
    {:noreply, assign(socket, busy?: false, error: message(error))}
  end

  def handle_async(:save, {:exit, reason}, socket) do
    require Logger
    Logger.warning("Quick note crashed: #{inspect(reason)}")
    {:noreply, assign(socket, busy?: false, error: "Couldn't save that note.")}
  end

  defp message({:error, _status, text}) when is_binary(text), do: text

  defp message({:error, %Ecto.Changeset{} = changeset}) do
    case Slipdock.Quota.limit_kind(changeset) do
      nil -> "Couldn't save that note."
      kind -> "Your account is at its limit for #{Slipdock.Quota.label(kind)}."
    end
  end

  defp message(_error), do: "Couldn't save that note."

  defp where(%{vault: vault, location: ""}), do: vault.name
  defp where(%{vault: vault, location: path}), do: vault.name <> " / " <> path

  @impl true
  def render(assigns) do
    ~H"""
    <div id="quick-note">
      <.modal
        :if={@open?}
        id="quick-note-panel"
        size="md"
        on_close={JS.push("close", target: @myself)}
      >
        <form
          id={"quick-note-form-#{@key}"}
          phx-submit="save"
          phx-change="type"
          phx-target={@myself}
          class="space-y-3 p-5"
        >
          <h2 class="text-lg font-semibold">Quick note</h2>
          <textarea
            id={"quick-note-text-#{@key}"}
            name="text"
            rows="7"
            phx-hook="AutoGrow"
            phx-mounted={JS.focus()}
            phx-debounce="300"
            data-submit-on-ctrl-enter
            readonly={@busy?}
            placeholder="What's on your mind?"
            aria-label="Your note"
            class="textarea max-h-[60dvh] w-full"
          >{@text}</textarea>
          <p :if={@error} id="quick-note-error" class="text-sm text-error">{@error}</p>
          <div
            :if={@saved}
            id="quick-note-saved"
            class="flex items-start gap-2 rounded-lg bg-base-200/60 p-2.5 text-sm"
          >
            <.icon name="hero-check-circle" class="mt-0.5 size-4 shrink-0 text-success" />
            <div class="min-w-0">
              <.link
                navigate={~p"/boards/#{@saved.page.board_id}/wiki/#{@saved.page.slug}"}
                class="link link-hover block truncate font-medium"
              >
                {@saved.page.title}
              </.link>
              <span class="text-base-content/60">
                Saved in <span id="quick-note-where" class="font-medium">{where(@saved)}</span>
                <span :if={@saved.placed_by == :settings} id="quick-note-fallback">
                  (AI could not choose a folder, so this is your Quick notes location)
                </span>
              </span>
            </div>
          </div>
          <div class="flex items-center justify-between gap-2">
            <span class="text-xs text-base-content/50">Ctrl-Enter saves</span>
            <button type="submit" class="btn btn-primary btn-sm" disabled={@busy?}>
              {if @busy?, do: "Saving…", else: "Save"}
            </button>
          </div>
        </form>
      </.modal>
    </div>
    """
  end
end
