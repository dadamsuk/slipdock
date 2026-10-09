defmodule SlipdockWeb.MeetingLive.ReviewComponents do
  @moduledoc """
  The review of a capture (screen 5): the transcript on the left — unsure
  words underlined, long gaps shown, lines whose speaker is unsure marked —
  and what was found on the right, each finding with its kind, its evidence
  (highlighted in the transcript when it is selected), its signals as words,
  what Slipdock already knew, its questions inline and what it *becomes*.

  On a phone it is one column, with the transcript behind a toggle.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.MeetingLive.Components, only: [clock: 1]

  alias Slipdock.Meetings.{Describe, Review, Verify}

  # A silence this long between two lines is shown as a gap.
  @gap_ms 30_000
  # A word the transcriber was less sure of than this is underlined.
  @unsure_below 0.6

  attr :capture, :any, required: true
  attr :kept, :list, required: true
  attr :dropped, :list, required: true
  attr :selected, :any, required: true
  attr :editing, :any, required: true
  attr :adding, :boolean, required: true
  attr :open_count, :integer, required: true
  attr :can_write, :boolean, required: true
  attr :narrow?, :boolean, default: false
  attr :show_transcript, :boolean, default: false
  attr :members, :list, default: []
  attr :lists, :list, default: []
  attr :error, :any, default: nil

  def review(assigns) do
    selected = Enum.find(assigns.kept, &(&1.id == assigns.selected))
    lit = if selected, do: MapSet.new(selected.evidence, & &1.line_id), else: MapSet.new()
    assigns = assign(assigns, lit: lit, reviewable?: Review.reviewable?(assigns.capture))

    ~H"""
    <div
      id="review"
      data-layout={if @narrow?, do: "one-column", else: "two-columns"}
      phx-window-keydown={@can_write && @reviewable? && "key"}
      class="space-y-4"
    >
      <div
        id="review-bar"
        class="sticky top-0 z-10 flex flex-wrap items-center gap-3 rounded-xl bg-base-100/95 px-4 py-2 shadow-sm ring-1 ring-base-content/10 backdrop-blur"
      >
        <span :if={@open_count > 0} id="open-questions" class="text-sm">
          <.icon name="hero-question-mark-circle" class="size-4 text-warning" />
          {@open_count} {if @open_count == 1, do: "question", else: "questions"} to settle
        </span>
        <span :if={@open_count == 0 and @reviewable?} class="text-sm text-success">
          <.icon name="hero-check-circle" class="size-4" /> Nothing left to settle
        </span>
        <span class="flex-1"></span>
        <.link
          :if={@capture.voices != []}
          id="who-said-what"
          navigate={"/boards/#{@capture.board_id}/meetings/#{@capture.id}/speakers"}
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-users" class="size-4" /> Who said what
        </.link>
        <button
          :if={@narrow?}
          id="toggle-transcript"
          type="button"
          phx-click="toggle_transcript"
          class="btn btn-ghost btn-sm"
          aria-expanded={to_string(@show_transcript)}
        >
          <.icon name="hero-document-text" class="size-4" />
          {if @show_transcript, do: "Findings", else: "Transcript"}
        </button>
        <button
          :if={@can_write and (@reviewable? or Slipdock.Meetings.Commit.pending?(@capture))}
          id="commit-capture"
          type="button"
          phx-click="commit"
          disabled={@open_count > 0 or not Slipdock.Meetings.Commit.committable?(@capture)}
          class="btn btn-primary btn-sm"
          title={
            if @open_count > 0,
              do: "Settle the open questions first",
              else: "See exactly what will be written"
          }
        >
          Commit…
        </button>
      </div>

      <p
        :if={@error}
        id="review-error"
        role="alert"
        class="rounded-xl bg-error/10 px-4 py-2 text-sm text-error"
      >
        {@error}
      </p>

      <div class={["grid gap-4", !@narrow? && "lg:grid-cols-2"]}>
        <section
          :if={!@narrow? or @show_transcript}
          id="review-transcript"
          class="min-w-0 rounded-xl bg-base-100 ring-1 ring-base-content/10 lg:max-h-[70vh] lg:overflow-y-auto"
        >
          <h2 class="border-b border-base-content/10 px-4 py-2 text-sm font-medium">Transcript</h2>
          <ol class="text-sm">
            <%= for {u, gap} <- with_gaps(@capture.utterances) do %>
              <li :if={gap} class="px-4 py-1 text-center text-2xs text-base-content/40">
                — {clock(gap)} with nothing said —
              </li>
              <li
                id={"line-#{u.line_id}"}
                data-highlight={to_string(MapSet.member?(@lit, u.line_id))}
                class={[
                  "flex gap-3 px-4 py-1.5",
                  MapSet.member?(@lit, u.line_id) && "bg-warning/15"
                ]}
              >
                <span class="w-12 shrink-0 font-mono text-2xs text-base-content/40">{clock(u.start_ms)}</span>
                <span class="min-w-0 break-words">
                  <span :if={u.speaker} class="font-medium">{u.speaker}</span>
                  <span
                    :if={u.voice_unsure}
                    class="badge badge-ghost badge-xs"
                    title="Whose voice this is isn't certain"
                  >
                    voice unsure
                  </span>
                  <span :if={u.speaker}>: </span>{words(u)}
                </span>
              </li>
            <% end %>
          </ol>
        </section>

        <section :if={!@narrow? or !@show_transcript} id="review-findings" class="min-w-0 space-y-3">
          <p
            :if={@kept == []}
            class="rounded-xl bg-base-100 p-4 text-sm text-base-content/60 ring-1 ring-base-content/10"
          >
            The readings found nothing in this meeting to write down.
          </p>

          <.finding_card
            :for={f <- @kept}
            finding={f}
            selected={f.id == @selected}
            editing={f.id == @editing}
            questions={Enum.filter(@capture.questions, &(&1.finding_id == f.id))}
            can_write={@can_write and @reviewable?}
            lists={@lists}
            members={@members}
            board_id={@capture.board_id}
          />

          <div :if={@can_write and @reviewable?}>
            <button
              :if={!@adding}
              id="start-add"
              type="button"
              phx-click="start_add"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-plus" class="size-4" /> Add something the transcript missed
            </button>
            <.add_form :if={@adding} lists={@lists} members={@members} />
          </div>

          <details
            :if={@dropped != []}
            id="dropped-findings"
            class="rounded-xl bg-base-100 p-3 text-sm ring-1 ring-base-content/10"
          >
            <summary class="cursor-pointer text-base-content/70">
              Dropped ({length(@dropped)}): their words are not in the transcript
            </summary>
            <ul class="mt-2 space-y-1">
              <li :for={f <- @dropped} id={"dropped-#{f.id}"} class="text-base-content/60">
                <span class="line-through">{f.title}</span> — {f.drop_reason}
              </li>
            </ul>
          </details>
        </section>
      </div>
    </div>
    """
  end

  attr :capture, :any, required: true
  attr :board, :any, required: true
  attr :can_write, :boolean, required: true
  attr :conflicts, :any, default: nil

  @doc """
  What a commit wrote (screen 8): each change with a link to where it
  landed, Undo all (with what was edited since, when anything was), and
  who committed it when.
  """
  def receipt(assigns) do
    set = assigns.capture.change_set || %{}
    assigns = assign(assigns, changes: set["changes"] || [], undone: set["undone"])

    ~H"""
    <section id="receipt" class="rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10">
      <div class="flex flex-wrap items-center gap-3">
        <h2 class="flex-1 font-medium">
          <%= if @undone do %>
            Undone by {@undone["by"]}
          <% else %>
            Written to the board
          <% end %>
        </h2>
        <span class="text-xs text-base-content/60">
          committed by {(@capture.committed_by &&
                           (@capture.committed_by.name || @capture.committed_by.email)) || "—"}
          {@capture.committed_at && Calendar.strftime(@capture.committed_at, "%d %b %Y, %H:%M")}
        </span>
        <button
          :if={@can_write and is_nil(@capture.undone_at) and is_nil(@conflicts)}
          id="undo-all"
          type="button"
          phx-click="undo"
          data-confirm="Undo everything this capture wrote?"
          class="btn btn-outline btn-sm"
        >
          <.icon name="hero-arrow-uturn-left" class="size-4" /> Undo all
        </button>
      </div>

      <div :if={@conflicts} id="undo-conflicts" class="mt-3 rounded-lg bg-warning/10 p-3 text-sm">
        <p class="font-medium">
          Edited since the commit — undoing these would throw those edits away:
        </p>
        <ul class="mt-1 list-disc pl-5">
          <li :for={c <- @conflicts} data-conflict={c["id"]}>
            {c["ref"]} “{c["title"]}”: {c["why"]}
          </li>
        </ul>
        <div class="mt-2 flex gap-2">
          <button
            id="undo-rest"
            type="button"
            phx-click="undo"
            phx-value-rest="true"
            class="btn btn-warning btn-xs"
          >
            Undo the rest, keep these
          </button>
          <button id="undo-cancel" type="button" phx-click="cancel_undo" class="btn btn-ghost btn-xs">Cancel</button>
        </div>
      </div>

      <ul class="mt-3 space-y-1 text-sm">
        <li
          :for={c <- @changes}
          id={"written-#{c["id"]}"}
          class={[@undone && "line-through text-base-content/50"]}
        >
          <%= case c["op"] do %>
            <% "create_card" -> %>
              New card
              <.link
                :if={c["card_id"]}
                navigate={"/boards/#{c["board_id"]}/cards/#{c["card_id"]}"}
                class="link"
              >
                {c["ref"]} {c["title"]}
              </.link>
              <span class="text-base-content/60">in {c["list"]}</span>
            <% "update_card" -> %>
              Changed
              <.link navigate={"/boards/#{c["board_id"]}/cards/#{c["card_id"]}"} class="link">{c[
                "ref"
              ]} {c["title"]}</.link>
              <span class="text-base-content/60">({Enum.join(
                Map.keys(c["fields"]) -- ["column_id"],
                ", "
              )})</span>
            <% "comment" -> %>
              Commented on
              <.link navigate={"/boards/#{c["board_id"]}/cards/#{c["card_id"]}"} class="link">{c[
                "ref"
              ]} {c["title"]}</.link>
            <% "decision_entry" -> %>
              {length(c["lines_added"])} {if length(c["lines_added"]) == 1,
                do: "decision",
                else: "decisions"} on
              <.link navigate={"/boards/#{c["board_id"]}/wiki/#{c["page_slug"]}"} class="link">{c[
                "page_title"
              ]}</.link>
            <% _ -> %>
              {c["op"]}
          <% end %>
        </li>
      </ul>
    </section>
    """
  end

  attr :finding, :any, required: true
  attr :selected, :boolean, required: true
  attr :editing, :boolean, required: true
  attr :questions, :list, required: true
  attr :can_write, :boolean, required: true
  attr :lists, :list, required: true
  attr :members, :list, required: true
  attr :board_id, :integer, required: true

  defp finding_card(assigns) do
    ~H"""
    <article
      id={"finding-#{@finding.id}"}
      data-selected={to_string(@selected)}
      data-included={to_string(@finding.included)}
      class={[
        "rounded-xl bg-base-100 p-4 ring-1 transition",
        @selected && "ring-2 ring-primary",
        !@selected && "ring-base-content/10",
        !@finding.included && "opacity-60"
      ]}
    >
      <button
        type="button"
        phx-click="select"
        phx-value-id={@finding.id}
        class="block w-full text-left"
        aria-pressed={to_string(@selected)}
      >
        <span class="badge badge-sm mr-1">{kind_label(@finding.kind)}</span>
        <span class="font-medium">{@finding.title}</span>
      </button>

      <p :if={@finding.body} class="mt-1 text-sm text-base-content/70">{@finding.body}</p>

      <p
        :if={@finding.edited_by}
        id={"edited-#{@finding.id}"}
        class="mt-1 text-xs text-base-content/50"
      >
        edited by {@finding.edited_by.name || @finding.edited_by.email}
      </p>
      <p
        :if={@finding.origin == "person" and @finding.added_by}
        class="mt-1 text-xs text-base-content/50"
      >
        added by {@finding.added_by.name || @finding.added_by.email}, with no words from the meeting behind it
      </p>

      <ul :if={@finding.evidence != []} class="mt-2 space-y-1 text-sm">
        <li
          :for={e <- @finding.evidence}
          class="border-l-2 border-base-content/20 pl-2 italic text-base-content/80"
        >
          “{e.quote}”
          <span class="not-italic text-2xs text-base-content/50">— {e.speaker || "unnamed"}, {e.line_id}</span>
        </li>
      </ul>

      <ul id={"signals-#{@finding.id}"} class="mt-2 flex flex-wrap gap-1">
        <li :for={s <- @finding.signals} class="badge badge-ghost badge-xs" data-signal={s}>
          {Verify.signal_label(s)}
        </li>
      </ul>

      <div :if={@finding.known != []} class="mt-2 rounded-lg bg-base-200/60 px-3 py-2 text-xs">
        <p class="font-medium text-base-content/70">What Slipdock already knew</p>
        <ul class="mt-1 space-y-0.5">
          <li :for={k <- @finding.known}>{known_line(k)}</li>
        </ul>
      </div>

      <.question_block
        :for={q <- @questions}
        question={q}
        can_write={@can_write}
        board_id={@board_id}
      />

      <p class="mt-3 text-sm">
        <span class="text-base-content/50">becomes →</span>
        <span id={"becomes-#{@finding.id}"}>{Describe.becomes(@finding)}</span>
      </p>

      <.edit_form :if={@editing} finding={@finding} lists={@lists} />

      <div :if={@can_write and not @editing} class="mt-3 flex flex-wrap gap-2">
        <button
          :if={!@finding.included}
          id={"include-#{@finding.id}"}
          type="button"
          phx-click="include"
          phx-value-id={@finding.id}
          phx-value-included="true"
          class="btn btn-outline btn-xs"
        >
          Include
        </button>
        <button
          :if={@finding.included}
          id={"leave-out-#{@finding.id}"}
          type="button"
          phx-click="include"
          phx-value-id={@finding.id}
          phx-value-included="false"
          class="btn btn-ghost btn-xs"
        >
          Leave out
        </button>
        <button
          id={"edit-#{@finding.id}"}
          type="button"
          phx-click="edit"
          phx-value-id={@finding.id}
          class="btn btn-ghost btn-xs"
        >
          Edit
        </button>
      </div>
    </article>
    """
  end

  attr :question, :any, required: true
  attr :can_write, :boolean, required: true
  attr :board_id, :integer, required: true

  defp question_block(assigns) do
    ~H"""
    <div
      id={"question-#{@question.id}"}
      data-status={@question.status}
      class={[
        "mt-3 rounded-lg px-3 py-2 text-sm",
        @question.status == "open" && "bg-warning/10 ring-1 ring-warning/40",
        @question.status != "open" && "bg-base-200/60"
      ]}
    >
      <p class="font-medium">
        {@question.prompt}
        <.link
          :if={@question.status in ["open", "waiting"]}
          id={"resolve-link-#{@question.id}"}
          navigate={"/boards/#{@board_id}/meetings/#{@question.capture_id}/resolve/#{@question.id}"}
          class="link ml-1 text-xs font-normal"
        >
          listen and resolve
        </.link>
      </p>
      <p :if={@question.status == "waiting"} class="mt-1 text-xs text-warning">
        Asked the speaker; waiting for their answer. The rest can be committed meanwhile.
      </p>
      <div :if={@question.status == "open"} class="mt-2 flex flex-wrap gap-2">
        <button
          :for={{option, i} <- Enum.with_index(@question.options, 1)}
          :if={@can_write}
          id={"answer-#{@question.id}-#{i}"}
          type="button"
          phx-click="answer"
          phx-value-question={@question.id}
          phx-value-value={option["value"]}
          class="btn btn-outline btn-xs"
          title={option["effect"]}
        >
          <kbd :if={i <= 4} class="mr-1 font-mono text-2xs opacity-60">{i}</kbd>{option["label"]}
        </button>
        <span :if={!@can_write} class="text-xs text-base-content/60">Waiting for somebody who can edit the board.</span>
      </div>
      <p :if={@question.status != "open"} class="mt-1 text-xs text-base-content/70">
        {@question.answer && @question.answer["label"]}
        <span :if={@question.answered_by}>
          — {@question.answered_by.name || @question.answered_by.email}{if @question.via == "agent",
            do: " via agent"}
        </span>
        <button
          :if={@can_write}
          id={"unanswer-#{@question.id}"}
          type="button"
          phx-click="unanswer"
          phx-value-question={@question.id}
          class="link ml-2"
        >
          change
        </button>
      </p>
    </div>
    """
  end

  attr :finding, :any, required: true
  attr :lists, :list, required: true

  defp edit_form(assigns) do
    ~H"""
    <form id={"edit-form-#{@finding.id}"} phx-submit="save_edit" class="mt-3 space-y-2">
      <input type="hidden" name="finding[id]" value={@finding.id} />
      <input
        type="text"
        name="finding[title]"
        value={@finding.title}
        class="input input-sm w-full"
        aria-label="Title"
        maxlength="255"
      />
      <textarea name="finding[body]" class="textarea textarea-sm w-full" rows="2" aria-label="Detail">{@finding.body}</textarea>
      <div :if={@finding.effect["type"] == "new_card"} class="grid gap-2 sm:grid-cols-2">
        <select name="finding[list]" class="select select-sm" aria-label="List">
          <option :for={l <- @lists} value={l.name} selected={l.name == @finding.effect["list"]}>
            {l.name}
          </option>
        </select>
        <input
          type="date"
          name="finding[due_date]"
          value={@finding.effect["due_date"]}
          class="input input-sm"
          aria-label="Due"
        />
      </div>
      <input
        :if={@finding.effect["type"] == "decision_entry"}
        type="text"
        name="finding[topic]"
        value={@finding.effect["topic"]}
        class="input input-sm w-full"
        aria-label="Topic"
      />
      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary btn-xs">Save</button>
        <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-xs">Cancel</button>
      </div>
    </form>
    """
  end

  attr :lists, :list, required: true
  attr :members, :list, required: true

  defp add_form(assigns) do
    ~H"""
    <form
      id="add-form"
      phx-submit="add"
      class="space-y-2 rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10"
    >
      <p class="text-sm font-medium">Something the transcript missed</p>
      <select name="added[kind]" class="select select-sm" aria-label="Kind">
        <option value="action">Action (a new card)</option>
        <option value="decision">Decision</option>
      </select>
      <input
        type="text"
        name="added[title]"
        required
        class="input input-sm w-full"
        placeholder="What it is"
        maxlength="255"
      />
      <textarea
        name="added[body]"
        class="textarea textarea-sm w-full"
        rows="2"
        placeholder="Detail (optional)"
      ></textarea>
      <div class="grid gap-2 sm:grid-cols-3">
        <select name="added[list]" class="select select-sm" aria-label="List">
          <option :for={l <- @lists} value={l.name}>{l.name}</option>
        </select>
        <select name="added[assignee_id]" class="select select-sm" aria-label="Who">
          <option value="">Nobody yet</option>
          <option :for={m <- @members} value={m.id}>{m.name || m.email}</option>
        </select>
        <input type="date" name="added[due_date]" class="input input-sm" aria-label="Due" />
      </div>
      <input
        type="text"
        name="added[topic]"
        class="input input-sm w-full"
        placeholder="Topic, for a decision (e.g. Pricing)"
      />
      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary btn-xs">Add</button>
        <button type="button" phx-click="cancel_add" class="btn btn-ghost btn-xs">Cancel</button>
      </div>
    </form>
    """
  end

  defp kind_label("card_change"), do: "change to a card"
  defp kind_label("open_question"), do: "open question"
  defp kind_label(kind), do: kind

  defp known_line(%{"answers" => true} = k),
    do: "#{k["ref"]} “#{k["title"]}” already answers it#{summary(k)}"

  defp known_line(%{"superseded" => true} = k),
    do: "Replaces the earlier decision “#{k["title"]}”"

  defp known_line(k) do
    details =
      [
        k["list"] && "in #{k["list"]}",
        k["done"] && "done",
        k["assignees"] not in [nil, []] && "for #{Enum.join(k["assignees"], ", ")}",
        k["due"] && "due #{Describe.date(k["due"])}"
      ]
      |> Enum.filter(&is_binary/1)

    "#{k["ref"]} “#{k["title"]}”" <>
      if(details == [], do: "", else: " — " <> Enum.join(details, ", "))
  end

  defp summary(%{"summary" => s}) when is_binary(s) and s != "", do: ": #{s}"
  defp summary(_), do: ""

  # Each line, with the silence before it when that was long.
  defp with_gaps(utterances) do
    {pairs, _} =
      Enum.map_reduce(utterances, nil, fn u, prev_end ->
        gap =
          if prev_end && u.start_ms && u.start_ms - prev_end >= @gap_ms,
            do: u.start_ms - prev_end,
            else: nil

        {{u, gap}, u.end_ms || u.start_ms || prev_end}
      end)

    pairs
  end

  # The words, with any the transcriber was unsure of underlined.
  defp words(%{words: words} = u) when is_list(words) and words != [] do
    assigns = %{words: words, text: u.text}

    ~H"""
    <%= for w <- @words do %>
      <span
        :if={(w["confidence"] || 1.0) < unsure_below()}
        class="underline decoration-warning decoration-dotted"
        title="The transcriber was unsure of this word"
        data-unsure="true"
      >{w["word"]}</span>
      <span :if={(w["confidence"] || 1.0) >= unsure_below()}>{w["word"]}</span>
    <% end %>
    """
  end

  defp words(u), do: u.text

  defp unsure_below, do: @unsure_below
end
