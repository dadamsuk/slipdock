defmodule Slipdock.Repo.Migrations.CloseStaleFindingProposals do
  @moduledoc """
  Rule proposals the server drafted from findings (#1942) were left open
  when triage decided the finding, filed twice or more for one finding by
  racing drafts, and drafted from event findings (#2129). This adds
  `garden_suggestions.note`, why the server closed a proposal, and closes
  once each open drafted proposal (its explanation starts "Finding #N was
  seen") that is one of these, with its note:

    * its finding is promoted, dismissed or merged: `finding #14 promoted:
      <the finding's note>`, as `Slipdock.Findings.triage/3` now closes one;
    * its finding is an event (`health`, `merge`, `lane`, `requeue`,
      `timeout`, `failed`, `incident`), not a lesson;
    * its finding is open and has another open proposal of its own
      (`findings.proposal_id`): `duplicate of proposal #81 (finding #14)`.

  Closed is `dismissed` with nobody deciding: reopening the finding
  reopens its own proposal (`Slipdock.Findings.Promote.reopened/1`).
  Down drops the column and leaves the proposals closed.
  """
  use Ecto.Migration

  def up do
    alter table(:garden_suggestions) do
      add :note, :text
    end

    flush()

    Enum.each(backfill(), &execute/1)
  end

  def down do
    alter table(:garden_suggestions) do
      remove :note
    end
  end

  @doc "The clean-up, as SQL statements (run again by its test)."
  def backfill do
    [
      """
      WITH drafted AS (
        SELECT s.id,
               substring(s.explanation FROM '^Finding #([0-9]+) was seen ')::bigint AS finding_id
        FROM garden_suggestions s
        WHERE s."check" = 'proposal' AND s.state = 'open'
          AND s.explanation ~ '^Finding #[0-9]+ was seen '
      ),
      why AS (
        SELECT d.id,
          CASE
            WHEN f.id IS NULL THEN
              'finding #' || d.finding_id || ' is gone'
            WHEN f.status = 'merged' THEN
              'finding #' || f.id || ' merged into #' || coalesce(f.merged_into_id::text, '?')
                || coalesce(': ' || nullif(f.note, ''), '')
            WHEN f.status <> 'open' THEN
              'finding #' || f.id || ' ' || f.status || coalesce(': ' || nullif(f.note, ''), '')
            WHEN f.source NOT IN ('agent', 'rejection', 'verification', 'audit') THEN
              'finding #' || f.id || ' is a ' || f.source
                || ' event: it records what happened, not a lesson'
            WHEN f.proposal_id IS DISTINCT FROM d.id
                 AND EXISTS (SELECT 1 FROM garden_suggestions p
                             WHERE p.id = f.proposal_id AND p.state = 'open') THEN
              'duplicate of proposal #' || f.proposal_id || ' (finding #' || f.id || ')'
          END AS note
        FROM drafted d
        LEFT JOIN findings f ON f.id = d.finding_id
      )
      UPDATE garden_suggestions s
      SET state = 'dismissed',
          note = why.note,
          decided_by_id = NULL,
          decided_at = date_trunc('second', timezone('UTC', now())),
          updated_at = date_trunc('second', timezone('UTC', now()))
      FROM why
      WHERE why.id = s.id AND why.note IS NOT NULL
      """
    ]
  end
end
