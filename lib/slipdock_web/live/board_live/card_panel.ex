defmodule SlipdockWeb.BoardLive.CardPanel do
  @moduledoc """
  The card panel's markup, part one: the top of the panel (title, list,
  flags, tags, description), its attachments, and the sidebar. The panel is
  `BoardLive.CardComponent`; these draw what it holds, and send their events
  to it (`target`). Part two is `BoardLive.CardSections`.
  """
  use SlipdockWeb, :html

  alias Slipdock.Boards.ShortNames

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.ItemComponents
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Boards, Dates, Palette, Transcription}
  alias Slipdock.Boards.{Attachment, Card}
  alias Slipdock.OCR.Text, as: OCRText
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
          <li>
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
  attr :form_key, :integer, default: 0

  @doc """
  Where an agent's completion stands on a board that verifies work (#1633):
  pending, with Accept and a Reject that takes the reason; or accepted or
  rejected, by whom, with the note; or accepted and merging its pull
  request (#1657), with Merged it myself.
  """
  def verify_section(assigns) do
    assigns =
      assigns
      |> assign(:merge_status, Slipdock.Verified.merge_status(assigns.card))
      |> assign(:person, Slipdock.Verified.person(verify_actor(assigns.card)))
      |> assign(:checks, Slipdock.Verified.Checks.lines(assigns.card.verify_checks))

    ~H"""
    <div id="card-verify" class="space-y-2 rounded-lg border border-base-300 px-3 py-2">
      <p class="flex items-center gap-2 text-sm">
        <.icon name={verify_icon(@card.verify_state)} class="size-4 shrink-0" />
        <span class="font-medium">{verify_title(@card.verify_state)}</span>
        <span :if={!@person} class="text-base-content/60">{verify_who(@card)}</span>
        <span :if={@person} id="card-verify-person" class="text-base-content/60">
          {verify_lead(@card)}
          <span :if={named?(@person)} class="font-medium text-base-content">{@person.name}</span>
          <a
            id="card-verify-email"
            href={"mailto:" <> @person.email}
            class="link link-primary break-all"
          >{@person.email}</a>
        </span>
        <span
          :if={@card.verify_rejections > 0}
          id="card-verify-rejections"
          class="badge badge-ghost badge-sm"
          title="How many times its submitted work was rejected"
        >
          rejected {@card.verify_rejections}×
        </span>
      </p>
      <p :if={@card.verify_note} class="whitespace-pre-wrap text-sm">{@card.verify_note}</p>
      <ul
        :if={@card.verify_state != "pending" && @checks != []}
        id="card-verify-checks"
        class="space-y-0.5 text-sm"
      >
        <li
          :for={{{label, result, note}, i} <- Enum.with_index(@checks)}
          id={"card-verify-check-#{i}"}
          class="flex items-start gap-1.5"
        >
          <.icon
            name={check_icon(result)}
            class={["mt-0.5 size-4 shrink-0", check_colour(result)]}
          />
          <span>
            <span class="font-medium">{label}</span>
            <span class="text-base-content/60">{result}</span>
            <span :if={note}>— {note}</span>
          </span>
        </li>
      </ul>
      <div :if={@person && @can_write} id="card-verify-reach" class="flex flex-wrap items-start gap-2">
        <form
          :if={not Card.assigned_to?(@card, @person.id)}
          id="verify-assign"
          phx-submit="card_change"
          phx-target={@target}
        >
          <input type="hidden" name="card[add_assignee_id]" value={@person.id} />
          <button type="submit" class="btn btn-ghost btn-sm">
            <.icon name="hero-user-plus" class="size-4" /> Assign to {first_word(@person)}
          </button>
        </form>
        <form
          id={"verify-note-#{@form_key}"}
          phx-submit="add_comment"
          phx-target={@target}
          class="flex min-w-0 flex-1 items-start gap-2"
        >
          <textarea
            name="body"
            rows="1"
            required
            aria-label={"A note to " <> Slipdock.Accounts.User.display_name(@person)}
            title="Posted as a comment; the @mention emails them"
            class="textarea field min-w-0 flex-1"
          >{"@" <> Slipdock.Wiki.Links.handle(@person) <> " "}</textarea>
          <button type="submit" class="btn btn-ghost btn-sm">
            <.icon name="hero-envelope" class="size-4" /> Note to {first_word(@person)}
          </button>
        </form>
      </div>
      <p :if={@card.merge_sha} id="card-merge-sha" class="text-sm">
        Merged as <code class="font-mono">{String.slice(@card.merge_sha, 0, 12)}</code>
      </p>
      <div :if={@card.verify_state == "merging"} id="card-merging" class="space-y-2">
        <p class="text-sm">
          <span :if={@merge_status in [:queued, :running]}>
            A runner is merging
            <a
              :if={@card.evidence_pr}
              href={@card.evidence_pr}
              target="_blank"
              rel="noopener noreferrer"
              class="link link-primary break-all"
            >{@card.evidence_pr}</a><span :if={!@card.evidence_pr}>its pull request</span>{if @merge_status ==
                                                                                                :queued,
                                                                                              do:
                                                                                                " (queued)",
                                                                                              else: ""}.
          </span>
          <span :if={@merge_status == :none} id="card-no-merger" class="text-warning">
            No runner can merge it: none of this board's runners takes merge jobs. Update a
            runner's script, or merge the pull request yourself and press Merged it myself.
          </span>
        </p>
        <button
          :if={@can_write}
          type="button"
          id="verify-merged"
          phx-click="verify_work"
          phx-value-decision="merged"
          phx-target={@target}
          data-confirm="Mark this card merged? Only if its pull request is merged."
          class="btn btn-ghost btn-sm"
        >
          Merged it myself
        </button>
      </div>
      <div :if={@card.verify_state == "held"} id="card-held" class="space-y-2">
        <p class="text-sm">
          Its human tier is <code>before_merge</code>: a person merges it or sends it back,
          by answering its wait or here.
        </p>
        <div :if={@can_write} class="space-y-2">
          <button
            type="button"
            id="held-merge"
            phx-click="verify_work"
            phx-value-decision="accept"
            phx-target={@target}
            class="btn btn-success btn-sm"
          >
            Merge
          </button>
          <form
            id="held-send-back"
            phx-submit="verify_work"
            phx-target={@target}
            class="flex items-start gap-2"
          >
            <input type="hidden" name="decision" value="reject" />
            <textarea
              name="reason"
              rows="1"
              required
              placeholder="Why it goes back"
              class="textarea field min-w-0 flex-1"
            ></textarea>
            <button type="submit" class="btn btn-ghost btn-sm">Send back</button>
          </form>
        </div>
      </div>
      <div :if={@card.verify_state == "pending" && @can_write} class="space-y-2">
        <button
          type="button"
          id="verify-accept"
          phx-click="verify_work"
          phx-value-decision="accept"
          phx-target={@target}
          class="btn btn-success btn-sm"
        >
          Accept
        </button>
        <form
          id="verify-reject"
          phx-submit="verify_work"
          phx-target={@target}
          class="flex items-start gap-2"
        >
          <input type="hidden" name="decision" value="reject" />
          <textarea
            name="reason"
            rows="1"
            required
            placeholder="What falls short of the bar"
            class="textarea field min-w-0 flex-1"
          ></textarea>
          <button type="submit" class="btn btn-ghost btn-sm">Reject</button>
        </form>
      </div>
    </div>
    """
  end

  defp failing_check?(result), do: Slipdock.Verified.Checks.failing_result?(result)

  # A part's mark: failed, passed, or a rule broken only in code the change
  # didn't touch (#1945), which is neither.
  defp check_icon("pre-existing"), do: "hero-archive-box"
  defp check_icon(result), do: if(failing_check?(result), do: "hero-x-mark", else: "hero-check")

  defp check_colour("pre-existing"), do: "text-warning"

  defp check_colour(result),
    do: if(failing_check?(result), do: "text-error", else: "text-success")

  defp verify_icon("pending"), do: "hero-clock"
  defp verify_icon("merging"), do: "hero-arrow-path"
  defp verify_icon("held"), do: "hero-hand-raised"
  defp verify_icon("accepted"), do: "hero-check-badge"
  defp verify_icon(_), do: "hero-x-circle"

  defp verify_title("pending"), do: "Awaiting verification"
  defp verify_title("merging"), do: "Accepted, merging"
  defp verify_title("held"), do: "Accepted, held for a person"
  defp verify_title("accepted"), do: "Accepted"
  defp verify_title(_), do: "Rejected"

  # Who the verification line is about: the submitter while it waits, then
  # whoever decided.
  defp verify_actor(%Card{verify_state: "pending", verify_submitter: by}), do: by
  defp verify_actor(%Card{verify_by: by}), do: by

  defp verify_lead(%Card{verify_state: "pending"}), do: "submitted by"
  defp verify_lead(_), do: "by"

  defp named?(%{name: name}), do: is_binary(name) and String.trim(name) != ""

  # A button's short label: the first word of their name, else their handle.
  defp first_word(person) do
    if named?(person),
      do: person.name |> String.split() |> hd(),
      else: Slipdock.Wiki.Links.handle(person)
  end

  defp verify_who(%Card{verify_state: "pending", verify_submitter: by}),
    do: "submitted by #{Slipdock.Verified.who(by)}"

  defp verify_who(%Card{verify_by: by}), do: "by #{Slipdock.Verified.who(by)}"

  attr :card, Card, required: true

  @doc """
  What an agent checked when it completed the card, and at which commit
  (#1632). Read-only: it is what the agent said.
  """
  def evidence_section(assigns) do
    ~H"""
    <div id="card-evidence" class="space-y-1.5 px-1">
      <p class="flex items-center gap-1.5 section-label">
        <.icon name="hero-check-badge" class="size-3.5" />
        <span>Evidence</span>
        <code :if={@card.evidence_commit} class="font-mono normal-case">
          {String.slice(@card.evidence_commit, 0, 12)}
        </code>
        <span :if={@card.evidence_branch} class="font-normal normal-case">
          on <code class="font-mono">{@card.evidence_branch}</code>
        </span>
      </p>
      <p :if={@card.evidence} class="whitespace-pre-wrap text-sm">{@card.evidence}</p>
      <p :if={@card.evidence_pr} id="card-evidence-pr" class="text-sm">
        Pull request
        <a
          href={@card.evidence_pr}
          target="_blank"
          rel="noopener noreferrer"
          class="link link-primary break-all"
        >
          {@card.evidence_pr}
        </a>
      </p>
      <p :if={@card.evidence_no_code} id="card-evidence-no-code" class="text-sm">
        <span class="font-medium">No code:</span>
        <span class="whitespace-pre-wrap">{@card.evidence_no_code}</span>
      </p>
      <p
        :if={@card.evidence_suite}
        id="card-evidence-suite"
        class={[
          "text-sm",
          if(@card.evidence_suite["result"] == "passed", do: "text-success", else: "text-error")
        ]}
      >
        Suite {Slipdock.Verified.suite_text(@card.evidence_suite)}
      </p>
      <ul :if={@card.evidence_tests} id="card-evidence-tests" class="space-y-0.5 text-xs">
        <li :for={t <- @card.evidence_tests}><code class="font-mono">{t}</code></li>
      </ul>
    </div>
    """
  end

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

  attr :card, Card, required: true
  attr :form, :any, required: true
  attr :target, :any, required: true

  @doc """
  What done means for the card (#1631): on a board that asks for a bar, or a
  card that has one. It locks for agents when work starts; a person can
  still change it, so the field stays editable here.
  """
  def bar_section(assigns) do
    ~H"""
    <.form
      phx-target={@target}
      for={@form}
      id="card-bar-form"
      phx-change="card_change"
      phx-submit="card_change"
      class="space-y-1.5 px-1"
    >
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
      <textarea
        name={@form[:bar].name}
        id="card-bar"
        rows="2"
        phx-debounce="800"
        phx-hook="AutoGrow"
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
  """
  def paths_section(assigns) do
    assigns =
      assign(assigns,
        overlap: Slipdock.Lanes.on?(assigns.board) && Slipdock.Lanes.conflict(assigns.card),
        advisory: Slipdock.Lanes.mode(assigns.board) == "advise",
        shared: shared_paths(assigns.board, assigns.card),
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

  @doc "The rest of the panel's top, under the title: flags, tags and the description."
  def card_header_form(assigns) do
    ~H"""
    <%!-- Flags and tags (#1727): what is on the card, as chips, and a
          "+ Add" that opens a checklist of the rest. Outside the card's form:
          they are clicks, and the tag picker holds a small form of its own. --%>
    <div class="space-y-3 px-1 pt-2">
      <div
        id="card-flags"
        class="flex flex-wrap items-center gap-x-3 gap-y-1.5"
        data-section-key="f"
        data-section-popover="card-flags-menu"
      >
        <p class="flex w-16 shrink-0 items-center gap-1.5 section-label">
          <.icon name="hero-flag" class="size-3.5" />
          <.keyed_label key="f" label="Flags" />
        </p>
        <div class="flex min-w-0 flex-1 flex-wrap items-center gap-1.5">
          <.flag_chip
            :for={flag <- applied_flags(@card)}
            flag={flag}
            removable={@can_write}
            phx-target={@target}
          />
          <button
            :if={@can_write}
            type="button"
            id="card-flags-add"
            popovertarget="card-flags-menu"
            class="btn btn-ghost btn-xs gap-1 font-normal text-base-content/60"
            aria-label="Add a flag"
          >
            <.icon name="hero-plus" class="size-3.5" /> Add
          </button>
          <span :if={!@can_write and @card.flags == []} class="text-xs text-base-content/40">
            None
          </span>
        </div>
        <div
          :if={@can_write}
          id="card-flags-menu"
          popover
          phx-hook="AnchoredPopover"
          data-anchor="card-flags-add"
          data-align="start"
          class="pop-menu"
        >
          <ul class="menu w-52 rounded-xl bg-base-100 p-1 text-sm shadow-xl ring-1 ring-base-content/10">
            <li :for={{flag, label, icon, color, _} <- flags()}>
              <button
                type="button"
                id={"card-flag-pick-#{flag}"}
                role="menuitemcheckbox"
                aria-checked={to_string(flag in @card.flags)}
                phx-click="toggle_flag"
                phx-value-flag={flag}
                phx-target={@target}
                class="flex items-center gap-2"
              >
                <.icon
                  name="hero-check"
                  class={["size-4", if(flag in @card.flags, do: "text-primary", else: "invisible")]}
                />
                <.icon name={icon} class={["size-4", color]} />
                <span class="flex-1 text-left">{label}</span>
              </button>
            </li>
          </ul>
        </div>
      </div>

      <div
        id="card-tags"
        class="flex flex-wrap items-center gap-x-3 gap-y-1.5"
        data-section-key="t"
        data-section-popover="card-tags-menu"
      >
        <p class="flex w-16 shrink-0 items-center gap-1.5 section-label">
          <.icon name="hero-tag" class="size-3.5" />
          <.keyed_label key="t" label="Tags" />
        </p>
        <div class="flex min-w-0 flex-1 flex-wrap items-center gap-1.5">
          <span
            :for={tag <- Enum.sort_by(@card.tags, &String.downcase(&1.name))}
            id={"card-tag-#{tag.id}"}
            data-role="tag-chip"
            class={[
              "inline-flex items-center gap-1 rounded-full py-0.5 pl-2.5 text-xs font-medium",
              Palette.chip(tag.color),
              if(@can_write, do: "pr-1", else: "pr-2.5")
            ]}
          >
            {tag.name}
            <button
              :if={@can_write}
              type="button"
              phx-click="toggle_tag"
              phx-value-id={tag.id}
              phx-target={@target}
              class="rounded-full p-0.5 opacity-60 transition hover:bg-base-content/10 hover:opacity-100"
              title={"Remove “#{tag.name}”"}
              aria-label={"Remove the tag #{tag.name}"}
            >
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </span>
          <button
            :if={@can_write}
            type="button"
            id="card-tags-add"
            popovertarget="card-tags-menu"
            class="btn btn-ghost btn-xs gap-1 font-normal text-base-content/60"
            aria-label="Add a tag"
          >
            <.icon name="hero-plus" class="size-3.5" /> Add
          </button>
          <span :if={!@can_write and @card.tags == []} class="text-xs text-base-content/40">
            None
          </span>
        </div>
        <div
          :if={@can_write}
          id="card-tags-menu"
          popover
          phx-hook="AnchoredPopover"
          data-anchor="card-tags-add"
          data-align="start"
          class="pop-menu"
        >
          <div class="w-64 rounded-xl bg-base-100 p-1 text-sm shadow-xl ring-1 ring-base-content/10">
            <%!-- One box: it narrows the list as you type, and Enter makes a
                  tag of what is typed (or applies the one of that name). --%>
            <.form
              for={%{}}
              as={:tag}
              id="card-tag-search"
              phx-submit="create_tag"
              phx-target={@target}
              phx-hook="TagFilter"
              data-list="card-tags-list"
              class="p-1"
            >
              <input
                type="text"
                name="name"
                id="card-tag-search-input"
                maxlength="30"
                autocomplete="off"
                placeholder="Search or name a new tag"
                aria-label="Search tags"
                class="input field-bare w-full"
              />
            </.form>
            <ul id="card-tags-list" class="menu max-h-64 w-full flex-nowrap overflow-y-auto p-0">
              <li
                :for={tag <- @board.tags}
                data-tag-name={tag.name}
              >
                <button
                  type="button"
                  id={"card-tag-pick-#{tag.id}"}
                  role="menuitemcheckbox"
                  aria-checked={to_string(Enum.any?(@card.tags, &(&1.id == tag.id)))}
                  phx-click="toggle_tag"
                  phx-value-id={tag.id}
                  phx-target={@target}
                  class="flex items-center gap-2"
                >
                  <.icon
                    name="hero-check"
                    class={[
                      "size-4",
                      if(Enum.any?(@card.tags, &(&1.id == tag.id)),
                        do: "text-primary",
                        else: "invisible"
                      )
                    ]}
                  />
                  <span class={["size-2 shrink-0 rounded-full", Palette.dot(tag.color)]}></span>
                  <span class="min-w-0 flex-1 truncate text-left">{tag.name}</span>
                </button>
              </li>
              <li
                data-role="no-tags"
                hidden={@board.tags != []}
                class="px-3 py-1.5 text-xs text-base-content/50"
              >
                No tags match.
              </li>
            </ul>
            <div class="border-t border-base-content/10 p-1">
              <button
                type="submit"
                form="card-tag-search"
                id="card-tag-create"
                data-role="new-tag"
                hidden
                class="btn btn-ghost btn-sm w-full justify-start gap-1.5 font-normal"
              >
                <.icon name="hero-plus" class="size-4" />
                <span>New tag “<span data-role="new-tag-name"></span>”</span>
              </button>
              <.link
                id="card-tag-manage"
                data-role="manage-tags"
                patch={@tags_path}
                class="btn btn-ghost btn-sm w-full justify-start gap-1.5 font-normal"
              >
                <.icon name="hero-plus" class="size-4" /> New tag
              </.link>
            </div>
          </div>
        </div>
      </div>
    </div>

    <.form
      phx-target={@target}
      for={@form}
      id="card-form"
      phx-change="card_change"
      phx-submit="card_change"
      class="space-y-3"
    >
      <div class="space-y-1.5 px-1" data-section-key="d">
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

  # The card's flags in the order the picker lists them.
  defp applied_flags(card), do: for({flag, _, _, _, _} <- flags(), flag in card.flags, do: flag)

  attr :flag, :string, required: true
  attr :removable, :boolean, default: false
  attr :rest, :global

  # An applied flag (#1727): its colour, icon and name, and an × to take it
  # off for someone who may.
  defp flag_chip(assigns) do
    {_, label, icon, color, active_cls} = List.keyfind!(flags(), assigns.flag, 0)
    assigns = assign(assigns, label: label, icon_name: icon, color: color, active_cls: active_cls)

    ~H"""
    <span
      id={"card-flag-#{@flag}"}
      data-role="flag-chip"
      class={[
        "inline-flex items-center gap-1 rounded-full py-0.5 pl-2 text-xs font-medium ring-1",
        @active_cls,
        if(@removable, do: "pr-1", else: "pr-2.5")
      ]}
    >
      <.icon name={@icon_name} class={["size-3.5", @color]} />
      {@label}
      <button
        :if={@removable}
        type="button"
        phx-click="toggle_flag"
        phx-value-flag={@flag}
        class="rounded-full p-0.5 opacity-60 transition hover:bg-base-content/10 hover:opacity-100"
        title={"Remove “#{@label}”"}
        aria-label={"Remove the flag #{@label}"}
        {@rest}
      >
        <.icon name="hero-x-mark" class="size-3" />
      </button>
    </span>
    """
  end

  attr :can_write, :boolean, required: true
  attr :card, Card, required: true
  attr :target, :any, required: true
  attr :uploads, :map, required: true

  attr :at, :string,
    default: nil,
    doc:
      "where a search result points (`transcript-5-part-2`): that transcript opens at that part"

  attr :transcribe, :boolean,
    default: false,
    doc: "whether a transcription server is set up, so recordings offer Transcribe"

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
        <h3 class="flex items-center gap-1.5 section-label">
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
          class={[
            "group flex flex-wrap items-center gap-3 rounded-xl bg-base-200/70 p-2",
            Attachment.audio?(a) && "sm:col-span-2"
          ]}
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
            <label
              :if={Attachment.image?(a)}
              class={[
                "mt-0.5 flex items-center gap-1.5 text-xs text-base-content/60",
                @can_write && "cursor-pointer"
              ]}
              title="The card's front shows the first image that isn't ticked here, unless Display leaves images out"
            >
              <input
                type="checkbox"
                id={"hide-on-card-#{a.id}"}
                class="checkbox"
                checked={a.hide_on_card}
                disabled={!@can_write}
                phx-target={@target}
                phx-click="hide_on_card"
                phx-value-id={a.id}
                phx-value-hide={to_string(!a.hide_on_card)}
              /> Don't show on the card front
            </label>
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
          <%!-- A recording plays where it is. preload="metadata" fetches its
                length and no more until somebody presses play. --%>
          <audio
            :if={Attachment.audio?(a)}
            id={"audio-#{a.id}"}
            controls
            preload="metadata"
            src={Boards.attachment_url(a)}
            class="h-9 min-w-0 flex-1 basis-60"
          ></audio>
          <button
            :if={Attachment.audio?(a) and @transcribe and @can_write}
            id={"transcribe-#{a.id}"}
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-xs shrink-0"
            phx-click="transcribe"
            phx-value-id={a.id}
            disabled={Transcription.running?(a)}
            title="Send the recording to the transcription server"
          >
            <span :if={Transcription.running?(a)} class="loading loading-spinner loading-xs"></span>
            <.icon :if={not Transcription.running?(a)} name="hero-language" class="size-3.5" />
            {transcribe_label(a)}
          </button>
          <p
            :if={a.transcript_status == "failed" and not Transcription.running?(a)}
            id={"transcript-error-#{a.id}"}
            class="basis-full text-xs text-error"
          >
            Couldn't transcribe it: {a.transcript_error}
          </p>
          <details
            :if={a.transcript_status == "done"}
            id={"transcript-#{a.id}"}
            open={opened_at?(@at, a)}
            class="basis-full rounded-lg bg-base-100/70 px-2 py-1 text-sm"
          >
            <summary class="cursor-pointer text-xs font-medium text-base-content/60">
              Transcript
            </summary>
            <%!-- Silence is not an error: the server answers with no text. --%>
            <p :if={a.transcript in [nil, ""]} class="mt-1 text-xs text-base-content/50">
              No speech was found in the recording.
            </p>
            <%!-- Drawn in the parts search indexes it in, so a result can land
                  on the one that matched (see `SlipdockWeb.SearchLinks`). --%>
            <div :if={a.transcript not in [nil, ""]} class="mt-1 max-h-80 overflow-y-auto">
              <p
                :for={
                  {part, n} <-
                    Enum.with_index(Slipdock.Search.Chunk.transcript_parts(a.transcript), 1)
                }
                id={"transcript-#{a.id}-part-#{n}"}
                class={[
                  "whitespace-pre-wrap rounded",
                  @at == "transcript-#{a.id}-part-#{n}" && "bg-warning/15"
                ]}
                phx-no-format
              >{part}</p>
            </div>
          </details>
          <.document_text attachment={a} at={@at} target={@target} can_write={@can_write} />
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
      <%!-- With nothing attached, one line (#1728): a drop zone that is
            also the file picker's label. --%>
      <label
        :if={@card.attachments == [] and @uploads.attachment.entries == [] and @can_write}
        for={@uploads.attachment.ref}
        data-role="drop-zone"
        class="flex cursor-pointer items-center gap-2 truncate rounded-lg border border-dashed border-base-content/15 px-3 py-1.5 text-xs text-base-content/50 transition-colors hover:border-primary/40 hover:text-base-content/70"
        title="You can also paste images straight into the description or a comment"
      >
        <.icon name="hero-arrow-up-tray" class="size-3.5 shrink-0" />
        <span class="truncate">Drop files here or click to attach</span>
      </label>
    </section>
    """
  end

  defp opened_at?(at, a) when is_binary(at),
    do: String.starts_with?(at <> "-", "transcript-#{a.id}-")

  defp opened_at?(_at, _a), do: false

  # What was read from a PDF or an image (see `Slipdock.OCR`). Waiting in the
  # queue shows nothing: it is background work that nobody asked for, and a
  # file with no words in it simply never shows anything either.
  attr :attachment, :map, required: true
  attr :at, :any, default: nil
  attr :target, :any, required: true
  attr :can_write, :boolean, default: false

  defp document_text(%{attachment: %{document_text: %OCRText{} = read}} = assigns) do
    assigns = assign(assigns, read: read, a: assigns.attachment)

    ~H"""
    <p
      :if={@read.status == "running"}
      id={"document-reading-#{@a.id}"}
      class="basis-full text-xs text-base-content/50"
    >
      <span class="loading loading-spinner loading-xs"></span> Reading the text…
    </p>
    <p
      :if={@read.status == "failed"}
      id={"document-error-#{@a.id}"}
      class="basis-full text-xs text-error"
    >
      Couldn't read the text: {@read.error}
      <button
        :if={@can_write}
        id={"read-text-#{@a.id}"}
        phx-target={@target}
        type="button"
        class="link"
        phx-click="read_text"
        phx-value-id={@a.id}
      >
        Try again
      </button>
    </p>
    <details
      :if={OCRText.readable?(@read)}
      id={"document-#{@a.id}"}
      open={@at && String.starts_with?(@at <> "-", "document-#{@a.id}-")}
      class="basis-full rounded-lg bg-base-100/70 px-2 py-1 text-sm"
    >
      <summary class="cursor-pointer text-xs font-medium text-base-content/60">
        Text in this file <span :if={@read.truncated} class="font-normal">(the start of it)</span>
      </summary>
      <div class="mt-1 max-h-80 overflow-y-auto">
        <p
          :for={{part, n} <- Enum.with_index(Slipdock.Search.Chunk.document_parts(@read.text), 1)}
          id={"document-#{@a.id}-part-#{n}"}
          class={[
            "whitespace-pre-wrap rounded",
            @at == "document-#{@a.id}-part-#{n}" && "bg-warning/15"
          ]}
          phx-no-format
        >{part}</p>
      </div>
    </details>
    """
  end

  defp document_text(assigns), do: ~H""

  defp transcribe_label(a) do
    cond do
      Transcription.running?(a) -> "Transcribing…"
      a.transcript_status == "done" -> "Transcribe again"
      a.transcript_status == "failed" -> "Try again"
      true -> "Transcribe"
    end
  end

  @border_edges [
    {"all", "All", nil},
    {"top", "Top", :border_top},
    {"right", "Right", :border_right},
    {"bottom", "Bottom", :border_bottom},
    {"left", "Left", :border_left}
  ]

  attr :card, :map, required: true
  attr :target, :any, required: true

  @doc """
  A colour for each edge of the card's front (#1209), apart from its cover:
  a row of swatches per edge, and an "All" row that sets the four at once.
  Folded away until opened, unless the card already has one.
  """
  def borders_section(assigns) do
    card = assigns.card
    colours = Enum.map(Slipdock.Boards.Card.borders(), &Map.get(card, &1))
    same = if Enum.uniq(colours) |> length() == 1, do: hd(colours), else: :mixed

    assigns =
      assign(assigns,
        edges: @border_edges,
        any?: Enum.any?(colours),
        same: same
      )

    ~H"""
    <details id="card-borders" class="group space-y-1.5" open={@any?}>
      <summary class="cursor-pointer list-none section-label">
        Borders <.icon name="hero-chevron-down" class="size-3 transition group-open:rotate-180" />
      </summary>
      <div :for={{edge, label, field} <- @edges} class="flex items-center gap-2 pt-1.5">
        <span class="w-11 shrink-0 text-xs text-base-content/60">{label}</span>
        <div class="flex flex-wrap gap-1">
          <button
            phx-target={@target}
            type="button"
            class={[
              "flex size-5 items-center justify-center rounded-full ring-1 ring-base-content/20 ring-offset-1 ring-offset-base-100",
              edge_colour(@card, field, @same) == nil && "ring-2 ring-base-content"
            ]}
            phx-click="set_border"
            phx-value-edge={edge}
            phx-value-color=""
            title={"No #{String.downcase(label)} border"}
          >
            <.icon name="hero-no-symbol" class="size-3 opacity-50" />
          </button>
          <.color_swatch
            :for={{name, _} <- Palette.all()}
            phx-target={@target}
            color={name}
            selected={edge_colour(@card, field, @same) == name}
            phx-click="set_border"
            phx-value-edge={edge}
            phx-value-color={name}
            class="size-5"
          />
        </div>
      </div>
    </details>
    """
  end

  # The "All" row shows a colour only when the four edges agree on it.
  defp edge_colour(_card, nil, same), do: if(same == :mixed, do: :mixed, else: same)
  defp edge_colour(card, field, _same), do: Map.get(card, field)

  attr :name, :string, required: true, doc: "`data-prop`, for tests and the e2e script"
  attr :label, :string, required: true
  attr :for, :string, default: nil, doc: "the id of the value's own input, if it has one"
  attr :icon, :string, default: nil, doc: "a heroicon drawn before the label"
  attr :rest, :global
  slot :inner_block, required: true

  # One property on the card back (#1726): the label on the left, the value
  # on the right.
  defp prop_row(assigns) do
    ~H"""
    <div
      data-prop={@name}
      class="grid min-h-8 grid-cols-[5.5rem_minmax(0,1fr)] items-center gap-x-2"
      {@rest}
    >
      <label
        :if={@for}
        for={@for}
        data-role="prop-label"
        class="flex min-w-0 items-center gap-1 text-xs text-base-content/60"
      >
        <.icon :if={@icon} name={@icon} class="size-3.5 shrink-0" />
        <span class="truncate">{@label}</span>
      </label>
      <span
        :if={!@for}
        data-role="prop-label"
        class="flex min-w-0 items-center gap-1 text-xs text-base-content/60"
      >
        <.icon :if={@icon} name={@icon} class="size-3.5 shrink-0" />
        <span class="truncate">{@label}</span>
      </span>
      <div data-role="prop-value" class="min-w-0 text-sm">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :card, Card, required: true

  defp precision_row(assigns) do
    ~H"""
    <.prop_row name="precision" label="Precision" for="card-precision">
      <select name="card[date_precision]" class="select field-bare w-full" id="card-precision">
        <option
          :for={{key, label} <- Dates.precisions()}
          value={key}
          selected={key == (@card.date_precision || "day")}
        >
          {label}
        </option>
      </select>
    </.prop_row>
    <p :if={Card.fuzzy?(@card) and @card.due_date} class="pl-24 text-xs text-base-content/60">
      Scheduled for {Dates.range_label(
        @card.start_date || @card.due_date,
        @card.due_date,
        @card.date_precision
      )}
    </p>
    """
  end

  attr :board, :any, required: true
  attr :card, Card, required: true
  attr :loop, :map, default: nil, doc: "the runner loop holding the card (#2027)"
  attr :authors, :map, default: nil, doc: "who created it and changed it last (#2028)"
  attr :form, :any, required: true
  attr :target, :any, required: true
  attr :users, :list, required: true

  @doc """
  The card's properties (#1726) as label/value rows, the value bare until it
  is pointed at or focused. The list and Completed are not here: the meta
  line and the title's check are where those are changed. Drawn inside a
  form that sends `card_change`: the sidebar's, or on a phone the one under
  the title (`phone_properties/1`), never both.
  """
  def card_props(assigns) do
    ~H"""
    <div id="card-props" class="space-y-0.5">
      <.prop_row name="assignees" label="Assignees" id="card-assignees">
        <div class="flex min-w-0 flex-wrap items-center gap-1">
          <%!-- The runner loop holding the card (#2027): beside the people,
                never one of them, and gone when its job ends. --%>
          <SlipdockWeb.LoopComponents.loop_chip
            id="card-assignee-loop"
            loop={@loop}
            href={@loop && "#card-job-#{@loop.job_id}"}
          />
          <span
            :for={u <- Card.assignees(@card)}
            id={"card-assignee-#{u.id}"}
            class="inline-flex min-w-0 max-w-full items-center gap-1 rounded-full bg-base-200 py-0.5 pr-1 pl-0.5 [&>span:first-child]:min-w-0"
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
          </span>
          <%!-- Keyed on who is already on the card, so the picker comes
                back empty after each pick instead of re-sending the
                last one. --%>
          <select
            name="card[add_assignee_id]"
            class="select field-bare w-full min-w-0 flex-1 text-base-content/70"
            aria-label="Add an assignee"
            id={"card-assignee-add-" <> Enum.map_join(Card.assignees(@card), "-", & &1.id)}
          >
            <option value="" selected>
              {if Card.assignees(@card) == [], do: "Unassigned", else: "Add…"}
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
      </.prop_row>
      <.prop_row name="priority" label="Priority" for="card-priority">
        <select
          name="card[priority]"
          id="card-priority"
          class="select field-bare w-full"
        >
          <option
            :for={{label, value} <- priority_options()}
            value={value}
            selected={value == @card.priority}
          >
            {label}
          </option>
        </select>
      </.prop_row>
      <%!-- A simple board is a to-do list: % complete, Start, Precision
            and Health are project tracking, and stay out of its way
            (`Board.simple?/1`). --%>
      <.prop_row
        :if={not @board.simple}
        name="percent"
        label="% complete"
        for="card-percent-complete"
      >
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
            class="input field-bare w-16"
          />
          <progress
            :if={@card.percent_complete}
            class={[
              "progress h-1.5 min-w-0 flex-1",
              if(@card.percent_complete == 100,
                do: "progress-success",
                else: "progress-primary"
              )
            ]}
            value={@card.percent_complete}
            max="100"
          ></progress>
        </div>
      </.prop_row>
      <p :if={@form[:percent_complete].errors != []} class="text-xs text-error">
        Use a whole number from 0 to 100.
      </p>
      <.prop_row :if={not @board.simple} name="start" label="Start" icon={start_icon()}>
        <.date_field
          id={"card-start-date-#{@card.id}"}
          name="card[start_date]"
          value={@card.start_date}
          max={@card.due_date}
          bare
          class="w-full"
          aria-label="Start date"
        />
      </.prop_row>
      <%!-- The start in words (#1709): "Starts in 11 days", "Started 11
            days late". --%>
      <p
        :if={(not @board.simple and @card.start_date) && start_words(@card)}
        class="pl-24 text-xs text-base-content/60"
        data-role="start-words"
      >
        {start_words(@card)}
      </p>
      <.prop_row name="due" label="Due" icon={due_icon()}>
        <div class="flex min-w-0 flex-wrap items-center gap-1">
          <.date_field
            id={"card-due-date-#{@card.id}"}
            name="card[due_date]"
            value={@card.due_date}
            min={@card.start_date}
            bare
            class="min-w-0 flex-1"
            aria-label="Due date"
          />
          <%!-- The date is in the field: the badge only when it says
                more (overdue, due soon, done). --%>
          <.due_badge
            :if={due_state(@card.due_date, @card.completed) not in [nil, :later]}
            date={@card.due_date}
            completed={@card.completed}
          />
        </div>
      </.prop_row>
      <p :if={@form[:start_date].errors != []} class="text-xs text-error">
        Start must be on or before the due date.
      </p>
      <%!-- Precision matters only once it isn't "day": until then it is
            under More (a toggle the client keeps across patches). --%>
      <.precision_row
        :if={not @board.simple and (@card.date_precision || "day") != "day"}
        card={@card}
      />
      <.prop_row :if={not @board.simple} name="health" label="Health" id="card-status">
        <div
          class="flex flex-wrap items-center gap-1.5"
          aria-describedby="card-health-about"
        >
          <.health_pill health={Card.health(@card)} />
          <.stated_pill
            :if={Card.stated_health(@card)}
            health={Card.stated_health(@card)}
            title="Last reported on the card"
          />
          <span
            id="card-health-about"
            class="inline-flex text-base-content/50"
            title={health_about(Card.stated_health(@card))}
          >
            <.icon name="hero-information-circle" class="size-4" />
            <span class="sr-only">{health_about(Card.stated_health(@card))}</span>
          </span>
        </div>
      </.prop_row>
      <div :if={not @board.simple and (@card.date_precision || "day") == "day"}>
        <button
          type="button"
          id="card-props-more-toggle"
          aria-expanded="false"
          aria-controls="card-props-more"
          phx-click={
            JS.toggle_attribute({"hidden", "hidden"}, to: "#card-props-more")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          }
          class="btn btn-ghost btn-xs gap-1 px-1 font-normal text-base-content/60"
        >
          More <.icon name="hero-chevron-down" class="size-3" />
        </button>
        <div id="card-props-more" hidden>
          <.precision_row card={@card} />
        </div>
      </div>
      <.card_authors :if={@authors} authors={@authors} />
    </div>
    """
  end

  attr :authors, :map, required: true

  # Who made the card and who changed it last (#2028), read-only, under its
  # properties: "Created by Robin, 3 days ago", "Last changed by Dev server
  # loop, 2 minutes ago". Nobody recorded is the time alone, never a guess.
  defp card_authors(assigns) do
    ~H"""
    <div id="card-authors" class="space-y-0.5 px-1 pt-2 text-xs text-base-content/50">
      <p id="card-created-by">
        <.author_line
          verb="Created"
          who={@authors.created_by}
          at={@authors.created_at}
          id="card-created-by-at"
        />
      </p>
      <p id="card-changed-by">
        <.author_line
          verb="Last changed"
          who={@authors.updated_by}
          at={@authors.updated_at}
          id="card-changed-by-at"
        />
      </p>
    </div>
    """
  end

  attr :verb, :string, required: true
  attr :who, :map, default: nil
  attr :at, :any, required: true
  attr :id, :string, required: true

  defp author_line(%{who: nil} = assigns) do
    ~H"""
    {@verb} <.timestamp id={@id} at={@at} />
    """
  end

  defp author_line(assigns) do
    ~H"""
    {@verb} by <span class="font-medium text-base-content/70" data-author-kind={@who.kind}>{@who.name}</span>,
    <.timestamp
      id={@id}
      at={@at}
    />
    """
  end

  attr :board, :any, required: true
  attr :card, Card, required: true
  attr :loop, :map, default: nil, doc: "the runner loop holding the card (#2027)"
  attr :authors, :map, default: nil, doc: "who created it and changed it last (#2028)"
  attr :form, :any, required: true
  attr :target, :any, required: true
  attr :users, :list, required: true

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
        <span data-summary="assignee" class="inline-flex min-w-0 items-center gap-1">
          <.icon name="hero-user" class="size-4 shrink-0 text-base-content/50" />
          <span class="truncate">
            {case Card.assignees(@card) do
              [] -> "Unassigned"
              people -> Enum.map_join(people, ", ", &Slipdock.Accounts.User.display_name/1)
            end}
          </span>
        </span>
        <span data-summary="due" class="inline-flex items-center gap-1">
          <.icon name="hero-calendar" class="size-4 shrink-0 text-base-content/50" />
          {if @card.due_date,
            do: "Due #{SlipdockWeb.Dates.short(@card.due_date)}",
            else: "No due date"}
        </span>
        <span data-summary="priority" class="inline-flex items-center gap-1">
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

  @doc "The panel's sidebar: the properties (assignees, priority, dates, health), time, fields, votes, cover, borders, repeat and snooze."
  def card_sidebar(assigns) do
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
          />
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
        </.form>
        <.time_section
          :if={not @board.simple}
          target={@target}
          card={@card}
          can_write={@can_write}
          form_key={@form_key}
        />
      </fieldset>
      <fieldset :if={not @board.simple} disabled={!@can_comment} class="min-w-0">
        <.status_section
          target={@target}
          item={@card}
          can_write={@can_write}
          can_comment={@can_comment}
          form_key={@form_key}
          stated={Card.stated_health(@card)}
        />
      </fieldset>
      <fieldset :if={@board.fields != []} disabled={!@can_write} class="min-w-0">
        <.fields_section target={@target} item={@card} board={@board} can_write={@can_write} />
      </fieldset>
      <fieldset :if={not @board.simple} disabled={!@can_comment} class="min-w-0">
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
        <div class="space-y-1.5">
          <span class="section-label">Cover</span>
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

        <.borders_section card={@card} target={@target} />

        <.repeat_section card={@card} repeat={@repeat} target={@target} />

        <.snooze_section card={@card} can_write={@can_write} current_user={@current_user} />
      </fieldset>
    </aside>
    """
  end

  attr :card, Card, required: true
  attr :can_write, :boolean, required: true
  attr :current_user, :any, default: nil

  # Snooze (W-1803): until when, and why; Snooze… opens the board's picker
  # and Wake now brings it back. Both are the board view's events, so they
  # carry no target.
  defp snooze_section(assigns) do
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
  attr :repeat, :map, default: nil
  attr :target, :any, required: true

  # Repeat (W-1802): how the card recurs and what is next, or the Repeat…
  # form — presets for the card's date, a rule of one's own, the time, how
  # early, what a missed one does and when it ends — with what it would do
  # (in words, and the next three dates) before it is saved.
  defp repeat_section(assigns) do
    assigns = assign(assigns, series: Card.recurrence(assigns.card))

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

  # The Health pills' tooltip (#1699): what each one means, kept off the page.
  defp health_about(nil), do: "Worked out from the card's dates, blockers and subcards."

  defp health_about(_stated),
    do:
      "The first is worked out from the card's dates, blockers and subcards. " <>
        "The second is what was last reported."
end
