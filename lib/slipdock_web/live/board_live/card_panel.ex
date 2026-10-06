defmodule SlipdockWeb.BoardLive.CardPanel do
  @moduledoc """
  The card panel's markup, part one: the top of the panel (title, list,
  flags, tags, description), its attachments, and the sidebar. The panel is
  `BoardLive.CardComponent`; these draw what it holds, and send their events
  to it (`target`). Part two is `BoardLive.CardSections`.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.ItemComponents
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Boards, Dates, Palette}
  alias Slipdock.Boards.{Attachment, Card}
  alias SlipdockWeb.RichText

  attr :board, :any, required: true
  attr :can_write, :boolean, required: true
  attr :card, Card, required: true
  attr :current_user, :any, default: nil
  attr :editing_description, :boolean, required: true
  attr :form, :any, required: true
  attr :mention_people, :string, default: nil
  attr :tags_path, :string, required: true
  attr :target, :any, required: true
  attr :uploads, :map, required: true

  @doc "The top of the panel: the title, its list, flags, tags and the description."
  def card_header_form(assigns) do
    ~H"""
    <.form
      phx-target={@target}
      for={@form}
      id="card-form"
      phx-change="card_change"
      phx-submit="card_change"
      class="space-y-3"
    >
      <div class="flex items-start gap-3 pr-8">
        <button
          type="button"
          class={[
            "mt-1.5 shrink-0",
            if(@card.completed,
              do: "text-success",
              else: "text-base-content/30 hover:text-success"
            )
          ]}
          phx-click="toggle_complete"
          phx-value-id={@card.id}
          title={if @card.completed, do: "Mark incomplete", else: "Mark complete"}
        >
          <.icon
            name={if @card.completed, do: "hero-check-circle-solid", else: "hero-check-circle"}
            class="size-6"
          />
        </button>
        <textarea
          name={@form[:title].name}
          id="card-title"
          rows="1"
          phx-debounce="500"
          phx-hook="AutoGrow"
          data-single-line
          class={[
            "w-full resize-none rounded-lg bg-transparent px-1 text-xl font-bold leading-tight outline-none ring-primary/40 focus:bg-base-200/60 focus:ring-2 sm:text-2xl",
            @card.completed && "opacity-60"
          ]}
          placeholder="Card title"
        >{@form[:title].value}</textarea>
      </div>
      <p :if={@form[:title].errors != []} class="text-sm text-error">Title can't be blank.</p>
      <div class="flex flex-wrap items-center gap-x-1.5 px-1 text-sm text-base-content/50">
        <%!-- A link, not a button: this sits in the fieldset that is
              disabled for a read-only card, and a reader can share a link
              too. The hook copies the URL instead of following it. --%>
        <a
          id="card-copy-link"
          href={url(~p"/boards/#{@card.board_id}/cards/#{@card.id}")}
          phx-hook="CopyLink"
          class="badge badge-ghost badge-sm gap-1 font-mono text-base-content/70 hover:text-primary"
          title="Copy a link to this card"
        >
          <span data-label>#{@card.id}</span>
          <.icon name="hero-link" class="size-3" />
        </a>
        <span>in list</span>
        <%!-- The quickest way to move a card, and the only practical one
              on a phone, where dragging it across a board that shows one
              list at a time is no way to live. The sidebar keeps its own
              copy of this field; `card_change` touches only what the form
              it came from carried. --%>
        <select
          :if={@can_write}
          name="card[column_id]"
          class="select select-ghost select-sm w-auto max-w-[12rem] pl-1 font-medium text-base-content/80"
          title="Move this card to another list"
          aria-label="List"
        >
          <option
            :for={{name, id} <- column_options(@board)}
            value={id}
            selected={id == @card.column_id}
          >
            {name}
          </option>
        </select>
        <span :if={!@can_write} class="font-medium text-base-content/80">
          {@card.column.name}
        </span>
        <%!-- `type="button"` matters: this sits inside the card form. --%>
        <button
          :if={@can_write}
          type="button"
          id="card-move-board"
          phx-click="open_move_board"
          phx-target="#board-move"
          phx-value-id={@card.id}
          class="link link-hover text-base-content/60 hover:text-primary"
          title="Move this card to another board, with its subcards"
        >
          another board…
        </button>
        <span>· created {relative_time(@card.inserted_at)}</span>
      </div>

      <div class="space-y-1.5 px-1 pt-2" data-section-key="f">
        <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
          <.keyed_label key="f" label="Flags" />
        </p>
        <div class="flex flex-wrap gap-1.5">
          <.flag_toggle
            :for={{flag, _, _, _, _} <- flags()}
            phx-target={@target}
            flag={flag}
            active={flag in @card.flags}
            phx-click="toggle_flag"
            phx-value-flag={flag}
          />
        </div>
      </div>

      <div class="space-y-1.5 px-1" data-section-key="t">
        <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
          <.keyed_label key="t" label="Tags" />
        </p>
        <div class="flex flex-wrap items-center gap-1.5">
          <.tag_toggle
            :for={tag <- @board.tags}
            phx-target={@target}
            tag={tag}
            active={Enum.any?(@card.tags, &(&1.id == tag.id))}
            phx-click="toggle_tag"
            phx-value-id={tag.id}
          />
          <.link patch={@tags_path} class="btn btn-ghost btn-xs">
            <.icon name="hero-plus" class="size-3.5" /> New tag
          </.link>
        </div>
      </div>

      <div class="space-y-1.5 px-1" data-section-key="d">
        <div class="flex items-center justify-between">
          <label
            for="card-description"
            class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60"
          >
            <.icon name="hero-bars-3-bottom-left" class="size-3.5" />
            <.keyed_label key="d" label="Description" />
          </label>
          <button
            :if={@can_write and not @editing_description and (@card.description || "") != ""}
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="edit_description"
          >
            <.icon name="hero-pencil" class="size-3.5" /> Edit
          </button>
          <button
            :if={@editing_description}
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="stop_editing_description"
          >
            <.icon name="hero-check" class="size-3.5" /> Done
          </button>
        </div>
        <div
          :if={@editing_description}
          id="card-description-paste"
          phx-hook="PasteImage"
          data-upload="desc_image"
          class="space-y-1"
        >
          <div
            id="card-description-mention"
            phx-hook="Mention"
            data-people={@mention_people}
          >
            <textarea
              phx-target={@target}
              id="card-description"
              name={@form[:description].name}
              phx-debounce="700"
              phx-hook="AutoGrow"
              phx-keydown="stop_editing_description"
              phx-key="Escape"
              autofocus
              rows="3"
              placeholder="Add more detail…"
              class="textarea w-full resize-none text-sm leading-relaxed"
            >{@form[:description].value}</textarea>
          </div>
          <.live_file_input upload={@uploads.desc_image} class="hidden" />
          <p class="text-2xs text-base-content/60">
            Paste or drop an image to add it; type @ to mention somebody. Click Done or press Escape when finished.
          </p>
        </div>
        <div
          :if={not @editing_description and (@card.description || "") != ""}
          phx-target={@target}
          id="card-description-view"
          class={[
            "rounded-lg px-1 py-1 text-sm leading-relaxed whitespace-pre-wrap break-words",
            @can_write && "cursor-text hover:bg-base-200/60"
          ]}
          phx-click={@can_write && "edit_description"}
          phx-no-format
        >{RichText.render(@card.description, board: @board, as: @current_user)}</div>
        <button
          :if={not @editing_description and (@card.description || "") == "" and @can_write}
          phx-target={@target}
          type="button"
          class="w-full rounded-lg bg-base-200/60 px-3 py-2 text-left text-sm text-base-content/50 hover:bg-base-200"
          phx-click="edit_description"
        >
          Add more detail…
        </button>
        <p
          :if={not @editing_description and (@card.description || "") == "" and not @can_write}
          class="px-1 text-sm italic text-base-content/40"
        >
          No description.
        </p>
      </div>
    </.form>
    """
  end

  attr :can_write, :boolean, required: true
  attr :card, Card, required: true
  attr :target, :any, required: true
  attr :uploads, :map, required: true

  @doc "The card's files, and the uploads under way."
  def attachments_section(assigns) do
    ~H"""
    <section
      id="card-attachments"
      class="space-y-2 rounded-xl px-1 transition-colors"
      phx-drop-target={@uploads.attachment.ref}
      data-section-key="a"
    >
      <div class="flex items-center justify-between">
        <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
          <.icon name="hero-paper-clip" class="size-3.5" />
          <.keyed_label key="a" label="Attachments" />
          <span :if={@card.attachments != []} class="font-normal">({length(@card.attachments)})</span>
        </h3>
        <form
          :if={@can_write}
          phx-target={@target}
          id="attach-form"
          phx-change="validate_attachments"
          phx-submit="validate_attachments"
        >
          <label class="btn btn-ghost btn-xs cursor-pointer">
            <.icon name="hero-arrow-up-tray" class="size-3.5" /> Attach
            <.live_file_input upload={@uploads.attachment} class="hidden" />
          </label>
        </form>
      </div>
      <ul :if={@card.attachments != []} class="grid grid-cols-1 gap-2 sm:grid-cols-2">
        <li
          :for={a <- @card.attachments}
          id={"attachment-#{a.id}"}
          class="group flex items-center gap-3 rounded-xl bg-base-200/70 p-2"
        >
          <a
            href={Boards.attachment_url(a)}
            target="_blank"
            rel="noopener"
            class="flex size-12 shrink-0 items-center justify-center overflow-hidden rounded-lg bg-base-300/60"
            title={a.filename}
          >
            <img
              :if={Attachment.image?(a)}
              src={Boards.attachment_url(a)}
              alt={a.filename}
              loading="lazy"
              class="size-full object-cover"
            />
            <.icon
              :if={not Attachment.image?(a)}
              name={attachment_icon(a)}
              class="size-6 text-base-content/50"
            />
          </a>
          <div class="min-w-0 flex-1">
            <a
              href={Boards.attachment_url(a)}
              target="_blank"
              rel="noopener"
              class="block truncate text-sm font-medium hover:underline"
            >
              {a.filename}
            </a>
            <p class="text-xs text-base-content/50">
              {human_size(a.size)} · {relative_time(a.inserted_at)}
            </p>
          </div>
          <button
            :if={@can_write}
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-xs btn-square shrink-0 opacity-0 group-hover:opacity-100 focus:opacity-100 no-hover:opacity-100"
            phx-click="delete_attachment"
            phx-value-id={a.id}
            data-confirm={"Delete #{a.filename}?"}
            title="Delete attachment"
          >
            <.icon name="hero-trash" class="size-3.5" />
          </button>
        </li>
      </ul>
      <div
        :for={entry <- @uploads.attachment.entries}
        id={"upload-#{entry.ref}"}
        class="flex items-center gap-3 rounded-xl bg-base-200/40 px-3 py-2"
      >
        <.icon name="hero-arrow-up-tray" class="size-4 shrink-0 text-base-content/50" />
        <div class="min-w-0 flex-1 space-y-1">
          <p class="truncate text-xs">{entry.client_name}</p>
          <progress
            class="progress progress-primary h-1 w-full"
            value={entry.progress}
            max="100"
          ></progress>
        </div>
        <button
          phx-target={@target}
          type="button"
          class="btn btn-ghost btn-xs btn-square"
          phx-click="cancel_upload"
          phx-value-name="attachment"
          phx-value-ref={entry.ref}
          title="Cancel upload"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
      <p
        :if={@card.attachments == [] and @uploads.attachment.entries == [] and @can_write}
        class="text-xs text-base-content/40"
      >
        Drop files here, or paste images straight into the description or a comment.
      </p>
    </section>
    """
  end

  attr :board, :any, required: true
  attr :can_write, :boolean, required: true
  attr :card, Card, required: true
  attr :current_user, :any, default: nil
  attr :form, :any, required: true
  attr :form_key, :integer, required: true
  attr :target, :any, required: true
  attr :users, :list, required: true

  @doc "The panel's sidebar: list, assignees, priority, dates, health, time, fields, votes, cover and the card's actions."
  def card_sidebar(assigns) do
    ~H"""
    <aside class="min-w-0 space-y-5 rounded-b-2xl bg-base-200/60 p-5 md:rounded-r-2xl md:rounded-bl-none">
      <.form
        phx-target={@target}
        for={@form}
        id="card-meta-form"
        phx-change="card_change"
        class="space-y-4"
      >
        <label class="block space-y-1">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">List</span>
          <select name="card[column_id]" class="select select-sm w-full">
            <option
              :for={{name, id} <- column_options(@board)}
              value={id}
              selected={id == @card.column_id}
            >
              {name}
            </option>
          </select>
        </label>
        <div class="space-y-1" id="card-assignees">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Assignees
          </span>
          <ul :if={Card.assignees(@card) != []} class="flex flex-wrap gap-1">
            <li
              :for={u <- Card.assignees(@card)}
              id={"card-assignee-#{u.id}"}
              class="inline-flex items-center gap-1 rounded-full bg-base-200 py-0.5 pr-1 pl-0.5"
            >
              <.assignee_chip user={u} size="xs" with_name />
              <button
                phx-target={@target}
                type="button"
                phx-click="remove_assignee"
                phx-value-id={u.id}
                class="rounded-full p-0.5 text-base-content/50 transition hover:bg-base-300 hover:text-base-content"
                title={"Unassign #{Slipdock.Accounts.User.display_name(u)}"}
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            </li>
          </ul>
          <%!-- Keyed on who is already on the card, so the picker comes back
               empty after each pick instead of re-sending the last one. --%>
          <select
            name="card[add_assignee_id]"
            class="select select-sm w-full"
            id={"card-assignee-add-" <> Enum.map_join(Card.assignees(@card), "-", & &1.id)}
          >
            <option value="" selected>
              {if Card.assignees(@card) == [],
                do: "Unassigned — add someone…",
                else: "Add someone…"}
            </option>
            <option
              :for={u <- @users}
              :if={not Card.assigned_to?(@card, u.id)}
              value={u.id}
            >
              {Slipdock.Accounts.User.display_name(u)}
            </option>
          </select>
        </div>
        <label class="block space-y-1">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Priority</span>
          <select name="card[priority]" class="select select-sm w-full">
            <option
              :for={{label, value} <- priority_options()}
              value={value}
              selected={value == @card.priority}
            >
              {label}
            </option>
          </select>
        </label>
        <%!-- A simple board is a to-do list: what follows down to Health,
              bar the due date and Completed, is project tracking, and
              stays out of its way (`Board.simple?/1`). --%>
        <label :if={not @board.simple} class="block space-y-1">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">% complete</span>
          <div class="flex items-center gap-2">
            <input
              type="number"
              name="card[percent_complete]"
              id="card-percent-complete"
              value={@card.percent_complete}
              min="0"
              max="100"
              step="5"
              placeholder="—"
              phx-debounce="400"
              class="input input-sm w-20"
            />
            <progress
              :if={@card.percent_complete}
              class={[
                "progress h-1.5 flex-1",
                if(@card.percent_complete == 100,
                  do: "progress-success",
                  else: "progress-primary"
                )
              ]}
              value={@card.percent_complete}
              max="100"
            ></progress>
          </div>
          <p :if={@form[:percent_complete].errors != []} class="text-xs text-error">
            Use a whole number from 0 to 100.
          </p>
        </label>
        <label :if={not @board.simple} class="block space-y-1">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Start date</span>
          <input
            type="date"
            name="card[start_date]"
            value={@card.start_date}
            max={@card.due_date}
            class="input input-sm w-full"
          />
        </label>
        <label class="block space-y-1">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Due date</span>
          <input
            type="date"
            name="card[due_date]"
            value={@card.due_date}
            min={@card.start_date}
            class="input input-sm w-full"
          />
          <.due_badge date={@card.due_date} completed={@card.completed} />
          <p :if={@form[:start_date].errors != []} class="text-xs text-error">
            Start must be on or before the due date.
          </p>
        </label>
        <label :if={not @board.simple} class="block space-y-1">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Precision</span>
          <select
            name="card[date_precision]"
            class="select select-sm w-full"
            id="card-precision"
          >
            <option
              :for={{key, label} <- Dates.precisions()}
              value={key}
              selected={key == (@card.date_precision || "day")}
            >
              {label}
            </option>
          </select>
          <p :if={Card.fuzzy?(@card) and @card.due_date} class="text-xs text-base-content/60">
            Scheduled for {Dates.range_label(
              @card.start_date || @card.due_date,
              @card.due_date,
              @card.date_precision
            )}
          </p>
        </label>
        <div
          :if={
            (not @board.simple and @card.rollup) && @card.rollup.children > 0 &&
              @card.rollup.derived_due
          }
          class="space-y-1 rounded-lg bg-base-200/60 p-2 text-xs"
          id="card-rollup-dates"
        >
          <p class="flex items-center gap-1 font-semibold uppercase tracking-wide text-base-content/60">
            <.icon name="hero-arrow-up-on-square-stack" class="size-3.5" /> From subcards
          </p>
          <p class="text-base-content/80">
            {fmt_date(@card.rollup.derived_start)} → {fmt_date(@card.rollup.derived_due)}
          </p>
          <p
            :if={@card.rollup.start_slip > 0}
            class="flex items-center gap-1 text-warning-content dark:text-warning"
          >
            <.icon name="hero-arrow-trending-up" class="size-3.5" />
            {past_date_label(:start, @card.rollup.start_slip)}
            <span class="text-base-content/50">(yours: {fmt_date(@card.start_date)})</span>
          </p>
          <p
            :if={@card.rollup.due_slip > 0}
            class="flex items-center gap-1 text-warning-content dark:text-warning"
          >
            <.icon name="hero-arrow-trending-up" class="size-3.5" />
            {past_date_label(:due, @card.rollup.due_slip)}
            <span class="text-base-content/50">(yours: {fmt_date(@card.due_date)})</span>
          </p>
          <p :if={is_nil(@card.due_date)} class="text-base-content/50">
            No due date of its own, so the subcards set it.
          </p>
        </div>
        <p
          :if={Card.days_past_due(@card) > 0}
          class="flex items-center gap-1 rounded-lg bg-error/10 p-2 text-xs text-error"
          id="card-past-due"
        >
          <.icon name="hero-exclamation-triangle" class="size-3.5" />
          This card is {past_date_label(:due, Card.days_past_due(@card))}
        </p>
        <label class="flex cursor-pointer items-center justify-between">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Completed</span>
          <input type="hidden" name="card[completed]" value="false" />
          <input
            type="checkbox"
            name="card[completed]"
            value="true"
            class="toggle toggle-success toggle-sm"
            checked={@card.completed}
          />
        </label>
        <div :if={not @board.simple} class="space-y-1.5" id="card-status">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Health</span>
          <div class="flex flex-wrap items-center gap-1.5">
            <.health_pill health={Card.health(@card)} />
            <.stated_pill
              :if={Card.stated_health(@card)}
              health={Card.stated_health(@card)}
              title="Reported by the card's owner"
            />
          </div>
          <p class="text-xs text-base-content/50">
            The first pill is computed from dates, blockers and subcards; the second is
            what was last reported.
          </p>
        </div>
      </.form>
      <.time_section
        :if={not @board.simple}
        target={@target}
        card={@card}
        can_write={@can_write}
        form_key={@form_key}
      />
      <.status_section
        :if={not @board.simple}
        target={@target}
        item={@card}
        can_write={@can_write}
        form_key={@form_key}
        stated={Card.stated_health(@card)}
      />
      <.fields_section target={@target} item={@card} board={@board} can_write={@can_write} />
      <.vote_box
        :if={not @board.simple}
        target={@target}
        item={@card}
        board={@board}
        current_user={@current_user}
        can_write={@can_write}
      />

      <div class="space-y-1.5">
        <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Cover</span>
        <div class="flex flex-wrap gap-1.5">
          <button
            phx-target={@target}
            type="button"
            class={[
              "flex size-6 items-center justify-center rounded-full ring-1 ring-base-content/20 ring-offset-2 ring-offset-base-100",
              is_nil(@card.color) && "ring-2 ring-base-content"
            ]}
            phx-click="set_cover"
            phx-value-color=""
            title="No cover"
          >
            <.icon name="hero-no-symbol" class="size-3.5 opacity-50" />
          </button>
          <.color_swatch
            :for={{name, _} <- Palette.all()}
            phx-target={@target}
            color={name}
            selected={@card.color == name}
            phx-click="set_cover"
            phx-value-color={name}
          />
        </div>
      </div>

      <div class="space-y-1.5 border-t border-base-content/10 pt-4">
        <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Actions</span>
        <button
          phx-target={@target}
          type="button"
          class="btn btn-sm w-full justify-start"
          phx-click="archive_card"
        >
          <.icon name="hero-archive-box" class="size-4" /> Archive
        </button>
        <button
          phx-target={@target}
          type="button"
          class="btn btn-ghost btn-sm w-full justify-start text-error"
          phx-click="delete_card"
          data-confirm="Delete this card permanently?"
        >
          <.icon name="hero-trash" class="size-4" /> Delete
        </button>
      </div>
    </aside>
    """
  end
end
