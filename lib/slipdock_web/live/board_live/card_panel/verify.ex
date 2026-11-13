defmodule SlipdockWeb.BoardLive.CardPanel.Verify do
  @moduledoc """
  The card panel's verification markup: where an agent's completion stands
  (pending, accepted, rejected, merging) and the evidence it gave. Drawn by
  `BoardLive.CardPanel`, which passes each the assigns it reads, by name.
  """
  use SlipdockWeb, :html

  alias Slipdock.Boards.Card

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
          <span
            :if={@merge_status == :already_merged}
            id="card-merge-already-merged"
            class="text-warning"
          >
            Its merge job found the pull request already merged, but not at the accepted
            commit, so nothing was merged. Check what was merged; if it is the accepted
            work, press Merged it myself.
          </span>
          <span :if={@merge_status == :waiting} id="card-merge-waiting" class="text-warning">
            Merge waiting: its runner couldn't merge here and no other runner has taken it
            on. Fix that runner, or merge the pull request yourself and press Merged it myself.
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
end
