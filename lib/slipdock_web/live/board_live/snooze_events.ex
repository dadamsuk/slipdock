defmodule SlipdockWeb.BoardLive.SnoozeEvents do
  @moduledoc """
  Snooze on the board view (W-1803): the Snooze… picker, for one card (from
  its panel, or `z` on the board) or every card picked out in select mode;
  waking one by hand; and a list's "N snoozed" footer showing them in place.

  The picker offers tomorrow, next Monday, a week today and next month —
  each midnight in the reader's timezone — or a date of one's own, with an
  optional note. A card in an in-progress list is offered a move back to the
  ready list, and one due before the chosen day says so. `z` then `z` again
  is tomorrow: the picker's rows carry keys of their own (`data-snooze-key`,
  answered by the `SnoozeKeys` hook).

  `BoardLive.Show` hands these over once its access guards have passed, and
  every card named is looked up on this board before it is touched.
  """
  use Phoenix.Component

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveView, only: [put_flash: 3]
  import SlipdockWeb.BoardLive.State, only: [reload_board: 1]
  import SlipdockWeb.CoreComponents, only: [icon: 1, input: 1]

  alias Phoenix.LiveView.JS
  alias Slipdock.{Boards, Repo, Snooze, Timezones}
  alias Slipdock.Boards.{Card, Column}

  @write_events ~w(open_snooze snooze_preset snooze_save wake_card)
  @read_events ~w(snooze_change cancel_snooze toggle_snoozed)

  # The picker's preset keys, `z` first so `z z` is tomorrow.
  @keys %{"tomorrow" => "z", "monday" => "m", "week" => "w", "month" => "n"}

  @doc "Events that change the board (snoozing and waking)."
  def write_events, do: @write_events

  @doc "Events that change nothing stored."
  def read_events, do: @read_events

  @doc "Every event handled here."
  def events, do: @write_events ++ @read_events

  @doc "The assigns this module keeps on the board view."
  def mount_assigns, do: [snoozing: nil, revealed_snoozed: MapSet.new()]

  @doc "Handles one of `events/0`, after the board's guards."
  def handle_event("open_snooze", params, socket) do
    ids =
      case params do
        %{"id" => id} -> [id]
        _ -> MapSet.to_list(socket.assigns.selected)
      end

    case open_cards(socket, ids) do
      [] ->
        {:noreply, put_flash(socket, :error, "Pick an open card to snooze.")}

      cards ->
        {:noreply, assign(socket, snoozing: picker(socket, cards))}
    end
  end

  def handle_event("snooze_change", %{"snooze" => params}, %{assigns: %{snoozing: %{}}} = socket),
    do: {:noreply, update(socket, :snoozing, &%{&1 | form: snooze_form(params), error: nil})}

  def handle_event("cancel_snooze", _, socket), do: {:noreply, assign(socket, snoozing: nil)}

  def handle_event("snooze_preset", %{"preset" => key}, %{assigns: %{snoozing: %{} = s}} = socket) do
    case Enum.find(s.presets, fn {k, _, _} -> k == key end) do
      {_, _, date} -> apply_snooze(socket, date, s.form.params)
      nil -> {:noreply, socket}
    end
  end

  def handle_event("snooze_save", %{"snooze" => params}, %{assigns: %{snoozing: %{}}} = socket) do
    case Date.from_iso8601(params["date"] || "") do
      {:ok, date} ->
        apply_snooze(socket, date, params)

      _ ->
        {:noreply,
         update(
           socket,
           :snoozing,
           &%{&1 | form: snooze_form(params), error: "Pick a day to wake it."}
         )}
    end
  end

  def handle_event("wake_card", %{"id" => id}, socket) do
    with [card] <- board_cards(socket, [id]),
         {:ok, _} <- Snooze.wake(card, by: socket.assigns.current_user) do
      {:noreply, reload_board(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_snoozed", %{"id" => id}, socket) do
    id = to_int(id)

    {:noreply,
     update(socket, :revealed_snoozed, fn set ->
       if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
     end)}
  end

  # Picker events with no picker open: a stale click.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Snoozing -----------------------------------------------------------------

  defp apply_snooze(socket, %Date{} = date, params) do
    %{snoozing: s, current_user: user} = socket.assigns
    opts = [note: params["note"], notify: params["notify"] == "true"]
    back? = params["back"] != "false" and s.ready != nil

    results =
      for card <- board_cards(socket, s.ids) do
        with {:ok, card} <- Snooze.snooze(card, user, date, opts) do
          if back? and card.column_id in s.doing_ids,
            do: Boards.move_card_to_index(card, s.ready, :top, actor: Slipdock.Actor.web(user))

          {:ok, card}
        end
      end

    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {[], [{:error, reason} | _]} ->
        {:noreply, update(socket, :snoozing, &%{&1 | error: Snooze.error_message(reason)})}

      {done, failed} ->
        n = length(done)

        message =
          "Snoozed #{n} #{if n == 1, do: "card", else: "cards"} until " <>
            Calendar.strftime(date, "%a %-d %b") <>
            if(failed == [], do: "", else: " (#{length(failed)} couldn't be)")

        {:noreply,
         socket
         |> assign(snoozing: nil, selected: MapSet.new())
         |> reload_board()
         |> put_flash(if(failed == [], do: :info, else: :error), message)}
    end
  end

  # The picker for `cards`: presets in the reader's own timezone, and what it
  # needs to ask about the cards in progress or due before the day picked.
  defp picker(socket, cards) do
    %{board: board, current_user: user} = socket.assigns
    zone = Timezones.of(user)
    columns = board.columns
    doing_ids = for c <- columns, SlipdockWeb.APIGuide.role(columns, c) == "doing", do: c.id
    ready = SlipdockWeb.APIGuide.list_roles(columns).ready

    due =
      cards |> Enum.map(& &1.due_date) |> Enum.reject(&is_nil/1) |> Enum.min(Date, fn -> nil end)

    %{
      ids: Enum.map(cards, & &1.id),
      title: if(length(cards) == 1, do: hd(cards).title, else: "#{length(cards)} cards"),
      zone: zone,
      presets: Snooze.presets(Timezones.today(zone)),
      doing_ids: doing_ids,
      in_progress: Enum.count(cards, &(&1.column_id in doing_ids)),
      ready: ready,
      due: due,
      form: snooze_form(%{"date" => "", "note" => "", "notify" => "false", "back" => "true"}),
      error: nil
    }
  end

  defp snooze_form(params), do: to_form(params, as: :snooze)

  # Cards on this board, by id, that can be snoozed: open, not stand-ins.
  defp open_cards(socket, ids),
    do: socket |> board_cards(ids) |> Enum.reject(&(&1.completed or Card.stand_in?(&1)))

  defp board_cards(socket, ids) do
    ids = ids |> Enum.map(&to_int/1) |> Enum.reject(&is_nil/1)
    board_id = socket.assigns.board.id

    from(c in Card,
      where: c.id in ^ids and c.board_id == ^board_id and is_nil(c.archived_at),
      order_by: [asc: c.id]
    )
    |> Repo.all()
  end

  defp to_int(id) when is_integer(id), do: id

  defp to_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  ## The picker ---------------------------------------------------------------

  attr :snoozing, :map, required: true

  @doc "The Snooze… picker, while one is open."
  def snooze_picker(assigns) do
    assigns = assign(assigns, keys: @keys)

    ~H"""
    <div
      id="snooze-picker"
      phx-hook="SnoozeKeys"
      data-key-capture="filter"
      class="fixed inset-0 z-[80] flex items-start justify-center overflow-y-auto bg-base-content/30 p-3 pt-[10vh] backdrop-blur-sm"
    >
      <div
        class="kanban-modal-in w-full max-w-sm overflow-hidden rounded-2xl bg-base-100 shadow-2xl ring-1 ring-base-content/10"
        phx-click-away={JS.push("cancel_snooze")}
      >
        <header class="flex items-center gap-2 border-b border-base-300/70 px-4 py-2.5 text-sm font-semibold">
          <span aria-hidden="true">💤</span>
          <span class="min-w-0 flex-1 truncate">Snooze {@snoozing.title}</span>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-circle"
            phx-click="cancel_snooze"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </header>
        <.form
          for={@snoozing.form}
          id="snooze-form"
          phx-change="snooze_change"
          phx-submit="snooze_save"
          class="space-y-3 p-3"
        >
          <ul class="space-y-0.5">
            <li :for={{key, label, date} <- @snoozing.presets}>
              <button
                type="button"
                id={"snooze-#{key}"}
                data-snooze-key={@keys[key]}
                phx-click="snooze_preset"
                phx-value-preset={key}
                class="flex w-full items-center gap-2.5 rounded-lg px-2 py-1.5 text-left text-sm hover:bg-base-200"
              >
                <kbd class="flex size-5 shrink-0 items-center justify-center rounded border border-base-content/20 bg-base-200/60 font-mono text-2xs">
                  {@keys[key]}
                </kbd>
                <span class="flex-1">{label}</span>
                <span
                  :if={@snoozing.due && Date.compare(date, @snoozing.due) == :gt}
                  class="text-2xs text-warning"
                >
                  past due
                </span>
                <span class="text-xs text-base-content/60">{Calendar.strftime(date, "%a %-d %b")}</span>
              </button>
            </li>
          </ul>
          <div class="flex items-end gap-2">
            <div class="flex-1">
              <.input field={@snoozing.form[:date]} type="date" label="Or until" />
            </div>
            <button type="submit" id="snooze-save" class="btn btn-primary btn-sm mb-0.5">
              Snooze
            </button>
          </div>
          <.input
            field={@snoozing.form[:note]}
            label="Note (optional)"
            placeholder="waiting for the vendor's quote"
            maxlength={Snooze.note_max()}
          />
          <label class="flex cursor-pointer items-center gap-2 text-sm">
            <input type="hidden" name="snooze[notify]" value="false" />
            <input
              type="checkbox"
              name="snooze[notify]"
              value="true"
              checked={@snoozing.form[:notify].value == "true"}
              class="checkbox checkbox-xs"
            /> Tell me when it wakes
          </label>
          <label
            :if={@snoozing.in_progress > 0 and @snoozing.ready}
            id="snooze-back"
            class="flex cursor-pointer items-start gap-2 rounded-lg bg-warning/10 p-2 text-sm"
          >
            <input type="hidden" name="snooze[back]" value="false" />
            <input
              type="checkbox"
              name="snooze[back]"
              value="true"
              checked={@snoozing.form[:back].value != "false"}
              class="checkbox checkbox-xs mt-0.5"
            />
            <span>
              {if @snoozing.in_progress == 1, do: "It's", else: "#{@snoozing.in_progress} are"} in progress.
              Move {if @snoozing.in_progress == 1, do: "it", else: "them"} back to {@snoozing.ready.name}?
            </span>
          </label>
          <p :if={@snoozing.due} id="snooze-due" class="text-xs text-base-content/60">
            Due {Calendar.strftime(@snoozing.due, "%a %-d %b")}: a later day snoozes it past its due date.
          </p>
          <p :if={@snoozing.error} id="snooze-error" class="text-xs text-error">{@snoozing.error}</p>
        </.form>
      </div>
    </div>
    """
  end

  attr :column, Column, required: true
  attr :snoozed, :list, required: true
  attr :revealed, :boolean, required: true

  @doc "A list's \"N snoozed\" footer, which shows them in place, faded, and hides them again."
  def snoozed_footer(assigns) do
    ~H"""
    <button
      :if={@snoozed != []}
      type="button"
      id={"snoozed-#{@column.id}"}
      phx-click="toggle_snoozed"
      phx-value-id={@column.id}
      class="block w-full px-1 py-1 text-center text-2xs text-base-content/60 hover:text-base-content"
    >
      💤 {length(@snoozed)} snoozed{if @revealed, do: " · hide", else: ""}
    </button>
    """
  end
end
