defmodule SlipdockWeb.BoardLive.CardComponent.Glance do
  @moduledoc """
  The card panel's block beneath the title: the step the card is at, where
  it was left or how it ended, where it has shipped, the note and its
  history, and the form the note is written in.

  Function components: they draw what `BoardLive.CardComponent` holds and
  send their events to it.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents

  alias Slipdock.Boards
  alias Slipdock.Boards.Card

  # The card's handoff: nil if none was written or the newest is a clear.
  @doc false
  def current_handoff(%Card{handoff: %Slipdock.Boards.Handoff{} = h}),
    do: if(Slipdock.Boards.Handoff.cleared?(h), do: nil, else: h)

  def current_handoff(_), do: nil

  # Whether the glance block has anything to show: a handoff, a step
  # status, a shipped line, or a finished card's outcome.
  # `deliveries`: its shipped and deploy-failed lines.
  @doc false
  def glance?(card, deliveries) do
    current_handoff(card) != nil or latest_step(card) != nil or deliveries != [] or
      card.completed
  end

  defp latest_step(%Card{status_updates: [latest | _]}), do: latest
  defp latest_step(_card), do: nil

  attr :card, :any, required: true
  attr :label, :string, default: "Left off", doc: "what the board calls it (#1212)"
  attr :history, :list, required: true
  attr :editing, :boolean, required: true
  attr :form, :any, default: nil
  attr :draft, :any, default: nil, doc: "Auto generate: nil, :running, :done or {:error, why}"
  attr :ai?, :boolean, default: false, doc: "the reader has a model, so Auto generate is offered"
  attr :can_comment, :boolean, required: true
  attr :can_write, :boolean, default: false
  attr :current_user, :any, default: nil
  attr :users, :list, default: [], doc: "the board's people, to name who stated a status"
  attr :shipped, :list, default: [], doc: "`Slipdock.Deployments.shipped/1`"
  attr :deploy_failed, :list, default: [], doc: "`Slipdock.Deployments.deploy_failed/1`"
  attr :release, :map, default: nil, doc: "`Slipdock.Releases.state/1`"
  attr :not_shipped, :any, default: nil, doc: "`Slipdock.Deployments.NotShipped.for_card/2`"
  attr :board, :any, default: nil
  attr :target, :any, required: true

  # At a glance, beneath the title (#2022), in this order: the status row
  # (health, the latest step, when, who), the next step (an open card) or
  # the outcome (a finished one), the shipped lines, then the note,
  # collapsed past a few lines, with its byline last and quieter. A
  # finished card folds the handoff written before it finished away as
  # history; one left after it is what is still to do. While being written,
  # the form, with the history under it.
  def handoff_panel(assigns) do
    handoff = current_handoff(assigns.card)
    zone = Slipdock.Timezones.of(assigns.current_user)
    outcome = Slipdock.CardOutcome.of(assigns.card)
    folded? = handoff != nil and Slipdock.CardOutcome.before_finish?(assigns.card, handoff)
    current = if folded?, do: nil, else: handoff
    body = handoff_prose(current && current.body)

    assigns =
      assign(assigns,
        current: current,
        folded: if(folded?, do: handoff),
        step: latest_step(assigns.card),
        zone: zone,
        outcome: Slipdock.CardOutcome.text(outcome, zone),
        body: body,
        long_body: long_note?(body),
        can_delete:
          assigns.can_comment && current != nil &&
            Boards.Handoffs.may_delete_handoff?(current, assigns.current_user, assigns.can_write)
      )

    ~H"""
    <section id="card-handoff" class="ml-1 min-w-0 space-y-1.5 border-l-2 border-info/40 pl-3">
      <p
        :if={@step && !@editing}
        id="glance-status"
        class="flex flex-wrap items-center gap-x-1.5 gap-y-0.5 text-xs text-base-content/60"
      >
        <.stated_pill health={@step.health} />
        <span :if={@step.body} id="glance-step" class="min-w-0 break-words text-base-content/80">
          {@step.body}
        </span>
        <span aria-hidden="true">·</span>
        <.timestamp at={@step.inserted_at} id="glance-step-at" zone={@zone} />
        <span aria-hidden="true">·</span>
        <span id="glance-step-by">{step_by(@step, @users)}</span>
      </p>
      <%!-- `handoff-current` while there is a current note, as before. --%>
      <div
        :if={!@editing}
        id={if @current, do: "handoff-current", else: "glance-main"}
        class="space-y-1"
      >
        <p :if={@outcome} id="card-outcome" class="flex items-start gap-1.5 text-sm">
          <.icon name="hero-check-circle" class="mt-0.5 size-3.5 shrink-0 text-success" />
          <span class="min-w-0 break-words font-medium">{@outcome}</span>
        </p>
        <p :if={@current} id="handoff-line" class="flex items-start gap-1.5 text-sm">
          <.icon name="hero-arrow-uturn-left" class="mt-0.5 size-3.5 shrink-0 text-info" />
          <span class="min-w-0 break-words">
            <span class="text-base-content/60" id="handoff-label">
              {@label} — {if @outcome, do: "still to do:", else: "next:"}
            </span>
            <span class="font-medium" id="handoff-next">{@current.next_step}</span>
          </span>
        </p>
        <%!-- Batched releases (#2834): merged and waiting for a release,
              or the release that shipped it, with the time. --%>
        <p
          :if={@release}
          id="card-release"
          data-state={@release.state}
          class={[
            "flex items-start gap-1.5 text-xs",
            if(@release.state == "released", do: "text-success", else: "text-warning")
          ]}
        >
          <.icon
            name={if @release.state == "released", do: "hero-rocket-launch", else: "hero-clock"}
            class="mt-px size-3.5 shrink-0"
          />
          <span class="min-w-0 break-words">{Slipdock.Releases.text(@release, @zone)}</span>
        </p>
        <%!-- Where the card has shipped (#1134): one line per
              environment, latest first, with the time (#2022). --%>
        <ul :if={@shipped != []} id="card-shipped" class="space-y-0.5 text-xs">
          <li
            :for={s <- @shipped}
            class={[
              "flex items-start gap-1.5",
              if(s.rolled_back, do: "text-warning", else: "text-success")
            ]}
          >
            <.icon
              name={if s.rolled_back, do: "hero-arrow-uturn-left", else: "hero-rocket-launch"}
              class="mt-px size-3.5 shrink-0"
            />
            <span class="min-w-0 break-words">{Slipdock.Deployments.shipped_text(s, @zone)}</span>
          </li>
        </ul>
        <%!-- Where its latest deploy attempt failed (#2820), with the
              run; a later succeeded deploy takes the line away. --%>
        <ul :if={@deploy_failed != []} id="card-deploy-failed" class="space-y-0.5 text-xs">
          <li :for={f <- @deploy_failed} class="flex items-start gap-1.5 text-error">
            <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
            <span class="min-w-0 break-words">
              Deploy failed{if f.stage, do: " at #{f.stage}"} · {f.environment} ·
              <a
                :if={f.run_url}
                href={f.run_url}
                target="_blank"
                rel="noopener noreferrer"
                class="link"
              >run</a>
              <span :if={f.run_url} aria-hidden="true">·</span>
              {Slipdock.Deployments.time_text(f.at, @zone)}
            </span>
          </li>
        </ul>
        <%!-- Merged, and no succeeded deploy names it after the board's
              minutes (#2819): amber, until one does. --%>
        <p
          :if={@not_shipped}
          id="card-not-shipped"
          class="flex items-start gap-1.5 text-xs text-warning"
        >
          <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
          <span class="min-w-0 break-words">{@not_shipped.text}</span>
        </p>
        <%!-- Markdown, as a comment is (#1214): agents write it as bullets,
              and a single newline is still a line break for the template.
              Past a few lines it folds, with Show more. --%>
        <div :if={@current && @body} class="min-w-0">
          <input
            :if={@long_body}
            type="checkbox"
            id="handoff-more"
            class="peer sr-only"
            aria-label="Show the whole note"
          />
          <div
            id="handoff-body"
            class={[
              "card-prose break-words text-xs text-base-content/70",
              @long_body && "max-h-[5.5rem] overflow-hidden peer-checked:max-h-none"
            ]}
            phx-no-format
          >{SlipdockWeb.RichText.markdown(@body, board: @board, as: @current_user)}</div>
          <label
            :if={@long_body}
            for="handoff-more"
            id="handoff-more-toggle"
            class="link link-hover cursor-pointer text-2xs text-base-content/60 peer-checked:[&>.more]:hidden [&>.less]:hidden peer-checked:[&>.less]:inline"
          >
            <span class="more">Show more</span><span class="less">Show less</span>
          </label>
        </div>
        <div
          :if={@current || @folded}
          id="handoff-byline"
          class="flex flex-wrap items-center gap-x-1.5 text-2xs text-base-content/50"
        >
          <span :if={@current}>{handoff_byline(@current)}</span>
          <span :if={@current && @can_comment}>·</span>
          <button
            :if={@can_comment}
            id="handoff-edit"
            type="button"
            class="link link-hover hover:text-primary"
            phx-click="edit_handoff"
            phx-target={@target}
          >
            {if @current, do: "Update", else: "Leave “#{@label}”"}
          </button>
          <span :if={@can_delete}>·</span>
          <button
            :if={@can_delete}
            id="handoff-delete"
            type="button"
            class="link link-hover hover:text-error"
            phx-click="delete_handoff"
            phx-target={@target}
            data-confirm={"Delete this “#{@label}”? It goes from the history too, and the one before it, if any, shows again."}
          >
            Delete
          </button>
        </div>
        <details :if={@folded} id="handoff-before-finish" class="text-xs">
          <summary class="cursor-pointer text-base-content/50">
            Last note before it finished · {handoff_byline(@folded)}
          </summary>
          <div class="mt-1 space-y-1 rounded bg-base-200/60 p-1.5">
            <p class="font-medium">{@folded.next_step}</p>
            <div
              :if={handoff_prose(@folded.body)}
              class="card-prose break-words text-base-content/70"
              phx-no-format
            >{SlipdockWeb.RichText.markdown(handoff_prose(@folded.body), board: @board, as: @current_user)}</div>
          </div>
        </details>
        <.handoff_history
          :if={length(@history) > 1}
          history={@history}
          current={@current}
          can_restore={@can_comment}
          board={@board}
          current_user={@current_user}
          target={@target}
        />
      </div>

      <.form
        :if={@editing && @form}
        for={@form}
        id="handoff-form"
        phx-submit="leave_handoff"
        phx-target={@target}
        class="space-y-2"
      >
        <p id="handoff-form-title" class="flex items-center gap-1.5 text-sm text-base-content/60">
          <.icon name="hero-arrow-uturn-left" class="size-3.5 shrink-0 text-info" />
          {@label}
        </p>
        <%!-- Auto generate (#1099): a draft from the card's recent history,
              put in the fields below for the person to check and save. --%>
        <div :if={@ai?} class="flex flex-wrap items-center gap-2">
          <button
            id="handoff-draft"
            type="button"
            class="btn btn-ghost btn-xs gap-1"
            phx-click="draft_handoff"
            phx-target={@target}
            disabled={@draft == :running}
            title="Draft the next step and note from what has happened on this card lately"
          >
            <.icon
              name={if @draft == :running, do: "hero-arrow-path", else: "hero-sparkles"}
              class={["size-3.5", @draft == :running && "animate-spin"]}
            />
            {if @draft == :running, do: "Generating…", else: "Auto generate"}
          </button>
          <span :if={@draft == :done} id="handoff-draft-note" class="text-2xs text-base-content/50">
            Drafted from the card's recent history. Check it, then save.
          </span>
          <span
            :if={match?({:error, _}, @draft)}
            id="handoff-draft-error"
            class="text-2xs text-error"
          >
            {elem(@draft, 1)}
          </span>
        </div>
        <.input
          field={@form[:next_step]}
          label="Next step"
          placeholder="The one next step"
          maxlength="280"
          required
        />
        <.input
          field={@form[:body]}
          type="textarea"
          label="Note"
          rows="5"
          class="textarea field w-full"
          placeholder={Slipdock.Boards.Handoff.body_template()}
        />
        <div class="flex items-center gap-2">
          <button type="submit" id="handoff-save" class="btn btn-primary btn-xs">
            Save “{@label}”
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="cancel_handoff"
            phx-target={@target}
          >
            Cancel
          </button>
          <button
            :if={@current}
            id="handoff-clear"
            type="button"
            class="btn btn-ghost btn-xs ml-auto"
            phx-click="clear_handoff"
            phx-target={@target}
            data-confirm={"Clear “#{@label}”? The history keeps it."}
          >
            Clear
          </button>
        </div>
      </.form>

      <.handoff_history
        :if={@editing && @history != []}
        history={@history}
        current={@current}
        can_restore={@can_comment}
        board={@board}
        current_user={@current_user}
        target={@target}
      />
    </section>
    """
  end

  attr :history, :list, required: true
  attr :current, :any, default: nil, doc: "the handoff shown now, which isn't offered back"
  attr :can_restore, :boolean, default: false
  attr :board, :any, default: nil
  attr :current_user, :any, default: nil
  attr :target, :any, default: nil

  # Every handoff written, newest first. Each opens to its note, and an
  # earlier one can be made current again (#1214): Restore writes it anew.
  defp handoff_history(assigns) do
    ~H"""
    <details id="handoff-history" class="text-xs">
      <summary class="cursor-pointer text-base-content/50">History ({length(@history)})</summary>
      <ul class="mt-1 space-y-1">
        <li :for={h <- @history} id={"handoff-#{h.id}"} class="rounded bg-base-200/60 p-1.5">
          <span :if={!Slipdock.Boards.Handoff.cleared?(h)} class="font-medium">{h.next_step}</span>
          <span :if={Slipdock.Boards.Handoff.cleared?(h)} class="italic text-base-content/50">
            cleared
          </span>
          <span class="text-base-content/50">· {handoff_byline(h)}</span>
          <button
            :if={@can_restore and restorable?(h, @current)}
            type="button"
            class="link link-hover ml-1 text-base-content/50 hover:text-primary"
            phx-click="restore_handoff"
            phx-value-id={h.id}
            phx-target={@target}
            title="Make this the current one again"
          >
            Restore
          </button>
          <details :if={h.body} class="mt-0.5">
            <summary class="cursor-pointer text-base-content/50">Note</summary>
            <div class="card-prose break-words text-base-content/70" phx-no-format>{SlipdockWeb.RichText.markdown(h.body, board: @board, as: @current_user)}</div>
          </details>
        </li>
      </ul>
    </details>
    """
  end

  # A clear isn't restored (Clear does that), nor the one already current.
  defp restorable?(h, current),
    do: not Slipdock.Boards.Handoff.cleared?(h) and (is_nil(current) or current.id != h.id)

  defp handoff_byline(h) do
    who =
      cond do
        h.user -> Slipdock.Accounts.User.display_name(h.user)
        h.via == "runner" -> "a runner"
        true -> "someone"
      end

    job = if h.job_id, do: " · job ##{h.job_id}", else: ""
    "#{who} · #{relative_time(h.inserted_at)} · #{h.via}#{job}"
  end

  # Who stated a status: a person by name, the server's own steps (#2022)
  # as Slipdock.
  defp step_by(%{user_id: nil}, _users), do: "Slipdock"

  defp step_by(%{user_id: id}, users) do
    case Enum.find(users || [], &(&1.id == id)) do
      nil -> "someone"
      user -> Slipdock.Accounts.User.display_name(user)
    end
  end

  # The note without the runner's own lines (#2022): the transcript it sent
  # and how the job ended are the byline's and the job link's, not prose.
  @machine_lines [
    ~r/^\s*slipdock-runner: sending the transcript\b.*$/mu,
    ~r/^\s*Job #\d+ on .+ ended \w+(?: \(exit -?\d+\))?\.?\s*$/mu
  ]

  @doc false
  def handoff_prose(nil), do: nil

  def handoff_prose(body) when is_binary(body) do
    @machine_lines
    |> Enum.reduce(body, &Regex.replace(&1, &2, ""))
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> then(&if(&1 == "", do: nil, else: &1))
  end

  # A note long enough to fold: more than four lines, or a long paragraph.
  defp long_note?(nil), do: false

  defp long_note?(body),
    do: length(String.split(body, ~r/\R/)) > 4 or String.length(body) > 320
end
