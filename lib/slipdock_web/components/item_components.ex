defmodule SlipdockWeb.ItemComponents do
  @moduledoc """
  The sections a card and a wiki page both have: a checklist, comments,
  status updates, votes, web links and custom field values.

  These were the card panel's own markup until a page grew the same contents
  (one table each, one row belonging to exactly one of the two — see
  `Slipdock.Boards.Owned`). They take `item`, which is a `Slipdock.Boards.Card`
  or a `Slipdock.Wiki.Page`, and never ask which: the associations line up by
  name, and so do the events the panels handle.

  `form_key` is the counter the panels bump to clear a form after it submits;
  `section_key` is the keyboard shortcut letter, and is left out where the
  page's own view draws these and the shortcuts do not apply.

  The DOM ids below are keyed by the item, because a card's panel and a
  placed page's panel can both be open at once (`?card_id=…&page=…`) and two
  elements with one id is a bug that only shows up on the day someone does
  that.
  """
  use Phoenix.Component

  import SlipdockWeb.CoreComponents
  import SlipdockWeb.SlipdockComponents, only: [keyed_label: 1, relative_time: 1, stated_pill: 1]

  alias Slipdock.Boards.{CardUrl, FieldDefinition}
  alias Slipdock.Boards.StatusUpdate
  alias Slipdock.Fields
  alias Slipdock.{Boards, Votes}
  alias SlipdockWeb.RichText

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
        <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
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
      <ul class="space-y-1">
        <li
          :for={item <- @item.checklist_items}
          id={"check-#{item.id}"}
          class="group flex items-center gap-2 rounded-lg px-1 py-1 hover:bg-base-200/60"
        >
          <input
            type="checkbox"
            class="checkbox checkbox-sm checkbox-success"
            checked={item.done}
            disabled={not @can_write}
            phx-click="toggle_check"
            phx-value-id={item.id}
          />
          <span class={["flex-1 text-sm", item.done && "line-through text-base-content/50"]}>{item.text}</span>
          <button
            :if={@can_write}
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
        id={dom_id("add-check-#{@form_key}", @item)}
        phx-submit="add_check"
        class="flex gap-2"
      >
        <input
          type="text"
          name="text"
          placeholder="Add an item…"
          class="input input-sm flex-1"
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

  attr :item, :any, required: true
  attr :can_write, :boolean, required: true
  attr :form_key, :integer, default: 0
  attr :section_key, :string, default: nil

  @doc "Links out of the system, on a card or a page."
  def urls_section(assigns) do
    ~H"""
    <section class="space-y-2 px-1" id={dom_id("card-urls", @item)} data-section-key={@section_key}>
      <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
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
            title={"Added #{Calendar.strftime(url.inserted_at, "%a %-d %b %Y, %H:%M")}"}
          >
            {Calendar.strftime(url.inserted_at, "%-d %b %Y")}
          </span>
          <button
            :if={@can_write}
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
        id={dom_id("card-url-form-#{@form_key}", @item)}
        phx-submit="add_card_url"
        class="flex gap-1"
      >
        <input
          type="text"
          name="url"
          placeholder="https://… , file://… or an address"
          class="input input-xs min-w-0 flex-1"
          autocomplete="off"
        />
        <input
          type="text"
          name="title"
          placeholder="Label (optional)"
          class="input input-xs w-32 shrink-0"
          autocomplete="off"
        />
        <button type="submit" class="btn btn-xs shrink-0">Add</button>
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

  attr :item, :any, required: true
  attr :board, :any, required: true
  attr :current_user, :any, default: nil
  attr :can_write, :boolean, required: true
  attr :form_key, :integer, default: 0
  attr :section_key, :string, default: nil
  attr :uploads, :any, default: nil, doc: "when given, images can be pasted into a comment"

  attr :mention_people, :string,
    default: nil,
    doc: "when given (see `SlipdockWeb.Mention.people/1`), typing @ offers these people"

  @doc "The remarks on a card or a page, newest first."
  def comments_section(assigns) do
    ~H"""
    <section class="space-y-3 px-1" data-section-key={@section_key}>
      <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
        <.icon name="hero-chat-bubble-left" class="size-3.5" />
        <.keyed_label :if={@section_key} key={@section_key} label="Comments" />
        <span :if={is_nil(@section_key)}>Comments</span>
        <span :if={@item.comments != []} class="font-normal">({length(@item.comments)})</span>
      </h3>
      <form
        :if={@can_write}
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
            <textarea
              name="body"
              rows="2"
              placeholder={
                if @uploads,
                  do: "Write a comment… (paste an image to attach it)",
                  else: "Write a comment…"
              }
              class="textarea w-full text-sm"
              required
            ></textarea>
          </div>
          <.live_file_input :if={@uploads} upload={@uploads.comment_image} class="hidden" />
        </div>
        <div class="flex justify-end">
          <button type="submit" class="btn btn-primary btn-sm">Comment</button>
        </div>
      </form>
      <ul class="space-y-3">
        <li :for={comment <- @item.comments} id={"comment-#{comment.id}"} class="group flex gap-3">
          <div class="flex size-8 shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-indigo-500 to-violet-600 text-xs font-bold text-white">
            Me
          </div>
          <div class="min-w-0 flex-1 rounded-xl bg-base-200/70 px-3 py-2">
            <div class="flex items-center justify-between gap-2">
              <span class="text-xs text-base-content/50">{relative_time(comment.inserted_at)}</span>
              <button
                :if={@can_write}
                type="button"
                class="btn btn-ghost btn-xs btn-square opacity-0 group-hover:opacity-100 no-hover:opacity-100"
                phx-click="delete_comment"
                phx-value-id={comment.id}
                data-confirm="Delete this comment?"
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
            </div>
            <div class="whitespace-pre-wrap break-words text-sm" phx-no-format>{RichText.render(comment.body, board: @board, as: @current_user)}</div>
          </div>
        </li>
      </ul>
      <p :if={@item.comments == []} class="px-1 text-xs text-base-content/50">
        Nothing said yet.
      </p>
    </section>
    """
  end

  attr :item, :any, required: true
  attr :can_write, :boolean, required: true
  attr :form_key, :integer, default: 0
  attr :stated, :any, default: nil, doc: "the latest reported health, when already to hand"

  @doc "Reported health, and the last few updates."
  def status_section(assigns) do
    assigns = assign_new(assigns, :stated, fn -> Boards.Card.stated_health(assigns.item) end)

    ~H"""
    <div class="space-y-1.5" id={dom_id("card-status-updates", @item)}>
      <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Status updates</span>
      <form
        :if={@can_write}
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
          class="textarea textarea-sm w-full text-xs"
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
            <span class="text-base-content/50" title={DateTime.to_iso8601(u.inserted_at)}>
              {relative_time(u.inserted_at)}
            </span>
            <button
              :if={@can_write}
              type="button"
              class="btn btn-ghost btn-xs btn-square ml-auto"
              phx-click="delete_status_update"
              phx-value-id={u.id}
              title="Remove this update"
            >
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </div>
          <p :if={u.body} class="mt-1 whitespace-pre-wrap text-base-content/80">{u.body}</p>
        </li>
      </ul>
    </div>
    """
  end

  attr :item, :any, required: true
  attr :board, :any, required: true
  attr :can_write, :boolean, required: true

  @doc "The board's custom fields, with this card's or page's values."
  def fields_section(assigns) do
    ~H"""
    <div :if={@board.fields != []} class="space-y-2" id={dom_id("card-fields", @item)}>
      <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Fields</span>
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
        <%= cond do %>
          <% field.kind == "formula" -> %>
          <% not @can_write -> %>
            <p class="text-xs">{Fields.format(field, value) || "—"}</p>
          <% field.kind == "rating" -> %>
            <div class="flex items-center gap-0.5">
              <button
                :for={n <- 1..FieldDefinition.rating_max(field)//1}
                type="button"
                class={[
                  "text-base leading-none transition hover:scale-110",
                  if(is_number(value) and n <= value,
                    do: "text-amber-500",
                    else: "text-base-content/25"
                  )
                ]}
                phx-click="set_field"
                phx-value-field_id={field.id}
                value={n}
                title={"#{n} of #{FieldDefinition.rating_max(field)}"}
              >
                ★
              </button>
              <button
                :if={is_number(value)}
                type="button"
                class="btn btn-ghost btn-xs btn-square"
                phx-click="set_field"
                phx-value-field_id={field.id}
                value=""
                title="Clear"
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            </div>
          <% true -> %>
            <form
              phx-change="set_field"
              phx-submit="set_field"
              id={dom_id("field-form-#{field.id}", @item)}
            >
              <input type="hidden" name="field_id" value={field.id} />
              <%= case field.kind do %>
                <% "number" -> %>
                  <input
                    type="number"
                    name="value"
                    value={value}
                    step={field.config["step"] || "any"}
                    min={field.config["min"]}
                    max={field.config["max"]}
                    placeholder={field.config["unit"]}
                    class="input input-sm w-full"
                    phx-debounce="600"
                  />
                <% "select" -> %>
                  <select name="value" class="select select-sm w-full">
                    <option value="">—</option>
                    <option :for={o <- field.options} value={o["key"]} selected={o["key"] == value}>
                      {o["label"]}
                    </option>
                  </select>
                <% "date" -> %>
                  <input type="date" name="value" value={value} class="input input-sm w-full" />
                <% _ -> %>
                  <input
                    type="text"
                    name="value"
                    value={value}
                    class="input input-sm w-full"
                    phx-debounce="600"
                  />
              <% end %>
            </form>
        <% end %>
      </div>
    </div>
    """
  end

  attr :item, :any, required: true
  attr :board, :any, required: true
  attr :current_user, :any, default: nil
  attr :can_write, :boolean, required: true

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

    assigns =
      assign(assigns,
        budget: budget,
        per_card: per_card,
        mine: mine,
        left: max(budget - spent, 0),
        total: Boards.Card.vote_total(assigns.item),
        can_add: mine < per_card and spent < budget and assigns.can_write
      )

    ~H"""
    <div class="space-y-1.5" id={dom_id("card-votes", @item)}>
      <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Votes</span>
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span class="chip chip-line" title="Votes from everyone">
          <.icon name="hero-hand-thumb-up" class="size-3" /> {@total}
        </span>
        <div :if={@current_user} class="join" title="Your votes">
          <button
            type="button"
            class="btn btn-xs join-item"
            phx-click="vote"
            phx-value-count={@mine - 1}
            disabled={@mine == 0 or not @can_write}
            aria-label="One vote fewer"
          >
            −
          </button>
          <span class="btn btn-xs join-item no-animation cursor-default font-mono">{@mine}</span>
          <button
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
end
