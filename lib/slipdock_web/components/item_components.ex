defmodule SlipdockWeb.ItemComponents do
  @moduledoc """
  The sections a card and a wiki page both have: a checklist, comments,
  status updates, votes, web links and custom field values.

  These were the card panel's own markup until a page grew the same contents
  (one table each, one row belonging to exactly one of the two — see
  `Slipdock.Boards.Owned`). They take `item`, which is a `Slipdock.Boards.Card`
  or a `Slipdock.Wiki.Page`, and never ask which: the associations line up by
  name, and so do the events the panels handle.

  `target` is the LiveComponent the sections' events go to, when the panel
  is one (the board's card and page panels are); without it they go to the
  LiveView.

  `form_key` is the counter the panels bump to clear a form after it submits;
  `section_key` is the keyboard shortcut letter, and is left out where the
  page's own view draws these and the shortcuts do not apply.

  The DOM ids below are keyed by the item, because a card's panel and a
  placed page's panel can both be open at once (`?card_id=…&page=…`) and two
  elements with one id is a bug that only shows up on the day someone does
  that.
  """
  use Phoenix.Component
  alias SlipdockWeb.Dates

  import SlipdockWeb.CoreComponents
  import SlipdockWeb.SlipdockComponents, only: [keyed_label: 1, stated_pill: 1, timestamp: 1]

  alias Slipdock.Boards.{CardUrl, FieldDefinition}
  alias Slipdock.Boards.StatusUpdate
  alias Slipdock.Fields
  alias Slipdock.{Boards, Votes}
  alias SlipdockWeb.RichText

  attr :notice, :any,
    required: true,
    doc: "`{kind, message}` from `BoardLive.Helpers.notice/3`, or nil"

  attr :class, :any, default: nil

  @doc """
  What the panel's last action said (a refusal, a result), at the panel's
  top. A callout, never a flash: the toast's dismissal reads as a click-away
  and closes the modal (UX-29).
  """
  def panel_notice(%{notice: {kind, message}} = assigns) do
    assigns = assign(assigns, kind: kind, message: message)

    ~H"""
    <.callout id="panel-notice" kind={@kind} class={@class}>{@message}</.callout>
    """
  end

  def panel_notice(assigns), do: ~H""

  attr :target, :any, default: nil, doc: "the LiveComponent the events go to"
  attr :item, :any, required: true
  attr :can_write, :boolean, required: true
  attr :form_key, :integer, default: 0
  attr :section_key, :string, default: nil

  @doc "The tick boxes on a card or a page, with their progress."
  def checklist_section(assigns) do
    {done, total, pct} = progress(assigns.item.checklist_items)
    assigns = assign(assigns, done: done, total: total, pct: pct)

    ~H"""
    <section class="space-y-2 px-1" data-section-key={@section_key}>
      <div class="flex items-center justify-between">
        <h3 class="flex items-center gap-1.5 section-label">
          <.icon name="hero-clipboard-document-check" class="size-3.5" />
          <.keyed_label :if={@section_key} key={@section_key} label="Checklist" />
          <span :if={is_nil(@section_key)}>Checklist</span>
        </h3>
        <span :if={@total > 0} class="text-xs text-base-content/50">{@done}/{@total} · {@pct}%</span>
      </div>
      <progress
        :if={@total > 0}
        class={[
          "progress h-1.5 w-full",
          if(@pct == 100, do: "progress-success", else: "progress-primary")
        ]}
        value={@done}
        max={@total}
      ></progress>
      <%!-- Dragged by the handle into a new order (#1752); the group is the
           item's own, so an item never lands on another checklist. --%>
      <ul
        id={dom_id("checklist-items", @item)}
        class="space-y-1"
        phx-hook="Sortable"
        data-group={dom_id("checklist", @item)}
        data-event="move_check"
        data-push-to="self"
        data-handle=".check-handle"
        data-disabled={to_string(not @can_write)}
      >
        <li
          :for={item <- @item.checklist_items}
          id={"check-#{item.id}"}
          data-id={item.id}
          class="group flex items-center gap-2 rounded-lg px-1 py-1 hover:bg-base-200/60"
        >
          <span
            :if={@can_write}
            class="check-handle cursor-grab text-base-content/30 hover:text-base-content/70 active:cursor-grabbing"
            title="Drag to reorder"
            aria-hidden="true"
          >
            <.icon name="hero-bars-2" class="size-3.5" />
          </span>
          <input
            phx-target={@target}
            type="checkbox"
            class="checkbox"
            checked={item.done}
            disabled={not @can_write}
            phx-click="toggle_check"
            phx-value-id={item.id}
          />
          <span class={["flex-1 text-sm", item.done && "line-through text-base-content/50"]}>{item.text}</span>
          <button
            :if={@can_write}
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-xs btn-square opacity-0 group-hover:opacity-100 no-hover:opacity-100"
            phx-click="delete_check"
            phx-value-id={item.id}
            title="Remove"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </li>
      </ul>
      <form
        :if={@can_write}
        phx-target={@target}
        id={dom_id("add-check-#{@form_key}", @item)}
        phx-submit="add_check"
        class="flex gap-2"
      >
        <input
          type="text"
          name="text"
          placeholder="Add an item…"
          class="input field flex-1"
          autocomplete="off"
          required
        />
        <button type="submit" class="btn btn-sm">Add</button>
      </form>
    </section>
    """
  end

  # A card keeps the plain ids it has always had; a page's are suffixed.
  defp dom_id(name, %Slipdock.Wiki.Page{id: id}), do: "#{name}-page-#{id}"
  defp dom_id(name, _card), do: name

  @doc "How far through a checklist is: `{done, total, percent}`."
  def progress([]), do: {0, 0, 0}

  def progress(items) do
    total = length(items)
    done = Enum.count(items, & &1.done)
    {done, total, round(done / total * 100)}
  end

  attr :target, :any, default: nil, doc: "the LiveComponent the events go to"
  attr :item, :any, required: true
  attr :can_write, :boolean, required: true
  attr :form_key, :integer, default: 0
  attr :section_key, :string, default: nil

  @doc "Links out of the system, on a card or a page."
  def urls_section(assigns) do
    ~H"""
    <section class="space-y-2 px-1" id={dom_id("card-urls", @item)} data-section-key={@section_key}>
      <h3 class="flex items-center gap-1.5 section-label">
        <.icon name="hero-globe-alt" class="size-3.5" />
        <.keyed_label :if={@section_key} key={@section_key} label="Web links" />
        <span :if={is_nil(@section_key)}>Web links</span>
        <span :if={@item.urls != []} class="font-normal">({length(@item.urls)})</span>
      </h3>
      <ul :if={@item.urls != []} class="space-y-1">
        <li :for={url <- @item.urls} id={"card-url-#{url.id}"} class="flex items-center gap-2 text-xs">
          <.icon name={url_icon(url)} class="size-3.5 shrink-0 text-base-content/50" />
          <a
            href={url.url}
            target="_blank"
            rel="noopener noreferrer"
            class="min-w-0 flex-1 truncate hover:underline"
            title={url.url}
          >
            {CardUrl.label(url)}
          </a>
          <span
            class="shrink-0 text-2xs text-base-content/50"
            title={"Added #{Dates.exact(url.inserted_at)}"}
          >
            {Dates.long(url.inserted_at)}
          </span>
          <button
            :if={@can_write}
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="remove_card_url"
            phx-value-id={url.id}
            title="Remove link"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </li>
      </ul>
      <p :if={@item.urls == []} class="px-1 text-xs text-base-content/50">
        Nothing linked yet — a page, a shared drive, a file somewhere else.
      </p>
      <form
        :if={@can_write}
        phx-target={@target}
        id={dom_id("card-url-form-#{@form_key}", @item)}
        phx-submit="add_card_url"
        class="flex gap-1"
      >
        <input
          type="text"
          name="url"
          placeholder="https://… , file://… or an address"
          class="input field min-w-0 flex-1"
          autocomplete="off"
        />
        <input
          type="text"
          name="title"
          placeholder="Label (optional)"
          class="input field w-32 shrink-0"
          autocomplete="off"
        />
        <button type="submit" class="btn btn-sm shrink-0">Add</button>
      </form>
    </section>
    """
  end

  @doc "The icon for the kind of thing a link points at."
  def url_icon(url) do
    case CardUrl.kind(url) do
      :mail -> "hero-envelope"
      :file -> "hero-folder"
      _ -> "hero-link"
    end
  end

  attr :field, FieldDefinition, required: true
  attr :item, :any, required: true, doc: "the card or page whose value it edits"
  attr :can_write, :boolean, required: true
  attr :id, :string, required: true, doc: "the form's (or the stars' row's) DOM id"
  attr :event, :string, default: "set_field"
  attr :target, :any, default: nil, doc: "the LiveComponent the event goes to"

  attr :params, :list,
    default: [],
    doc: "more `{name, value}` the event carries beside `field_id` and `value`"

  attr :look, :atom,
    values: [:boxed, :bare],
    default: :boxed,
    doc: "`:boxed` fills a panel's column; `:bare` edits in place in a table row"

  @doc """
  One custom field's value, edited in place: the stars of a rating, a
  select, a number, a date or text. The card and page panels
  (`fields_section/1`) and the Prioritise table both draw their fields with
  it, so the two can't drift (#2878).

  Every kind sends `event` with `field_id`, `value` ("" clears it) and each
  of `params` (the table adds `card_id`). Without `can_write`, or for a
  formula, it shows the value as `Slipdock.Fields.format/2` writes it.

  A number honours the field's `step`, `min` and `max`, and shows a whole
  float without its `.0`. In the `:boxed` look its unit is the placeholder
  and a typed value saves after 600ms; in the `:bare` look the unit is a
  suffix in the box ("4000 people", "80%") and a value saves when the box
  is left, since a save re-ranks the table's rows under the cursor.
  """
  def field_input(%{can_write: false} = assigns), do: field_value(assigns)
  def field_input(%{field: %{kind: "formula"}} = assigns), do: field_value(assigns)

  def field_input(%{field: %{kind: "rating"}} = assigns) do
    assigns =
      assign(assigns,
        value: Fields.value(assigns.item, assigns.field),
        max: FieldDefinition.rating_max(assigns.field),
        values: for({k, v} <- assigns.params, do: {"phx-value-#{k}", v})
      )

    ~H"""
    <div class="flex items-center gap-0.5" id={@id}>
      <button
        :for={n <- 1..@max//1}
        phx-target={@target}
        type="button"
        class={[
          "leading-none transition hover:scale-110",
          if(@look == :bare, do: "text-sm", else: "text-base"),
          if(is_number(@value) and n <= @value, do: "text-amber-500", else: "text-base-content/25")
        ]}
        phx-click={@event}
        phx-value-field_id={@field.id}
        value={n}
        title={"#{n} of #{@max}"}
        {@values}
      >
        ★
      </button>
      <button
        :if={is_number(@value)}
        phx-target={@target}
        type="button"
        class="btn btn-ghost btn-xs btn-square"
        phx-click={@event}
        phx-value-field_id={@field.id}
        value=""
        title="Clear"
        {@values}
      >
        <.icon name="hero-x-mark" class="size-3" />
      </button>
    </div>
    """
  end

  def field_input(assigns) do
    value = Fields.value(assigns.item, assigns.field)
    config = assigns.field.config || %{}
    unit = config["unit"] |> to_string() |> String.trim()

    assigns =
      assign(assigns,
        value: field_input_value(value),
        config: config,
        unit: unit,
        debounce: if(assigns.look == :bare, do: "blur", else: "600")
      )

    ~H"""
    <form
      phx-target={@target}
      phx-change={@event}
      phx-submit={@event}
      id={@id}
      class={@look == :bare && "flex items-center"}
    >
      <input :for={{k, v} <- @params} type="hidden" name={k} value={v} />
      <input type="hidden" name="field_id" value={@field.id} />
      <%= case {@field.kind, @look} do %>
        <% {"number", :boxed} -> %>
          <input
            type="number"
            name="value"
            value={@value}
            step={@config["step"] || "any"}
            min={@config["min"]}
            max={@config["max"]}
            placeholder={@config["unit"]}
            aria-label={@field.name}
            class="input field w-full"
            phx-debounce={@debounce}
          />
        <% {"number", :bare} -> %>
          <label class="prio-number field-bare">
            <input
              type="number"
              name="value"
              value={@value}
              step={@config["step"] || "any"}
              min={@config["min"]}
              max={@config["max"]}
              phx-debounce={@debounce}
              style={"--prio-chars: #{chars(@value)}"}
              aria-label={@field.name}
              placeholder="—"
            />
            <span
              :if={@unit != ""}
              data-unit
              class={["prio-unit", Fields.tight_unit?(@unit) && "prio-unit-tight"]}
            >
              {@unit}
            </span>
          </label>
        <% {"select", look} -> %>
          <select
            name="value"
            aria-label={@field.name}
            class={["select", if(look == :bare, do: "field-bare w-28", else: "field w-full")]}
          >
            <option value="" selected={is_nil(@value)}>—</option>
            <option :for={o <- @field.options} value={o["key"]} selected={o["key"] == @value}>
              {o["label"]}
            </option>
          </select>
        <% {"date", look} -> %>
          <.date_field
            id={"#{@id}-date"}
            name="value"
            value={@value}
            bare={look == :bare}
            placeholder={if(look == :bare, do: "—", else: "Add date")}
            aria-label={@field.name}
            class={if(look == :bare, do: "w-32", else: "w-full")}
          />
        <% {_text, look} -> %>
          <input
            type="text"
            name="value"
            value={@value}
            aria-label={@field.name}
            class={
              if(look == :bare, do: "input field-bare prio-input w-36", else: "input field w-full")
            }
            placeholder={look == :bare && "—"}
            phx-debounce={@debounce}
          />
      <% end %>
    </form>
    """
  end

  defp field_value(assigns) do
    assigns =
      assign(assigns,
        text: Fields.format(assigns.field, Fields.value(assigns.item, assigns.field)) || "—"
      )

    ~H"""
    <span :if={@look == :bare}>{@text}</span>
    <p :if={@look == :boxed} class="text-xs">{@text}</p>
    """
  end

  # A whole float shows without its ".0": 4000, not 4000.0.
  defp field_input_value(n) when is_float(n) and n == trunc(n), do: trunc(n)
  defp field_input_value(v), do: v

  # How wide a bare number box starts, in characters, where the browser
  # can't size it to what is typed (`field-sizing`): the value, or the
  # placeholder.
  defp chars(nil), do: 1
  defp chars(v), do: v |> to_string() |> String.length() |> max(1)

  attr :target, :any, default: nil, doc: "the LiveComponent the events go to"
  attr :item, :any, required: true
  attr :board, :any, required: true
  attr :current_user, :any, default: nil
  attr :can_write, :boolean, required: true

  attr :can_comment, :boolean,
    default: nil,
    doc: "may comment and take back their own comments (#863); defaults to `can_write`"

  attr :form_key, :integer, default: 0
  attr :section_key, :string, default: nil
  attr :uploads, :any, default: nil, doc: "when given, images can be pasted into a comment"

  attr :mention_people, :string,
    default: nil,
    doc: "when given (see `SlipdockWeb.Mention.people/1`), typing @ offers these people"

  @doc "The remarks on a card or a page, newest first."
  def comments_section(assigns) do
    # Looked up once for the list, not once per comment that mentions someone.
    assigns =
      assigns
      |> assign(
        :members,
        if(Enum.any?(assigns.item.comments, &RichText.mentions?(&1.body)),
          do: Slipdock.Wiki.Links.members(assigns.board)
        )
      )
      |> default_can_comment()

    ~H"""
    <section class="space-y-3 px-1" data-section-key={@section_key}>
      <h3 class="flex items-center gap-1.5 section-label">
        <.icon name="hero-chat-bubble-left" class="size-3.5" />
        <.keyed_label :if={@section_key} key={@section_key} label="Comments" />
        <span :if={is_nil(@section_key)}>Comments</span>
        <span :if={@item.comments != []} class="font-normal">({length(@item.comments)})</span>
      </h3>
      <form
        :if={@can_comment}
        phx-target={@target}
        id={dom_id("add-comment-#{@form_key}", @item)}
        phx-submit="add_comment"
        phx-change="comment_change"
        class="space-y-2"
      >
        <div
          id={dom_id("comment-paste-#{@form_key}", @item)}
          phx-hook={@uploads && "PasteImage"}
          data-upload="comment_image"
        >
          <div
            id={dom_id("comment-mention-#{@form_key}", @item)}
            phx-hook={@mention_people && "Mention"}
            data-people={@mention_people}
          >
            <%!-- Typing [[ offers the wiki's pages (PageLink). --%>
            <div
              id={dom_id("comment-page-link-#{@form_key}", @item)}
              phx-hook="PageLink"
              data-board={@item.board_id}
            >
              <div
                id={dom_id("comment-editor-#{@form_key}", @item)}
                phx-hook="MarkdownEditor"
                phx-update="ignore"
                data-editor-class="md-editor-field"
              >
                <textarea
                  name="body"
                  rows="2"
                  placeholder={
                    if @uploads,
                      do: "Write a comment… (paste an image to attach it)",
                      else: "Write a comment…"
                  }
                  class="textarea field w-full"
                  required
                ></textarea>
              </div>
            </div>
          </div>
          <.live_file_input :if={@uploads} upload={@uploads.comment_image} class="hidden" />
        </div>
        <div class="flex justify-end">
          <button type="submit" class="btn btn-primary btn-sm">Comment</button>
        </div>
      </form>
      <ul class="space-y-3">
        <li :for={comment <- @item.comments} id={"comment-#{comment.id}"} class="group flex gap-3">
          <SlipdockWeb.SlipdockComponents.avatar
            user={comment_user(comment)}
            size="md"
            title={comment_author(comment)}
          />
          <div class="min-w-0 flex-1 rounded-xl bg-base-200/70 px-3 py-2">
            <div class="flex items-center justify-between gap-2">
              <span class="text-xs text-base-content/50">
                <span :if={comment_author(comment)} class="font-semibold text-base-content/70">
                  {comment_author(comment)}
                </span>
                <.timestamp at={comment.inserted_at} id={"comment-#{comment.id}-at"} />
              </span>
              <button
                :if={@can_write or (@can_comment and own?(comment, @current_user))}
                phx-target={@target}
                type="button"
                class="btn btn-ghost btn-xs btn-square opacity-0 group-hover:opacity-100 no-hover:opacity-100"
                phx-click="delete_comment"
                phx-value-id={comment.id}
                data-confirm="Delete this comment?"
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
            </div>
            <div class="card-prose break-words text-sm" phx-no-format>{RichText.markdown(comment.body, board: @board, as: @current_user, members: @members)}</div>
          </div>
        </li>
      </ul>
      <p :if={@item.comments == []} class="px-1 text-xs text-base-content/50">
        Nothing said yet.
      </p>
    </section>
    """
  end

  attr :target, :any, default: nil, doc: "the LiveComponent the events go to"
  attr :item, :any, required: true
  attr :can_write, :boolean, required: true
  attr :can_comment, :boolean, default: nil, doc: "may post an update; defaults to `can_write`"
  attr :form_key, :integer, default: 0
  attr :stated, :any, default: nil, doc: "the latest reported health, when already to hand"

  @doc "Reported health, and the last few updates."
  def status_section(assigns) do
    assigns =
      assigns
      |> assign_new(:stated, fn -> Boards.Card.stated_health(assigns.item) end)
      |> default_can_comment()

    ~H"""
    <div class="space-y-1.5" id={dom_id("card-status-updates", @item)}>
      <span class="section-label">Status updates</span>
      <form
        :if={@can_comment}
        phx-target={@target}
        id={dom_id("status-form-#{@form_key}", @item)}
        phx-submit="add_status_update"
        class="space-y-1.5"
      >
        <div class="flex flex-wrap gap-1">
          <label :for={{key, label} <- StatusUpdate.healths()} class="cursor-pointer">
            <input
              type="radio"
              name="health"
              value={key}
              class="peer sr-only"
              required
              checked={key == @stated}
            />
            <span class="btn btn-xs btn-ghost peer-checked:btn-primary">{label}</span>
          </label>
        </div>
        <textarea
          name="body"
          rows="2"
          class="textarea field w-full"
          placeholder="What's happening? (optional)"
        ></textarea>
        <button type="submit" class="btn btn-primary btn-xs">Post update</button>
      </form>
      <ul :if={@item.status_updates != []} class="space-y-1.5">
        <li
          :for={u <- Enum.take(@item.status_updates, 5)}
          id={"status-update-#{u.id}"}
          class="rounded-lg bg-base-200/60 p-2 text-xs"
        >
          <div class="flex items-center gap-1.5">
            <.stated_pill health={u.health} />
            <.timestamp
              at={u.inserted_at}
              id={"status-update-#{u.id}-at"}
              class="text-base-content/50"
            />
            <button
              :if={@can_write}
              phx-target={@target}
              type="button"
              class="btn btn-ghost btn-xs btn-square ml-auto"
              phx-click="delete_status_update"
              phx-value-id={u.id}
              title="Remove this update"
            >
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </div>
          <div
            :if={u.body}
            id={"status-update-#{u.id}-body"}
            class="card-prose mt-1 break-words text-base-content/80"
            phx-no-format
          >{RichText.markdown(u.body)}</div>
        </li>
      </ul>
    </div>
    """
  end

  attr :target, :any, default: nil, doc: "the LiveComponent the events go to"
  attr :item, :any, required: true
  attr :board, :any, required: true
  attr :can_write, :boolean, required: true

  @doc "The board's custom fields, with this card's or page's values."
  def fields_section(assigns) do
    ~H"""
    <div :if={@board.fields != []} class="space-y-2" id={dom_id("card-fields", @item)}>
      <span class="section-label">Fields</span>
      <div
        :for={field <- @board.fields}
        class="space-y-0.5"
        id={dom_id("card-field-#{field.id}", @item)}
      >
        <% value = Fields.value(@item, field) %>
        <div class="flex items-center justify-between gap-2 text-xs">
          <span class="text-base-content/70" title={"{#{field.key}}"}>{field.name}</span>
          <span :if={field.kind == "formula"} class="font-mono font-semibold" title="Computed">
            {Fields.format(field, value) || "—"}
          </span>
        </div>
        <.field_input
          :if={field.kind != "formula"}
          field={field}
          item={@item}
          can_write={@can_write}
          target={@target}
          id={dom_id("field-form-#{field.id}", @item)}
        />
      </div>
    </div>
    """
  end

  attr :target, :any, default: nil, doc: "the LiveComponent the events go to"
  attr :item, :any, required: true
  attr :board, :any, required: true
  attr :current_user, :any, default: nil
  attr :can_write, :boolean, required: true
  attr :can_comment, :boolean, default: nil, doc: "may vote; defaults to `can_write`"

  @doc """
  Budget voting on a card or a page. Both come out of the one budget, so the
  numbers below are the tree's, not this item's.
  """
  def vote_box(assigns) do
    {budget, per_card} = Votes.budget(assigns.board)
    user = assigns.current_user
    root_id = Boards.root_of_board(assigns.board.id)
    spent = if user, do: Votes.spent(user, root_id), else: 0
    mine = if user, do: Votes.mine(assigns.item, user), else: 0
    assigns = default_can_comment(assigns)

    assigns =
      assign(assigns,
        budget: budget,
        per_card: per_card,
        mine: mine,
        left: max(budget - spent, 0),
        total: Boards.Card.vote_total(assigns.item),
        can_add: mine < per_card and spent < budget and assigns.can_comment
      )

    ~H"""
    <div class="space-y-1.5" id={dom_id("card-votes", @item)}>
      <span class="section-label">Votes</span>
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span class="chip chip-line" title="Votes from everyone">
          <.icon name="hero-hand-thumb-up" class="size-3" /> {@total}
        </span>
        <div :if={@current_user} class="join" title="Your votes">
          <button
            phx-target={@target}
            type="button"
            class="btn btn-xs join-item"
            phx-click="vote"
            phx-value-count={@mine - 1}
            disabled={@mine == 0 or not @can_comment}
            aria-label="One vote fewer"
          >
            −
          </button>
          <span class="btn btn-xs join-item no-animation cursor-default font-mono">{@mine}</span>
          <button
            phx-target={@target}
            type="button"
            class="btn btn-xs join-item"
            phx-click="vote"
            phx-value-count={@mine + 1}
            disabled={not @can_add}
            aria-label="One more vote"
          >
            +
          </button>
        </div>
        <span class="text-base-content/50">
          {@left} of {@budget} left · up to {@per_card} per card
        </span>
      </div>
    </div>
    """
  end

  # Whoever may write may also join the discussion; a section given only
  # `can_write` takes that as its answer.
  defp default_can_comment(%{can_comment: nil, can_write: can_write} = assigns),
    do: assign(assigns, :can_comment, can_write)

  defp default_can_comment(assigns), do: assigns

  defp own?(%{user_id: id}, %Slipdock.Accounts.User{id: id}) when not is_nil(id), do: true
  defp own?(_comment, _user), do: false

  # Who wrote a comment: nil for one from before authors were kept, or one
  # the system wrote (see `Slipdock.Boards.Comment`).
  defp comment_author(%{user: %Slipdock.Accounts.User{} = u}),
    do: Slipdock.Accounts.User.display_name(u)

  defp comment_author(_), do: nil

  defp comment_user(%{user: %Slipdock.Accounts.User{} = u}), do: u
  defp comment_user(_), do: nil
end
