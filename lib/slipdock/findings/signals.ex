defmodule Slipdock.Findings.Signals do
  @moduledoc """
  The findings the system records without asking (W-2310 §Findings): agents
  under-report their own stumbles, so the places that see one call here.

    * a verifier **rejects** (`rejected/4`): the kind comes from the failing
      part — a broken rule is a `rule`, a disputed Handbook line
      `handbook-wrong`, anything else `process`
    * a runner job **times out** or **fails** (`job_ended/1`)
    * its card is **requeued** or given up on (`requeued/3`, `gave_up/2`)
    * a **lane** refuses an agent's move (`lane_refused/3`)
    * a **merge** job fails (`merge_failed/3`)
    * an **audit** disagrees (`audit_disagreed/3`)
    * a verdict reports a rule broken in code the change didn't touch
      (`pre_existing/3`, source `verification`: it isn't a rejection)
    * the **health** monitor flags an incident (`health_flagged/3`)
    * a card names the card that caused it and the check that missed it
      (`incident/2`, source `incident`, #1946): one finding per incident,
      on the causing card, changed in place as the incident's fields change

  Each records its source, card and job; a repeat on the same card and cause
  adds to the count (`Slipdock.Findings.record/1`), and the same job never
  counts twice.

  A board without a handbook keeps them all the same, on its root board:
  they are about the work, not the handbook. Triage doesn't need one
  (dismiss and merge never do, and a promotion's note can name any page),
  and a handbook installed later starts from the history rather than from
  nothing. Nothing here may stop the work it watches: a finding that can't
  be written is logged and dropped.
  """
  require Logger

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Findings
  alias Slipdock.Findings.Finding
  alias Slipdock.{Incidents, Repo}
  alias Slipdock.Runners.Job

  @doc "A verifier rejected `card`: `reason` and the verdict's parts (`checks`)."
  def rejected(%Card{} = card, reason, checks, actor) do
    {kind, part} = rejection_kind(checks)

    record(%{
      card: card,
      source: "rejection",
      kind: kind,
      cause: "rejected: " <> part,
      text: "Rejected (#{part}): " <> to_string(reason),
      job_id: job_id(actor)
    })
  end

  @doc false
  # The kind and the cause of a rejection, from its first failing part.
  def rejection_kind(checks) when is_map(checks) do
    rules = Enum.filter(List.wrap(checks["rules"]), &(&1["result"] == "broken"))
    bar = Enum.filter(List.wrap(checks["bar"]), &(&1["result"] == "fail"))

    cond do
      rules != [] -> {"rule", "rule " <> to_string(hd(rules)["id"])}
      checks["handbook_line"] == "disputed" -> {"handbook-wrong", "Handbook line"}
      checks["ask"] == "misses" -> {"process", "the ask"}
      bar != [] -> {"process", "bar " <> to_string(hd(bar)["item"])}
      true -> {"process", "the reason"}
    end
  end

  def rejection_kind(_checks), do: {"process", "the reason"}

  @doc """
  A runner job ended: one that timed out or failed is a finding on its card.
  Merge jobs are left to `merge_failed/3`; a cancelled or parked job is
  somebody's choice, not a stumble.
  """
  def job_ended(%Job{card_id: card_id, kind: kind} = job) when is_integer(card_id) do
    with true <- Enum.member?(["timeout", "failed"], job.status),
         false <- kind == Slipdock.Verified.merge_kind(),
         %Card{} = card <- Slipdock.Repo.get(Card, card_id) do
      {source, cause, what} =
        if job.status == "timeout",
          do: {"timeout", "#{kind} job timed out", "timed out"},
          else: {"failed", "#{kind} job failed", failed_text(job)}

      record(%{
        card: card,
        source: source,
        kind: "process",
        cause: cause,
        text: "Runner job ##{job.id} (#{kind}) #{what}.",
        job_id: job.id
      })
    else
      _ -> :ok
    end
  end

  def job_ended(_job), do: :ok

  defp failed_text(%Job{error: error}) when is_binary(error) and error != "",
    do: "failed: " <> String.slice(error, 0, 500)

  defp failed_text(%Job{exit_code: code}) when is_integer(code), do: "failed, exit #{code}"
  defp failed_text(_job), do: "failed"

  @doc "Recovery put `card` back on its list after `job` left it in progress."
  def requeued(%Job{} = job, %Card{} = card, why) do
    record(%{
      card: card,
      source: "requeue",
      kind: "process",
      cause: "requeued",
      text: "Runner job ##{job.id} ended (#{why}) with the card still in progress: put back.",
      job_id: job.id
    })
  end

  @doc "Recovery gave up on `card` after its retries."
  def gave_up(%Job{} = job, %Card{} = card) do
    record(%{
      card: card,
      source: "requeue",
      kind: "process",
      cause: "gave up",
      text: "Runner job ##{job.id} left the card in progress after its retries: flagged blocked.",
      job_id: job.id
    })
  end

  @doc """
  A verdict on `card` (`checks`, in the stored shape) reported rules broken
  only in code the change didn't touch (#1945): one `rule` finding for each
  such part, source `verification`, its cause naming the rule and the place,
  so a part reported again (the next round, or another card) is counted
  rather than kept twice.
  """
  def pre_existing(%Card{} = card, checks, actor) do
    checks
    |> Slipdock.Verified.Checks.pre_existing()
    |> Enum.uniq_by(&{&1["id"], &1["file"], &1["line"]})
    |> Enum.each(fn r ->
      place = "#{r["file"]}:#{r["line"]}"

      record(%{
        card: card,
        source: "verification",
        kind: "rule",
        cause: "pre-existing #{r["id"]} #{place}",
        text:
          "#{r["id"]} is broken in code the change didn't touch, at #{place}" <>
            if(r["note"], do: ": #{r["note"]}", else: "") <>
            " (reported by the verifier, not a rejection).",
        job_id: job_id(actor)
      })
    end)
  end

  @doc "A lane refused an agent moving `card`, or changing its paths, because of `other`."
  def lane_refused(%Card{} = card, %Card{} = other, actor) do
    record(%{
      card: card,
      source: "lane",
      kind: "process",
      cause: "lane ##{other.id}",
      text:
        "A lane refused ##{card.id}: its paths (#{Enum.join(card.paths, ", ")}) overlap " <>
          "##{other.id} \"#{other.title}\" (#{Enum.join(other.paths, ", ")}).",
      job_id: job_id(actor)
    })
  end

  @doc "A merge job for `card` failed, saying `said`."
  def merge_failed(%Card{} = card, %Job{} = job, said) do
    record(%{
      card: card,
      source: "merge",
      kind: "tooling",
      cause: "merge failed",
      text: "Merge job ##{job.id} #{job.status}: " <> to_string(said),
      job_id: job.id
    })
  end

  @doc "An audit disagreed with `card`'s acceptance."
  def audit_disagreed(%Card{} = card, reason, actor) do
    record(%{
      card: card,
      source: "audit",
      kind: "process",
      cause: "audit disagrees",
      text: "An audit disagrees with the acceptance: " <> to_string(reason),
      job_id: job_id(actor)
    })
  end

  @doc """
  The health monitor flagged an incident: one finding on each card it is
  about, or on the tree's root board when no card is.
  """
  def health_flagged(incident, label, cards) do
    attrs = %{
      source: "health",
      kind: "process",
      cause: "health: " <> incident.detector,
      text: "#{label}: #{incident.summary}",
      job_id: job_ref(incident.subject["job"])
    }

    case cards do
      [] ->
        record(
          Map.put(attrs, :board, Slipdock.Repo.get!(Slipdock.Boards.Board, incident.board_id))
        )

      cards ->
        Enum.each(cards, &record(Map.put(attrs, :card, &1)))
    end
  end

  @doc """
  Keeps the finding for `incident` (#1946) in step with its fields: while it
  names a cause and a layer, one `process` finding on the causing card says
  which layer missed it. Changing the layer or the cause changes that
  finding (its text, and the card it is on) rather than adding one; clearing
  either takes an untriaged one away, and leaves one a person has promoted or
  dismissed as they left it. `by` is who set it, in words.
  """
  def incident(%Card{} = incident, by \\ nil) do
    key = Incidents.finding_cause(incident)
    cause = incident.missed_by && Incidents.cause(incident)

    existing =
      Repo.one(
        from f in Finding,
          where: f.source == "incident" and f.cause == ^key and f.status != "merged",
          order_by: [desc: f.id],
          limit: 1
      )

    case {existing, cause} do
      {nil, nil} ->
        :ok

      {nil, cause} ->
        record(%{
          card: cause,
          source: "incident",
          kind: "process",
          cause: key,
          text: Incidents.finding_text(incident, incident.missed_by),
          by: by
        })

      {%Finding{status: "open"} = finding, nil} ->
        Repo.delete(finding)

      {_triaged, nil} ->
        :ok

      {finding, cause} ->
        finding
        |> Finding.changeset(%{text: Incidents.finding_text(incident, incident.missed_by)})
        |> Ecto.Changeset.change(
          card_id: cause.id,
          board_id: Board.root_id(cause.board)
        )
        |> Repo.update()
    end
  rescue
    e ->
      Logger.warning("incident finding not kept: #{Exception.message(e)}")
      :ok
  end

  defp record(attrs) do
    case Findings.record(attrs) do
      {:ok, finding} ->
        {:ok, finding}

      {:error, error} ->
        Logger.warning("finding not recorded (#{attrs[:source]}): #{inspect(error)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("finding not recorded (#{attrs[:source]}): #{Exception.message(e)}")
      :ok
  end

  defp job_id(actor) when is_map(actor), do: job_ref(actor[:job_id] || actor["job_id"])
  defp job_id(_actor), do: nil

  # Only a job that is there: a finding's job is a reference.
  defp job_ref(id) when is_integer(id), do: if(Slipdock.Repo.get(Job, id), do: id)
  defp job_ref(_), do: nil
end
