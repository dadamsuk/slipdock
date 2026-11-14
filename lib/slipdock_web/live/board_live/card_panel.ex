defmodule SlipdockWeb.BoardLive.CardPanel do
  @moduledoc """
  The card panel's markup, part one: the top of the panel (title, list,
  flags, tags, description), its attachments, and the sidebar. The panel is
  `BoardLive.CardComponent`; these draw what it holds, and send their events
  to it (`target`). Part two is `BoardLive.CardSections`.

  The larger pieces are in modules of their own under `CardPanel.`: `Verify`
  (verification and evidence), `Chips` (the Flags and Tags rows),
  `Attachments`, `Properties` (the property rows, authors and borders) and
  `Schedule` (Repeat and Snooze). None of them refers back to this module.
  """
  use SlipdockWeb, :html

  alias Slipdock.Boards.ShortNames

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.ItemComponents
  import SlipdockWeb.BoardLive.Helpers

  import SlipdockWeb.BoardLive.CardPanel.Properties,
    only: [card_props: 1, borders_section: 1, side?: 2]

  import SlipdockWeb.BoardLive.CardPanel.Schedule, only: [repeat_section: 1, snooze_section: 1]

  alias SlipdockWeb.BoardLive.CardPanel.{Attachments, Chips, Verify}

  alias Slipdock.Boards.Card
  alias Slipdock.Palette
  alias SlipdockWeb.RichText

  # The card's paths that are shared on its board (#1971): they hold no lane.
  defp shared_paths(board, card) do
    case card.paths do
      [_ | _] = paths ->
        shared = Slipdock.Lanes.shared_paths(board)
        Enum.filter(paths, &Slipdock.Lanes.shared?(&1, shared))

      _ ->
        []
    end
  end

  attr :board, :any, required: true
  attr :can_write, :boolean, required: true

  attr :can_add, :boolean,
    default: false,
    doc: "offer Duplicate: it adds a card to the board, so needs write on the board"

  attr :card, Card, required: true

  attr :handoff_link, :boolean,
    default: false,
    doc: "offer the handoff (the board's label for it): a commenter may write one"

  attr :ask_link, :boolean,
    default: false,
    doc: "offer Ask questions (#1220)"

  attr :target, :any, required: true

  @doc """
  The card's actions (#1725), in a row at the top of the panel that ends
  where the heart and the close button begin: Move (to another board), the
  handoff, Ask, and a ⋯ menu with Duplicate, Archive and Delete. Outside
  the card's fieldsets, so each says for itself who may use it: a reader
  gets none of them, a commenter only the handoff. The words drop below
  `sm`, leaving the icons, so the row stays one row on a phone.
  """
  def card_toolbar(assigns) do
    ~H"""
    <div id="card-toolbar" class="flex min-w-0 items-center justify-end gap-0.5">
      <button
        :if={@can_write}
        type="button"
        id="card-move-board"
        phx-click="open_move_board"
        phx-target="#board-move"
        phx-value-id={@card.id}
        class="btn btn-ghost btn-sm gap-1.5 px-2 font-normal"
        title="Move this card to another board, with its subcards"
        aria-label="Move to another board"
      >
        <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
        <span class="hidden sm:inline">Move</span>
      </button>
      <%!-- Most cards never get a handoff, so until one is written it is
            this and no more (W-1804). --%>
      <button
        :if={@handoff_link}
        type="button"
        id="handoff-edit"
        phx-click="edit_handoff"
        phx-target={@target}
        class="btn btn-ghost btn-sm gap-1.5 px-2 font-normal"
        title="Say where you left this card, so whoever picks it up next reads that first"
        aria-label={"Add “#{Slipdock.Boards.Board.handoff_label(@board)}”"}
      >
        <.icon name="hero-bookmark" class="size-4" />
        <span class="hidden max-w-[9rem] truncate sm:inline">
          {Slipdock.Boards.Board.handoff_label(@board)}
        </span>
      </button>
      <%!-- Follow-up questions (#1220): ask someone, a box per question. --%>
      <button
        :if={@ask_link}
        type="button"
        id="wait-ask"
        phx-click="ask_questions"
        phx-target={@target}
        class="btn btn-ghost btn-sm gap-1.5 px-2 font-normal"
        title="Ask someone questions on this card: the card waits on their answers"
        aria-label="Ask questions"
      >
        <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" />
        <span class="hidden sm:inline">Ask</span>
      </button>
      <button
        :if={@can_write}
        type="button"
        id="card-more"
        popovertarget="card-more-menu"
        class="btn btn-ghost btn-sm btn-square"
        title="More actions"
        aria-label="More actions"
      >
        <.icon name="hero-ellipsis-horizontal" class="size-5" />
      </button>
      <div
        :if={@can_write}
        id="card-more-menu"
        popover
        phx-hook="AnchoredPopover"
        data-anchor="card-more"
        class="pop-menu"
      >
        <ul class="menu w-48 rounded-xl bg-base-100 p-1 text-sm shadow-xl ring-1 ring-base-content/10">
          <li :if={@can_add}>
            <button
              id="duplicate-card"
              type="button"
              popovertarget="card-more-menu"
              popovertargetaction="hide"
              phx-target={@target}
              phx-click="duplicate_card"
              title="A copy as it is now: checklist unticked, subcards reopened; no comments, dates or files"
            >
              <.icon name="hero-document-duplicate" class="size-4" /> Duplicate
            </button>
          </li>
          <li>
            <button
              id="archive-card"
              type="button"
              popovertarget="card-more-menu"
              popovertargetaction="hide"
              phx-target={@target}
              phx-click="archive_card"
            >
              <.icon name="hero-archive-box" class="size-4" /> Archive
            </button>
          </li>
          <li class="border-t border-base-content/10 pt-1">
            <button
              id="delete-card"
              type="button"
              phx-target={@target}
              phx-click="delete_card"
              data-confirm="Delete this card permanently?"
              class="text-error"
            >
              <.icon name="hero-trash" class="size-4" /> Delete
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :can_write, :boolean, required: true
  attr :card, Card, required: true
  attr :form, :any, required: true
  attr :target, :any, required: true

  @doc """
  The very top of the panel: the title and the quiet meta line under it
  (board › list, the card's link, when it was made). A form of its own, so
  that the handoff can sit straight beneath it, outside every form.
  """
  def card_title_form(assigns) do
    ~H"""
    <.form
      phx-target={@target}
      for={@form}
      id="card-title-form"
      phx-change="card_change"
      phx-submit="card_change"
      class="space-y-3"
    >
      <div class="flex items-start gap-3">
        <.complete_toggle card={@card} class="mt-1.5" size="size-6" disabled={!@can_write} />
        <textarea
          name={@form[:title].name}
          id="card-title"
          rows="1"
          phx-debounce="500"
          phx-hook="AutoGrow"
          data-single-line
          class={[
            "field-bare w-full resize-none px-1 text-xl font-bold leading-tight sm:text-2xl",
            @card.completed && "opacity-60"
          ]}
          placeholder="Card title"
        >{@form[:title].value}</textarea>
      </div>
      <p :if={@form[:title].errors != []} class="text-sm text-error">Title can't be blank.</p>
      <div
        :if={@card.short_name || @card.short_name_edited || ShortNames.long?(@form[:title].value)}
        class="flex items-center gap-2 px-1 text-sm"
      >
        <label for="card-short-name" class="text-base-content/50">Short name</label>
        <input
          type="text"
          id="card-short-name"
          name={@form[:short_name].name}
          value={@form[:short_name].value}
          maxlength={ShortNames.max_length()}
          phx-debounce="500"
          placeholder="Made for you"
          class="field-bare min-w-0 flex-1 px-1"
        />
      </div>
      <p :if={@form[:short_name].errors != []} class="text-sm text-error">
        A short name is at most {ShortNames.max_length()} characters.
      </p>
      <%!-- A quiet breadcrumb (#1725): Board › List · #id · created, and on
            an epic the one way to its subcards' board. Words and a bare
            select, no bordered buttons: the actions are in the toolbar
            (`card_toolbar/1`). --%>
      <div
        id="card-meta"
        class="flex flex-wrap items-center gap-x-1.5 gap-y-1 px-1 text-sm text-base-content/50"
      >
        <span id="card-meta-board" class="max-w-[14rem] truncate" title={@board.name}>
          {@board.name}
        </span>
        <span aria-hidden="true">›</span>
        <%!-- The quickest way to move a card, and the only practical one
              on a phone, where dragging it across a board that shows one
              list at a time is no way to live. `card_change` touches only
              what the form it came from carried. --%>
        <select
          :if={@can_write}
          name="card[column_id]"
          class="select field-bare w-auto max-w-[12rem] font-medium text-base-content/80"
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
        <span aria-hidden="true">·</span>
        <%!-- A link, not a button: this sits in the fieldset that is
              disabled for a read-only card, and a reader can share a link
              too. The hook copies the URL instead of following it. --%>
        <a
          id="card-copy-link"
          href={url(~p"/boards/#{@card.board_id}/cards/#{@card.id}")}
          phx-hook="CopyLink"
          class="inline-flex items-center gap-1 font-mono text-base-content/60 hover:text-primary"
          title="Copy a link to this card"
        >
          <span data-label>#{@card.id}</span>
          <.icon name="hero-link" class="size-3" />
        </a>
        <span aria-hidden="true">·</span>
        <span>created <.timestamp id="card-created-at" at={@card.inserted_at} /></span>
        <%!-- Its time in the list, the chip its tile wears (#2131), so the
              card explains what the board and Right now say about it. --%>
        <span :if={aged?(@card)} id="card-age" class="inline-flex items-center gap-1.5">
          <span aria-hidden="true">·</span>
          <span>in list</span>
          <.age_chip state={@card.state} />
        </span>
        <%!-- An epic opens onto its board in one click from the top, the
              only "Open board" on the card. --%>
        <span
          :if={@card.sub_board}
          id="card-open-board"
          class="inline-flex items-center gap-1.5"
        >
          <span aria-hidden="true">·</span>
          <.link
            navigate={~p"/boards/#{@card.sub_board.id}"}
            class="inline-flex items-center gap-1 font-medium text-primary hover:underline"
            title="Open this card's subcards as a board"
          >
            <.icon name="hero-squares-2x2" class="size-3.5" /> Open board
          </.link>
          <span :for={{done, total} <- [Card.progress(@card)]}>{done} of {total} done</span>
        </span>
      </div>
    </.form>
    """
  end

  attr :card, Card, required: true
  attr :can_write, :boolean, required: true
  attr :target, :any, required: true
  attr :form_key, :integer, doc: "its default is `Verify.verify_section/1`'s"

  @doc "Where an agent's completion stands on a board that verifies work: `Verify.verify_section/1`."
  def verify_section(assigns), do: Verify.verify_section(assigns)

  attr :card, Card, required: true

  @doc "What an agent checked when it completed the card: `Verify.evidence_section/1`."
  def evidence_section(assigns), do: Verify.evidence_section(assigns)

  attr :board, :any, required: true
  attr :card, Card, required: true
  attr :form, :any, required: true
  attr :target, :any, required: true

  @doc """
  What kind of change the card is (#1951), with the agent work it decides
  (#2018): on a board with profiles on, or a card that has one. Beside a
  profile, where it came from ("inferred", "set by a person"); beside none,
  on a profiles board, what an agent starting it would be given and why, for
  a person to accept or override before work starts.
  """
  def profile_section(assigns) do
    assigns =
      assign(assigns,
        source: profile_source_text(assigns.card.profile_source),
        preview:
          if(is_nil(assigns.card.profile) and assigns.board.profiles,
            do: Slipdock.Profiles.explain_card(assigns.card)
          )
      )

    ~H"""
    <.form
      phx-target={@target}
      for={@form}
      id="card-profile-form"
      phx-change="card_change"
      phx-submit="card_change"
      class="space-y-1.5 px-1"
    >
      <p class="flex items-center gap-1.5 section-label">
        <.icon name="hero-tag" class="size-3.5" />
        <label for="card-profile">Profile</label>
      </p>
      <div class="flex flex-wrap items-center gap-2">
        <select name={@form[:profile].name} id="card-profile" class="select field w-auto">
          <option value="" selected={is_nil(@card.profile)}>None</option>
          <option
            :for={name <- Slipdock.Profiles.names()}
            value={name}
            selected={name == @card.profile}
          >
            {name}
          </option>
        </select>
        <span
          :if={@card.profile && @source}
          id="card-profile-source"
          data-source={@card.profile_source}
          class="text-xs text-base-content/60"
        >
          · {@source}
        </span>
        <span :if={@preview} id="card-profile-preview" class="text-xs text-base-content/60">
          would be inferred: <span class="font-medium">{elem(@preview, 0)}</span>, {elem(
            @preview,
            1
          )}
        </span>
        <button
          :if={@preview}
          type="button"
          id="card-profile-accept"
          phx-click="accept_profile"
          phx-value-profile={elem(@preview, 0)}
          phx-target={@target}
          class="btn btn-ghost btn-xs"
        >
          Use it
        </button>
      </div>
      <p :for={msg <- Enum.map(@form[:profile].errors, &elem(&1, 0))} class="text-sm text-error">
        {msg}
      </p>
    </.form>
    """
  end

  @doc "Where a card's profile came from, as the panel and tile say it (#2018)."
  def profile_source_text("inferred"), do: "inferred"
  def profile_source_text(source) when source in ~w(person agent rule), do: "set by #{source}"
  def profile_source_text(_source), do: nil

  attr :board, :any, default: nil
  attr :can_write, :boolean, default: true
  attr :card, Card, required: true
  attr :current_user, :any, default: nil
  attr :editing, :boolean, default: false, doc: "its box is open (#3001)"
  attr :form, :any, required: true
  attr :target, :any, required: true

  @doc """
  What done means for the card (#1631): on a board that asks for a bar, or a
  card that has one. It locks for agents when work starts; a person can
  still change it, so the field stays editable here.

  A bar that is written shows as Markdown (#3001), as the description does:
  its parts are usually a numbered list. Clicking it, or Edit, opens the box;
  Done (or Escape) closes it. An empty bar shows the box straight away.
  """
  def bar_section(assigns) do
    assigns =
      assign(assigns, :written?, String.trim(assigns.card.bar || "") != "")

    ~H"""
    <.form
      phx-target={@target}
      for={@form}
      id="card-bar-form"
      phx-change="card_change"
      phx-submit="card_change"
      class="space-y-1.5 px-1"
    >
      <div class="flex items-center gap-1.5">
        <p class="flex items-center gap-1.5 section-label">
          <.icon name="hero-trophy" class="size-3.5" />
          <span>Bar</span>
          <span
            :if={@card.bar_locked_at}
            id="card-bar-locked"
            class="badge badge-ghost badge-xs gap-1 normal-case"
            title="Locked when work started: agents can't change it"
          >
            <.icon name="hero-lock-closed" class="size-3" /> locked
          </span>
        </p>
        <button
          :if={@can_write and @written? and not @editing}
          id="card-bar-edit"
          phx-target={@target}
          type="button"
          class="btn btn-ghost btn-xs ml-auto"
          phx-click="edit_bar"
        >
          <.icon name="hero-pencil" class="size-3.5" /> Edit
        </button>
        <button
          :if={@written? and @editing}
          id="card-bar-done"
          phx-target={@target}
          type="button"
          class="btn btn-ghost btn-xs ml-auto"
          phx-click="stop_editing_bar"
        >
          <.icon name="hero-check" class="size-3.5" /> Done
        </button>
      </div>
      <div
        :if={@written? and not @editing}
        phx-target={@target}
        id="card-bar-view"
        class={[
          "card-prose rounded-lg px-1 py-1 text-sm leading-relaxed break-words",
          @can_write && "cursor-text hover:bg-base-200/60"
        ]}
        phx-click={@can_write && "edit_bar"}
        phx-no-format
      >{RichText.markdown(@card.bar, board: @board, as: @current_user)}</div>
      <textarea
        :if={@editing or not @written?}
        name={@form[:bar].name}
        id="card-bar"
        rows="2"
        phx-debounce="800"
        phx-hook="AutoGrow"
        phx-keydown={@written? && "stop_editing_bar"}
        phx-key={@written? && "Escape"}
        phx-target={@target}
        maxlength={Card.bar_length()}
        placeholder="What done means for this card, written before work starts"
        class="textarea field w-full"
      >{@form[:bar].value}</textarea>
      <p :for={msg <- Enum.map(@form[:bar].errors, &elem(&1, 0))} class="text-sm text-error">
        {msg}
      </p>
    </.form>
    """
  end

  attr :board, :any, required: true
  attr :card, Card, required: true
  attr :form, :any, required: true
  attr :target, :any, required: true

  @doc """
  The paths the card's work touches (#1628), one glob per line. On a board
  with lanes on it says which card in progress they overlap, if any: an
  agent can't start this card then, but a person moving it is the override.
  A glob that claims a whole top-level directory is marked broad, with why
  (#2698, `Slipdock.Lanes.broad?/2`).
  """
  def paths_section(assigns) do
    assigns =
      assign(assigns,
        overlap: Slipdock.Lanes.on?(assigns.board) && Slipdock.Lanes.conflict(assigns.card),
        advisory: Slipdock.Lanes.mode(assigns.board) == "advise",
        shared: shared_paths(assigns.board, assigns.card),
        broad:
          Slipdock.Lanes.broad_paths(
            assigns.card.paths,
            Slipdock.Lanes.shared_paths(assigns.board)
          ),
        text: assigns.form[:paths].value |> List.wrap() |> Enum.join("\n")
      )

    ~H"""
    <.form
      phx-target={@target}
      for={@form}
      id="card-paths-form"
      phx-change="card_change"
      phx-submit="card_change"
      class="space-y-1.5 px-1"
    >
      <p class="flex items-center gap-1.5 section-label">
        <.icon name="hero-folder" class="size-3.5" />
        <span>Paths</span>
      </p>
      <textarea
        name={@form[:paths].name}
        id="card-paths"
        rows="2"
        phx-debounce="800"
        phx-hook="AutoGrow"
        placeholder="The files its work touches, one glob per line: lib/slipdock/runners/**"
        class="textarea field field-mono w-full"
      >{@text}</textarea>
      <p :for={msg <- Enum.map(@form[:paths].errors, &elem(&1, 0))} class="text-sm text-error">
        {msg}
      </p>
      <p :if={@overlap && !@advisory} id="card-paths-overlap" class="text-xs text-warning">
        Overlaps #{@overlap.id} {@overlap.title}, in progress: an agent can't start this card
        while it is. Moving it yourself overrides that.
      </p>
      <p :if={@overlap && @advisory} id="card-paths-overlap" class="text-xs text-base-content/60">
        Overlaps #{@overlap.id} {@overlap.title}, in progress, advisory: an agent can start this
        card, and its job's prompt tells it which card is in those files.
      </p>
      <p :if={@broad != []} id="card-paths-broad" class="text-xs text-base-content/60">
        Broad: <span class="font-mono">{Enum.join(@broad, ", ")}</span>
        — {Slipdock.Lanes.broad_reason()}. Advice only: nothing is refused for it.
      </p>
      <p :if={@shared != []} id="card-paths-shared" class="text-xs text-base-content/60">
        Shared on the board, so they hold no lane:
        <span class="font-mono">{Enum.join(@shared, ", ")}</span>
      </p>
    </.form>
    """
  end

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
  attr :description?, :boolean, default: true, doc: "the reader's card view shows it (#2031)"

  @doc "The rest of the panel's top, under the title: flags, tags and the description."
  def card_header_form(assigns) do
    ~H"""
    <%!-- Flags and tags (#1727): what is on the card, as chips, and a
          "+ Add" that opens a checklist of the rest. Outside the card's form:
          they are clicks, and the tag picker holds a small form of its own. --%>
    <div class="space-y-3 px-1 pt-2">
      <Chips.flags_row card={@card} can_write={@can_write} target={@target} />

      <Chips.tags_row
        board={@board}
        card={@card}
        can_write={@can_write}
        tags_path={@tags_path}
        target={@target}
      />
    </div>

    <.form
      phx-target={@target}
      for={@form}
      id="card-form"
      phx-change="card_change"
      phx-submit="card_change"
      class="space-y-3"
    >
      <div :if={@description?} class="space-y-1.5 px-1" data-section-key="d">
        <div class="flex items-center justify-between">
          <label
            for="card-description"
            class="flex items-center gap-1.5 section-label"
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
            <%!-- Typing [[ offers the wiki's pages (PageLink). --%>
            <div id="card-description-page-link" phx-hook="PageLink" data-board={@card.board_id}>
              <%!-- The Markdown editor (MarkdownEditor) takes over the
                    textarea, which stays the form's field; ignored by
                    LiveView so a patch never resets it under the editor. --%>
              <div
                id={"card-description-editor-#{@card.id}"}
                phx-hook="MarkdownEditor"
                phx-update="ignore"
                data-editor-class="md-editor-field"
              >
                <textarea
                  phx-target={@target}
                  id="card-description"
                  name={@form[:description].name}
                  phx-debounce="700"
                  phx-keydown="stop_editing_description"
                  phx-key="Escape"
                  autofocus
                  rows="3"
                  placeholder="Add more detail…"
                  class="textarea field w-full"
                >{@form[:description].value}</textarea>
              </div>
            </div>
          </div>
          <.live_file_input upload={@uploads.desc_image} class="hidden" />
          <p class="text-2xs text-base-content/60">
            Paste or drop an image to add it; type @ to mention somebody, [[ to link a page. Click Done or press Escape when finished.
          </p>
        </div>
        <div
          :if={not @editing_description and (@card.description || "") != ""}
          phx-target={@target}
          id="card-description-view"
          class={[
            "card-prose rounded-lg px-1 py-1 text-sm leading-relaxed break-words",
            @can_write && "cursor-text hover:bg-base-200/60"
          ]}
          phx-click={@can_write && "edit_description"}
          phx-no-format
        >{RichText.markdown(@card.description, board: @board, as: @current_user)}</div>
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

  attr :at, :string,
    doc:
      "where a search result points (`transcript-5-part-2`): that transcript opens at that part"

  attr :transcribe, :boolean,
    doc: "whether a transcription server is set up, so recordings offer Transcribe"

  @doc """
  The card's files, and the uploads under way: `Attachments.attachments_section/1`,
  which holds the defaults of `at` and `transcribe`.
  """
  def attachments_section(assigns), do: Attachments.attachments_section(assigns)

  attr :board, :any, required: true
  attr :card, Card, required: true
  attr :loop, :map, default: nil, doc: "the runner loop holding the card (#2027)"
  attr :authors, :map, default: nil, doc: "who created it and changed it last (#2028)"
  attr :form, :any, required: true
  attr :target, :any, required: true
  attr :users, :list, required: true

  attr :panel, :any,
    default: nil,
    doc: "the properties the reader's card view shows (#2070), a MapSet; nil shows them all"

  @doc """
  On a phone (#1729), the card's properties come straight after its title:
  a one-line summary (who, when it is due, how urgent; the list is on the
  meta line above), which opens onto the property rows to change them. The
  open state is the client's (`JS.toggle_attribute`), so it survives a save.
  """
  def phone_properties(assigns) do
    ~H"""
    <div id="card-phone-properties" class="space-y-1">
      <button
        type="button"
        id="card-phone-summary"
        aria-expanded="false"
        aria-controls="card-phone-props"
        phx-click={
          JS.toggle_attribute({"hidden", "hidden"}, to: "#card-phone-props")
          |> JS.toggle_attribute({"aria-expanded", "true", "false"})
        }
        class="flex w-full flex-wrap items-center gap-x-3 gap-y-1 rounded-lg bg-base-200/60 px-3 py-2 text-left text-sm text-base-content/80"
      >
        <span
          :if={side?(@panel, "side.assignees")}
          data-summary="assignee"
          class="inline-flex min-w-0 items-center gap-1"
        >
          <.icon name="hero-user" class="size-4 shrink-0 text-base-content/50" />
          <span class="truncate">
            {case Card.assignees(@card) do
              [] -> "Unassigned"
              people -> Enum.map_join(people, ", ", &Slipdock.Accounts.User.display_name/1)
            end}
          </span>
        </span>
        <span
          :if={side?(@panel, "side.due")}
          data-summary="due"
          class="inline-flex items-center gap-1"
        >
          <.icon name="hero-calendar" class="size-4 shrink-0 text-base-content/50" />
          {if @card.due_date,
            do: "Due #{SlipdockWeb.Dates.short(@card.due_date)}",
            else: "No due date"}
        </span>
        <span
          :if={side?(@panel, "side.priority")}
          data-summary="priority"
          class="inline-flex items-center gap-1"
        >
          <.icon name="hero-signal" class="size-4 shrink-0 text-base-content/50" />
          {if @card.priority in [nil, "none"],
            do: "No priority",
            else: priority_label(@card.priority)}
        </span>
        <.icon name="hero-chevron-down" class="ml-auto size-4 text-base-content/50" />
      </button>
      <div id="card-phone-props" hidden class="rounded-lg bg-base-200/40 px-3 py-2">
        <.form
          for={@form}
          id="card-phone-props-form"
          phx-change="card_change"
          phx-target={@target}
        >
          <.card_props
            board={@board}
            card={@card}
            form={@form}
            loop={@loop}
            authors={@authors}
            target={@target}
            users={@users}
            panel={@panel}
          />
        </.form>
      </div>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :can_write, :boolean, required: true
  attr :can_comment, :boolean, default: false, doc: "may report a status and vote (#863)"
  attr :card, Card, required: true
  attr :loop, :map, default: nil, doc: "the runner loop holding the card (#2027)"
  attr :authors, :map, default: nil, doc: "who created it and changed it last (#2028)"
  attr :current_user, :any, default: nil
  attr :form, :any, required: true
  attr :form_key, :integer, required: true
  attr :target, :any, required: true
  attr :users, :list, required: true
  attr :repeat, :map, default: nil, doc: "the Repeat… form while it is open (W-1802)"

  attr :narrow?, :boolean, default: false, doc: "a phone: the properties are under the title"

  attr :panel, :any,
    default: nil,
    doc: "the groups the reader's card view shows (#2031), a MapSet; nil shows them all"

  @doc "The panel's sidebar: the properties (assignees, priority, dates, health), time, fields, votes, cover, borders, repeat and snooze."
  def card_sidebar(assigns) do
    panel = assigns.panel || MapSet.new(Slipdock.CardViews.Elements.panel_keys())
    assigns = assign(assigns, :panel, panel)

    ~H"""
    <aside class="min-w-0 space-y-5 rounded-b-2xl bg-base-200/60 p-5 md:rounded-bl-none">
      <%!-- The card's own fields need write; status updates and votes are
            the discussion, which a commenter joins (#863). --%>
      <fieldset disabled={!@can_write} class="min-w-0 space-y-5">
        <.form
          phx-target={@target}
          for={@form}
          id="card-meta-form"
          phx-change="card_change"
          class="space-y-4"
        >
          <%!-- Properties (#1726): the label on the left, the value on the
                right. On a phone they are under the title instead (#1729). --%>
          <.card_props
            :if={!@narrow?}
            board={@board}
            card={@card}
            form={@form}
            loop={@loop}
            authors={@authors}
            target={@target}
            users={@users}
            panel={@panel}
          />
          <div
            :if={
              (not @board.simple and MapSet.member?(@panel, "side.rollup") and @card.rollup) &&
                @card.rollup.children > 0 && @card.rollup.derived_due
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
            :if={MapSet.member?(@panel, "side.due") and Card.days_past_due(@card) > 0}
            class="flex items-center gap-1 rounded-lg bg-error/10 p-2 text-xs text-error"
            id="card-past-due"
          >
            <.icon name="hero-exclamation-triangle" class="size-3.5" />
            This card is {past_date_label(:due, Card.days_past_due(@card))}
          </p>
        </.form>
        <.time_section
          :if={not @board.simple and MapSet.member?(@panel, "side.time")}
          target={@target}
          card={@card}
          can_write={@can_write}
          form_key={@form_key}
        />
      </fieldset>
      <fieldset
        :if={not @board.simple and MapSet.member?(@panel, "side.status")}
        disabled={!@can_comment}
        class="min-w-0"
      >
        <.status_section
          target={@target}
          item={@card}
          can_write={@can_write}
          can_comment={@can_comment}
          form_key={@form_key}
          stated={Card.stated_health(@card)}
        />
      </fieldset>
      <fieldset
        :if={@board.fields != [] and MapSet.member?(@panel, "side.fields")}
        disabled={!@can_write}
        class="min-w-0"
      >
        <.fields_section target={@target} item={@card} board={@board} can_write={@can_write} />
      </fieldset>
      <fieldset
        :if={not @board.simple and MapSet.member?(@panel, "side.votes")}
        disabled={!@can_comment}
        class="min-w-0"
      >
        <.vote_box
          target={@target}
          item={@card}
          board={@board}
          current_user={@current_user}
          can_write={@can_write}
          can_comment={@can_comment}
        />
      </fieldset>
      <fieldset disabled={!@can_write} class="min-w-0 space-y-5">
        <div :if={MapSet.member?(@panel, "side.cover")} class="space-y-1.5">
          <span class="section-label">Cover</span>
          <div class="flex flex-wrap gap-1.5">
            <.color_swatch
              phx-target={@target}
              color={nil}
              label="No cover"
              selected={is_nil(@card.color)}
              phx-click="set_cover"
              phx-value-color=""
            />
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

        <.borders_section :if={MapSet.member?(@panel, "side.borders")} card={@card} target={@target} />

        <.repeat_section
          :if={MapSet.member?(@panel, "side.repeat")}
          card={@card}
          current_user={@current_user}
          repeat={@repeat}
          target={@target}
        />

        <.snooze_section
          :if={MapSet.member?(@panel, "side.snooze")}
          card={@card}
          can_write={@can_write}
          current_user={@current_user}
        />
      </fieldset>
    </aside>
    """
  end

  # A card whose time in its list is known: one read with its state
  # (`Items.with_state/2`), which the chip has words for (#2131).
  defp aged?(%Card{state: state}), do: not is_nil(Slipdock.CardState.age_text(state))
end
