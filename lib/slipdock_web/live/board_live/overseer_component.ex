defmodule SlipdockWeb.BoardLive.OverseerComponent do
  @moduledoc """
  The Overseer part of a board's Automations panel (#2068, `Slipdock.Overseer`):
  whether it is on, the bounds its passes are paced between, its next pass and
  last digest, and the conditions its watch has open, each with why and what
  to do.

  Anybody who can open the panel sees where it stands; only the board's
  owner changes it, which every event checks for itself. A sub-board shows
  its tree's root's overseer, and only to someone who can read the root:
  its conditions and digest name cards anywhere in the tree.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents, only: [timestamp: 1]

  alias Slipdock.{Access, Overseer}
  alias Slipdock.Overseer.Settings

  @impl true
  def mount(socket), do: {:ok, assign(socket, notice: nil)}

  @impl true
  def update(assigns, socket) do
    %{board: board, current_user: user} = assigns

    {:ok,
     socket
     |> assign(board: board, current_user: user)
     |> assign(can_manage: Access.board_permission(user, board) == :owner)
     |> assign(can_read_root: can_read_root?(user, board))
     |> load()}
  end

  defp can_read_root?(_user, %{root_id: nil}), do: true

  defp can_read_root?(user, board),
    do: Access.can_read?(Access.board_permission(user, Overseer.root(board)))

  defp load(%{assigns: %{can_read_root: false}} = socket), do: assign(socket, state: nil)

  defp load(socket) do
    state = Overseer.state(socket.assigns.board)

    assign(socket,
      state: state,
      form: to_form(Settings.changeset(state.settings, %{}), as: :overseer)
    )
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{can_manage: false}} = socket),
    do:
      {:noreply,
       assign(socket, notice: {:error, "Only the board's owner can change the overseer."})}

  def handle_event("validate", %{"overseer" => params}, socket) do
    form =
      socket.assigns.state.settings
      |> Settings.changeset(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :overseer)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"overseer" => params}, socket) do
    case Overseer.put_settings(socket.assigns.board, params) do
      {:ok, settings} ->
        message = if settings.enabled, do: "The overseer is on.", else: "The overseer is off."
        {:noreply, socket |> load() |> assign(notice: {:info, message})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           form: to_form(Map.put(changeset, :action, :validate), as: :overseer),
           notice: {:error, "Not saved: see the fields below."}
         )}

      {:error, _} ->
        {:noreply,
         assign(socket, notice: {:error, "Not saved: the overseer's card couldn't be made."})}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-overseer" class="space-y-3 border-t border-base-content/10 pt-4">
      <div>
        <p class="text-sm font-medium">Overseer</p>
        <p class="text-xs text-base-content/60">
          Watches outcomes, not the work: says when a person should look now, once per condition,
          and clears it when it ends. A cheap model on one of your runners writes the digest.
        </p>
      </div>

      <.callout
        :if={@notice}
        id="overseer-notice"
        kind={if elem(@notice, 0) == :error, do: :error, else: :info}
      >
        {elem(@notice, 1)}
      </.callout>

      <p :if={is_nil(@state)} id="overseer-unreadable" class="text-xs text-base-content/60">
        This board's overseer is its tree's root board's, which you can't read.
      </p>

      <.form
        :if={@can_manage and @state}
        for={@form}
        id="overseer-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="space-y-3"
      >
        <input type="hidden" name={@form[:enabled].name} value="false" />
        <label class="flex cursor-pointer items-start gap-2 text-sm">
          <input
            type="checkbox"
            id="overseer-enabled"
            name={@form[:enabled].name}
            value="true"
            checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:enabled].value)}
            class="checkbox mt-0.5"
          />
          <span>
            <span class="font-medium">Watch this board</span>
            <span class="block text-xs text-base-content/60">
              Checks every minute for work going round, waiting on you while nothing runs,
              slow cards and jobs, idle runners, and epics with no way forward.
            </span>
          </span>
        </label>
        <div class="flex flex-wrap gap-3">
          <.input field={@form[:pool]} label="Runner pool" class="input field field-mono w-32" />
          <.input
            field={@form[:min_minutes]}
            type="number"
            label="Every (min), while active"
            class="input field w-24"
          />
          <.input
            field={@form[:max_minutes]}
            type="number"
            label="Up to (min), when quiet"
            class="input field w-24"
          />
          <.input
            field={@form[:idle_minutes]}
            type="number"
            label="Runners idle after (min)"
            class="input field w-24"
          />
          <.input
            field={@form[:digest_at]}
            type="text"
            label="Housekeeping digest at"
            placeholder="07:00"
            class="input field w-24"
          />
        </div>
        <input type="hidden" name={@form[:email].name} value="false" />
        <label class="flex cursor-pointer items-center gap-2 text-sm">
          <input
            type="checkbox"
            id="overseer-email"
            name={@form[:email].name}
            value="true"
            checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:email].value)}
            class="checkbox"
          />
          <span>Email me each new condition, as well as the alert</span>
        </label>
        <p class="text-xs text-base-content/60">
          Passes go to a runner whose config has <code>job_overseer</code>; give it a cheap,
          fast model.
        </p>
        <button type="submit" class="btn btn-primary btn-sm" id="overseer-save">Save</button>
      </.form>

      <div :if={@state && @state.settings.enabled} id="overseer-state" class="space-y-1 text-xs">
        <p :if={@state.settings.next_run_at} class="text-base-content/60">
          Next pass <.timestamp at={@state.settings.next_run_at} />
          <span :if={@state.open_job}> · pass #{@state.open_job.id} {@state.open_job.status}</span>
        </p>
        <div
          :if={@state.settings.last_digest}
          id="overseer-digest"
          class="rounded-box bg-base-200/60 p-2"
        >
          <p class="font-medium">Last digest · {health(@state.settings.last_health)}</p>
          <p class="whitespace-pre-line">{@state.settings.last_digest}</p>
        </div>
      </div>

      <.empty_state
        :if={@state && @state.conditions == []}
        id="overseer-empty"
        icon="hero-eye"
        title="Nothing needs you"
        compact
      >
        Nothing the watch checks for is open on this board.
      </.empty_state>

      <ul :if={@state && @state.conditions != []} id="overseer-conditions" class="space-y-2">
        <li
          :for={c <- @state.conditions}
          id={"overseer-condition-#{c.id}"}
          class="rounded-box bg-base-200/40 p-2 text-sm"
        >
          <p class="font-medium">
            <.link
              :if={c.card}
              navigate={~p"/boards/#{c.card.board_id}/cards/#{c.card_id}"}
              class="link"
            >
              {c.title}
            </.link>
            <span :if={is_nil(c.card)}>{c.title}</span>
          </p>
          <p class="text-xs text-base-content/60">{c.why}</p>
          <p class="text-xs">What to do: {c.todo}</p>
        </li>
      </ul>
    </div>
    """
  end

  defp health("on_track"), do: "on track"
  defp health("off_track"), do: "off track"
  defp health(_), do: "at risk"
end
