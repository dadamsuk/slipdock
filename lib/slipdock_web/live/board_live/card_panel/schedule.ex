defmodule SlipdockWeb.BoardLive.CardPanel.Schedule do
  @moduledoc """
  The card panel's Repeat and Snooze sections: how the card recurs and what
  is next, and until when it is snoozed. Drawn by `BoardLive.CardPanel`'s
  sidebar, which passes each the assigns it reads, by name.
  """
  use SlipdockWeb, :html

  alias Slipdock.Boards.Card

  attr :card, Card, required: true
  attr :can_write, :boolean, required: true
  attr :current_user, :any, default: nil

  # Snooze (W-1803): until when, and why; Snooze… opens the board's picker
  # and Wake now brings it back. Both are the board view's events, so they
  # carry no target.
  @doc false
  def snooze_section(assigns) do
    assigns =
      assign(assigns,
        snoozed: Card.snoozed?(assigns.card),
        zone: Slipdock.Timezones.of(assigns.current_user)
      )

    ~H"""
    <div
      :if={@snoozed or (@can_write and !@card.completed and !Card.stand_in?(@card))}
      id="card-snooze"
      class="space-y-2 border-t border-base-content/10 pt-4"
    >
      <div class="flex items-center gap-2">
        <span class="section-label">Snooze</span>
        <button
          :if={@can_write and !@card.completed}
          id="snooze-open"
          type="button"
          class="btn btn-ghost btn-xs ml-auto"
          phx-click="open_snooze"
          phx-value-id={@card.id}
          title="Hide it until a day (z on the board)"
        >
          {if @snoozed, do: "Change…", else: "Snooze…"}
        </button>
      </div>
      <div :if={@snoozed} id="snooze-current" class="space-y-1 text-sm">
        <p class="font-medium">
          💤 Until {SlipdockWeb.Dates.weekday(@card.snoozed_until, zone: @zone)}
        </p>
        <p :if={@card.snooze_note} class="text-xs text-base-content/60" id="snooze-note">
          {@card.snooze_note}
        </p>
        <button
          :if={@can_write}
          id="snooze-wake"
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="wake_card"
          phx-value-id={@card.id}
        >
          Wake now
        </button>
      </div>
    </div>
    """
  end

  attr :card, Card, required: true
  attr :current_user, :any, default: nil
  attr :repeat, :map, default: nil
  attr :target, :any, required: true

  # Repeat (W-1802): how the card recurs and what is next, or the Repeat…
  # form — presets for the card's date, a rule of one's own, the time, how
  # early, what a missed one does and when it ends — with what it would do
  # (in words, and the next three dates) before it is saved.
  @doc false
  def repeat_section(assigns) do
    assigns =
      assign(assigns,
        series: Card.recurrence(assigns.card),
        # The instance this one was copied from (#2081), for "why is it like this?".
        copied_from: Slipdock.Recurrence.copied_from(assigns.card, assigns.current_user)
      )

    ~H"""
    <div id="card-repeat" class="space-y-2 border-t border-base-content/10 pt-4">
      <div class="flex items-center gap-2">
        <span class="section-label">Repeat</span>
        <button
          :if={!@repeat}
          id="repeat-edit"
          type="button"
          class="btn btn-ghost btn-xs ml-auto"
          phx-click="edit_repeat"
          phx-target={@target}
        >
          {if @series, do: "Change…", else: "Repeat…"}
        </button>
      </div>

      <div :if={@series && !@repeat} id="repeat-current" class="space-y-1 text-sm">
        <p class="font-medium">↻ {Slipdock.Recurrence.Series.summary(@series)}</p>
        <p class="text-xs text-base-content/60" id="repeat-state">{repeat_state_line(@series)}</p>
        <div class="flex flex-wrap gap-1 pt-1">
          <button
            :if={@series.next_on && !@series.ended_at}
            id="repeat-skip"
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="skip_repeat"
            phx-target={@target}
          >
            Skip next
          </button>
          <button
            :if={!@series.ended_at}
            id="repeat-pause"
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="pause_repeat"
            phx-target={@target}
          >
            {if @series.paused, do: "Resume", else: "Pause"}
          </button>
          <button
            id="repeat-stop"
            type="button"
            class="btn btn-ghost btn-error btn-xs"
            phx-click="stop_repeat"
            phx-target={@target}
            data-confirm="Stop this card repeating? The ones made so far stay."
          >
            Stop
          </button>
        </div>
      </div>

      <p :if={@copied_from && !@repeat} id="repeat-copied-from" class="text-xs text-base-content/60">
        Copied from
        <.link
          navigate={~p"/boards/#{@copied_from.board_id}/cards/#{@copied_from.id}"}
          class="link"
        >
          #{@copied_from.id}
        </.link>
        {@copied_from.title}
      </p>

      <p :if={!@series && !@repeat && @card.series_id} class="text-xs text-base-content/50">
        An earlier instance of a recurring card: the series has moved on to a newer one.
      </p>

      <.form
        :if={@repeat}
        for={@repeat.form}
        id="repeat-form"
        phx-change="repeat_change"
        phx-submit="save_repeat"
        phx-target={@target}
        class="space-y-2"
      >
        <.input
          field={@repeat.form[:preset]}
          type="select"
          label="How often"
          options={
            Enum.map(@repeat.presets, fn {rule, label} -> {label, rule} end) ++
              [{"Custom…", "custom"}]
          }
        />
        <.input
          :if={@repeat.form[:preset].value == "custom"}
          field={@repeat.form[:custom]}
          label="Rule"
          placeholder="every 2w mon thu · month last fri · 3d after"
        />
        <div class="grid grid-cols-2 gap-2">
          <.input field={@repeat.form[:at]} type="time" label="At" />
          <.input
            field={@repeat.form[:lead_days]}
            type="number"
            min="0"
            max="365"
            label="Days early"
            placeholder="0"
          />
        </div>
        <.input
          field={@repeat.form[:on_missed]}
          type="select"
          label="If the last one is still open"
          options={[
            {"Move its due date on", "bump"},
            {"Skip this one", "skip"},
            {"Make another anyway", "stack"}
          ]}
        />
        <.input
          field={@repeat.form[:ends]}
          type="select"
          label="Ends"
          options={[{"Never", "never"}, {"On a date", "on"}, {"After a number of times", "after"}]}
        />
        <.date_field
          :if={@repeat.form[:ends].value == "on"}
          field={@repeat.form[:ends_on]}
          label="On"
          class="w-full"
        />
        <.input
          :if={@repeat.form[:ends].value == "after"}
          field={@repeat.form[:count]}
          type="number"
          min="1"
          label="Times in all"
        />

        <div :if={@repeat.preview} id="repeat-preview" class="rounded-lg bg-base-100 p-2 text-xs">
          <p class="font-medium" id="repeat-summary">{@repeat.preview.summary}</p>
          <p :if={@repeat.preview.dates != []} class="text-base-content/60" id="repeat-dates">
            Next: {Enum.map_join(@repeat.preview.dates, ", ", &SlipdockWeb.Dates.weekday(&1))}
          </p>
          <p :if={@repeat.preview.kind == :after_done} class="text-base-content/60">
            Counted from the day each one is done.
          </p>
        </div>
        <p :if={@repeat.error} id="repeat-error" class="text-xs text-error">{@repeat.error}</p>

        <div class="flex items-center gap-2">
          <button type="submit" class="btn btn-primary btn-xs">Save</button>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="cancel_repeat"
            phx-target={@target}
          >
            Cancel
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp repeat_state_line(series) do
    cond do
      series.ended_at ->
        "Ended."

      series.paused ->
        "Paused."

      series.next_on ->
        "Next due #{SlipdockWeb.Dates.weekday(series.next_on)}" <>
          ", made #{SlipdockWeb.Dates.datetime(series.next_at, zone: series.timezone)}."

      series.kind == "after_done" ->
        "The next is counted from when this one is done."

      true ->
        ""
    end
  end
end
