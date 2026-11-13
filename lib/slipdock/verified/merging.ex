defmodule Slipdock.Verified.Merging do
  @moduledoc """
  Merging an accepted card's pull request: queueing the merge job and
  choosing its pool, where a merging card stands, and what a merge job's
  end does to the card.
  """

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Verified.{Actors, Evidence, Jobs, Outcome, Shipping, Util}

  ## Merging (#1657) ------------------------------------------------------------

  @merge_kind "merge"

  @doc "The job kind that merges an accepted card's pull request (#1656, #1657)."
  def merge_kind, do: @merge_kind

  @doc """
  Queues the merge job for a card being merged (#1657), with no setting, to
  the pool `merge_pool/2` picks (`opts` go to it). With none, nothing is
  queued and the card says what to do. `{:ok, job}` or `:none`.
  """
  def queue_merge(%Card{} = card, user \\ nil, opts \\ []) do
    case merge_pool(card, opts) do
      nil ->
        Slipdock.Boards.Comments.add_comment(card, no_merger_text(card), by: user)
        :none

      pool ->
        case Slipdock.Runners.queue(card, %{
               pool: pool,
               kind: @merge_kind,
               prompt: merge_prompt(card),
               exclude_runner_id: opts[:exclude]
             }) do
          {:ok, job} ->
            {:ok, job}

          {:error, reason} ->
            Slipdock.Boards.Comments.add_comment(
              card,
              "**Merge job not queued** for pool `#{pool}`: #{reason}. " <>
                merge_by_hand_text(card),
              by: user
            )

            :none
        end
    end
  end

  @doc """
  The pool a card's merge job goes to (see `queue_merge/3`), or nil. Of the
  runners on the tree that take merge jobs, the first that applies (#1754):

    * one idle now (`Slipdock.Runners.idle?/1`), the builder's pool first:
      the merge goes at once, rather than waiting for a pass to end;
    * the runner that decided the card (`decider:`), about to finish its
      verify job;
    * the pool of the runner that built the card, else the most recently
      seen pool.

  `exclude:` leaves out a runner that couldn't merge here.
  """
  def merge_pool(%Card{} = card, opts \\ []) do
    capable = merge_runners(card, opts[:exclude])
    builder_pool = builder_pool(card)
    idle = for r <- capable, Slipdock.Runners.idle?(r), do: r.pool
    decider = Enum.find(capable, &(&1.id == opts[:decider]))

    pick_pool(builder_pool, idle, decider, Enum.map(capable, & &1.pool))
  end

  # The runners on the card's tree that take merge jobs, the most recently
  # seen first, less the one to leave out.
  defp merge_runners(card, exclude) do
    import Ecto.Query
    alias Slipdock.Runners.Runner

    root = Board.root_id(Util.board(card))

    from(r in Runner,
      where: r.board_id == ^root and fragment("'merge' = ANY(?)", r.kinds),
      order_by: [desc_nulls_last: r.last_seen_at, asc: r.id]
    )
    |> Repo.all()
    |> Enum.reject(&(&1.id == exclude))
  end

  # The pool of the runner that built the card, or nil.
  defp builder_pool(card) do
    import Ecto.Query
    alias Slipdock.Runners.Runner

    case Jobs.builder_runner_id(card) do
      id when is_integer(id) -> Repo.one(from(r in Runner, where: r.id == ^id, select: r.pool))
      _ -> nil
    end
  end

  defp pick_pool(builder_pool, idle, decider, pools) do
    cond do
      builder_pool && Enum.member?(idle, builder_pool) -> builder_pool
      idle != [] -> hd(idle)
      decider -> decider.pool
      builder_pool && Enum.member?(pools, builder_pool) -> builder_pool
      true -> List.first(pools)
    end
  end

  @doc """
  Where a card being merged stands (#1657): `:queued` or `:running` while a
  merge job is open on it, nil when it isn't merging. With none open, its
  last merge job since the acceptance says why (#2646): `:already_merged`
  when that job found the pull request merged at another head (#2637),
  `:waiting` when its runner couldn't merge here and no other runner took
  it on (#1754), and `:none` when nothing will merge it (no runner can).
  """
  def merge_status(%Card{verify_state: "merging"} = card) do
    import Ecto.Query

    case Repo.one(
           from(j in Slipdock.Runners.Job,
             where:
               j.card_id == ^card.id and j.kind == @merge_kind and
                 j.status in ^Slipdock.Runners.Job.open_statuses(),
             order_by: [desc: j.id],
             limit: 1,
             select: j.status
           )
         ) do
      nil -> last_merge_outcome(card)
      "queued" -> :queued
      _ -> :running
    end
  end

  def merge_status(_card), do: nil

  # Why a merging card has no merge job open (#2646): its last merge job
  # since the acceptance, read the way merge_finished/2 read it.
  defp last_merge_outcome(card) do
    import Ecto.Query

    query =
      from(j in Slipdock.Runners.Job,
        where: j.card_id == ^card.id and j.kind == @merge_kind,
        order_by: [desc: j.id],
        limit: 1
      )

    query =
      if card.verify_at, do: where(query, [j], j.inserted_at >= ^card.verify_at), else: query

    job = Repo.one(query)

    cond do
      is_nil(job) -> :none
      already_merged?(job) -> :already_merged
      runner_refused?(job) -> :waiting
      true -> :none
    end
  end

  defp merge_prompt(card) do
    "Merge the pull request of card ##{card.id}: #{card.evidence_pr} at the accepted commit " <>
      "#{card.verify_commit || card.evidence_commit}. The runner's built-in merge kind does this."
  end

  defp no_merger_text(card) do
    "**No runner can merge this.** None of this board's runners takes merge jobs: a " <>
      "machine's runner says it does on each claim unless its machine turns the built-in " <>
      "merge off (`no_merge` in the machine's own file). " <>
      merge_by_hand_text(card)
  end

  defp merge_by_hand_text(card) do
    "Or merge #{card.evidence_pr || "the pull request"} yourself and press **Merged it myself** " <>
      "on the card (`slipdock verify #{card.id} merged`)."
  end

  @doc """
  A merge job has ended (#1657), called by `Slipdock.Runners` for kind
  merge. Done: the card completes, with the merge commit as `merge_sha`,
  and moves to the done list (a pull request the runner found already
  merged at the accepted commit too, #2637). A runner that couldn't merge
  here (not the pull request's repository, no git or gh, gh signed out)
  hands it on to another runner (#1754): the card's work isn't at fault.
  One the runner found already merged at another head (or, from an older
  runner, merged at a head it didn't say) stays merging for a person, with
  a comment, and isn't a rejection (#2637). Anything else: it
  goes back to the top of the ready list as rejected, the merge's reason as
  the rejection's, so the builder rebases and submits it again. A card no
  longer merging is left alone.
  """
  def merge_finished(%Slipdock.Runners.Job{kind: @merge_kind} = job, runner_name) do
    case Repo.get(Card, job.card_id) do
      %Card{verify_state: "merging", completed: false} = card ->
        actor = Slipdock.Actor.runner(nil, job.id, runner_name)

        cond do
          job.status == "done" ->
            complete_merged(card, job.merged_sha, actor, nil, merged_line(job, runner_name))

          runner_refused?(job) ->
            hand_on(card, job, runner_name)

          already_merged?(job) ->
            merged_elsewhere(card, job, runner_name)

          true ->
            merge_failed(card, job, actor)
        end

      _ ->
        :ok
    end
  end

  def merge_finished(_job, _runner_name), do: :ok

  # The runner's words for a pull request it found already merged at the
  # accepted commit (#2637): the merge the job wanted, so the card completes.
  defp merged_line(job, runner_name) do
    if String.contains?(merge_reason(job), "was already merged at the accepted commit"),
      do:
        "**Merged** by runner #{runner_name}: the pull request was already merged at the " <>
          "accepted commit",
      else: "**Merged** by runner #{runner_name}"
  end

  @doc """
  Whether a merge job failed because the pull request was already merged
  (#2637): at another head (the daemon's words), or at a head the runner
  didn't say (older runners: `is MERGED, not open`). Only the runner's own
  `merge:` line counts. Such a job leaves its card merging for a person
  (`merged_elsewhere`), so queuing the merge again would fail the same way:
  the health monitor's `merge_missing` flags it rather than requeuing, and
  `merge_failing` doesn't count it as a failing merge (#2759).
  """
  def already_merged?(%{status: "failed"} = job) do
    said = merge_reason(job)

    String.starts_with?(said, "merge: ") and
      (String.contains?(said, "was already merged at head") or
         String.contains?(said, "is MERGED, not open"))
  end

  def already_merged?(_job), do: false

  # Already merged, but not at a head the runner could match to the
  # accepted commit: no rebase or resubmission changes a merged pull
  # request, so the card isn't sent back or counted as rejected (in quality
  # or circling). It stays merging, and the comment says which head was
  # merged, for a person to look at and mark merged by hand.
  defp merged_elsewhere(card, job, runner_name) do
    said = merge_reason(job)
    Slipdock.Findings.Signals.merge_failed(card, job, said)

    Slipdock.Boards.Comments.add_comment(
      card,
      "**Merge failed: already merged.** Runner #{runner_name} found " <>
        "#{card.evidence_pr || "the pull request"} merged already, but not at a head it " <>
        "could match to the accepted commit `#{card.verify_commit || card.evidence_commit}`. " <>
        "Nothing was merged, and it doesn't count as a rejection. Check what was merged; if " <>
        "it is the accepted work, press **Merged it myself** on the card " <>
        "(`slipdock verify #{card.id} merged`).\n\n#{said}"
    )

    :ok
  end

  # What a runner's built-in merge says, before touching anything, when the
  # runner itself can't merge (exit 2): the card isn't at fault, so another
  # runner may merge it. (The first wording is the retired shell runners'
  # as well as the daemon's.)
  @runner_refusals [
    "but this runner's repository is",
    "has no origin remote",
    "git is not installed",
    "gh (GitHub CLI) is not installed",
    "gh is not signed in"
  ]

  # How many runners an acceptance's merge is handed to before the card
  # waits for a person.
  @merge_hand_ons 2

  defp runner_refused?(%{status: "failed"} = job) do
    said = merge_reason(job)

    String.starts_with?(said, "merge: ") and
      Enum.any?(@runner_refusals, &String.contains?(said, &1))
  end

  defp runner_refused?(_job), do: false

  # A runner that can't merge here hands the merge on, leaving that runner
  # out (#1754). Past @merge_hand_ons, or with no other runner, the card
  # stays merging with nothing queued and says why.
  defp hand_on(card, job, runner_name) do
    import Ecto.Query

    said = merge_reason(job)

    refused =
      from(j in Slipdock.Runners.Job,
        where:
          j.card_id == ^card.id and j.kind == @merge_kind and j.status == "failed" and
            j.inserted_at >= ^card.verify_at
      )
      |> Repo.all()
      |> Enum.count(&runner_refused?/1)

    pool = refused <= @merge_hand_ons && merge_pool(card, exclude: job.runner_id)
    queued = pool && queue_merge(card, nil, exclude: job.runner_id)

    case queued do
      {:ok, _job} ->
        Slipdock.Boards.Comments.add_comment(
          card,
          "**Merge handed on.** Runner #{runner_name} can't merge here, so pool `#{pool}` " <>
            "has it now.\n\n#{said}"
        )

      _ ->
        Slipdock.Boards.Comments.add_comment(
          card,
          "**Merge waiting.** Runner #{runner_name} can't merge here, and no other runner " <>
            "has taken it on. Fix the runner, or: " <> merge_by_hand_text(card) <> "\n\n#{said}"
        )
    end

    :ok
  end

  defp merge_failed(card, job, actor) do
    said = merge_reason(job)
    reason = "Merge failed (job ##{job.id}, #{job.status}): " <> said

    changes = [
      verify_state: "rejected",
      verify_note: reason,
      verify_at: Util.now(),
      verify_rejections: (card.verify_rejections || 0) + 1
    ]

    with {:ok, card} <-
           Slipdock.Boards.Cards.update_card(card, Evidence.no_evidence(),
             actor: actor,
             verify_changes: changes
           ) do
      Slipdock.Runners.TranscriptRetention.card_failed(card)
      Outcome.comment(card, merge_failed_line(card, said), reason, nil)
      Slipdock.Findings.Signals.merge_failed(card, job, said)

      Outcome.send_back(card, "Rework: the merge failed, reason under Verification", actor, nil)
    end
  end

  # What to do about a failed merge (#1666): a rebase only helps when the
  # branch conflicts with the default branch or its head moved; anything
  # else (gh signed out, the wrong repository, a closed pull request, a
  # failing check) is fixed where the reason says.
  defp merge_failed_line(card, said) do
    if rebase_fixes?(said),
      do:
        "**Merge failed.** It conflicts or its head moved: rebase `#{Shipping.pr_branch(card)}` " <>
          "on the default branch and submit it again.",
      else:
        "**Merge failed.** The merge job's reason is below, and a rebase won't fix it: " <>
          "fix what it says, then submit the card again."
  end

  @doc """
  Whether a failed merge's reason (the merge job's own words) is one a
  rebase fixes (#1666): a conflict, or a head that moved after acceptance.
  """
  def rebase_fixes?(said) when is_binary(said) do
    Regex.match?(
      ~r/conflict|not mergeable|cannot be cleanly created|head branch was modified|it moved after|not the accepted commit|is not up to date|behind the base/i,
      said
    )
  end

  def rebase_fixes?(_), do: false

  # The runner's own words: its last `merge:` line, else the output's last line.
  defp merge_reason(job) do
    lines = (job.output || job.log_tail || "") |> String.split(~r/\R/, trim: true)

    (Enum.find(Enum.reverse(lines), &String.starts_with?(&1, "merge:")) || List.last(lines) ||
       "the merge job ended #{job.status}")
    |> String.slice(0, 1000)
  end

  # A person saying they merged it themselves (#1657): only on a card being
  # merged, and only a person.
  @doc false
  def merged_by_hand(card, commit, actor, user) do
    cond do
      card.verify_state != "merging" ->
        {:error, :conflict, "card ##{card.id} isn't waiting for its merge"}

      Actors.gated?(actor) ->
        {:error, :forbidden, "only a person marks a card merged by hand"}

      commit != "" and not Regex.match?(~r/\A[0-9a-fA-F]{7,64}\z/, commit) ->
        {:error, :unprocessable_entity, "the merge commit must be a commit id"}

      true ->
        cancel_merge_jobs(card)

        complete_merged(
          card,
          Util.blank_to_nil(commit),
          actor,
          user,
          "**Merged by hand** by #{Actors.who(actor, user)}"
        )
    end
  end

  defp complete_merged(card, sha, actor, user, line) do
    sha = sha && String.downcase(sha)

    with {:ok, card} <-
           Slipdock.Boards.Cards.update_card(card, %{"completed" => true},
             actor: actor,
             by: user,
             verify_changes: [verify_state: "accepted", merge_sha: sha]
           ) do
      Outcome.comment(card, line <> if(sha, do: " as `#{sha}`.", else: "."), nil, user)

      done =
        card |> Util.board() |> Repo.preload(:columns) |> Map.get(:columns) |> Outcome.done_list()

      if done && done.id != card.column_id,
        do: Slipdock.Boards.Cards.move_card(card.id, done.id, nil, actor: actor)

      # Merged: an audit now can't hold anything up (#1780).
      card = Repo.get!(Card, card.id)
      Jobs.maybe_audit(card)
      # On a batched board a critical card's merge asks for a release (#2835).
      Slipdock.Releases.card_merged(card)
      {:ok, card}
    end
    |> Outcome.api_error()
  end

  defp cancel_merge_jobs(%Card{id: card_id}) do
    import Ecto.Query

    from(j in Slipdock.Runners.Job,
      where:
        j.card_id == ^card_id and j.kind == @merge_kind and
          j.status in ^Slipdock.Runners.Job.open_statuses()
    )
    |> Repo.all()
    |> Enum.each(&Slipdock.Runners.cancel_job/1)
  end

  @doc """
  The job kinds that finish a card's work rather than add to it: verifying
  and merging. Lanes and the WIP limit hold work jobs only (#1807): these
  edit nobody's files and put no more work in progress.
  """
  def finishing_kinds, do: [Jobs.verify_kind(), @merge_kind]
end
