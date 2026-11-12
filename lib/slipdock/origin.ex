defmodule Slipdock.Origin do
  @moduledoc """
  Where a card came from (#2778, W-2588 §2), recorded when it is made:

    * `person` — made in the web UI, by a person's token or by mail;
    * `sweep`, `findings` — a generator named by an agent inside its job;
    * `health`, `overseer`, `verify` — the server's own monitors and
      verification follow-ups;
    * `release` — the fix card a red release files (#2838);
    * `automation` — a rule's *create a card* action, or the clock;
    * `import` — brought in by an import;
    * `agent` — an agent, with its runner job's id when it made the card
      during one.

  The server works it out from who made the card (`Slipdock.Actor`). A
  caller may name only a generator (`sweep`, `findings`), and only from
  inside a runner job: nobody can claim to be a person. Cards made before
  origins were recorded have none.
  """

  @names ~w(person sweep findings health overseer verify release automation import agent)
  @claimable ~w(sweep findings)

  @doc "Every origin a card can have."
  def names, do: @names

  @doc "The origins a caller may name for a card it makes, from inside a job."
  def claimable, do: @claimable

  @doc """
  The origin of a card made by `actor` (with `by`, the person writing, when
  known). `given` is the server's own say (`opts[:origin]`), which wins;
  `requested` is what the caller asked for. Answers `{:ok, {origin,
  job_id}}`, or `{:error, message}` for a claim it may not make.
  """
  def resolve(actor, by, given, requested)

  def resolve(actor, _by, given, _requested) when given in @names,
    do: {:ok, {given, job_of(given, actor)}}

  def resolve(actor, by, _given, requested) when requested in [nil, ""],
    do: {:ok, from_actor(actor, by)}

  def resolve(%{job_id: job_id}, _by, _given, requested)
      when requested in @claimable and is_integer(job_id),
      do: {:ok, {requested, job_id}}

  def resolve(_actor, _by, _given, requested) do
    {:error,
     "can't be “#{requested}”: only an agent inside a runner job may name where a card " <>
       "came from, and only as #{Enum.join(@claimable, " or ")}; the server records the rest"}
  end

  defp from_actor(%{kind: "human"}, _by), do: {"person", nil}
  defp from_actor(%{kind: "agent", job_id: job_id}, _by), do: {"agent", job_id}
  defp from_actor(%{kind: "agent"}, _by), do: {"agent", nil}
  defp from_actor(%{kind: "automation"}, _by), do: {"automation", nil}
  defp from_actor(_actor, by) when not is_nil(by), do: {"person", nil}
  defp from_actor(_actor, _by), do: {nil, nil}

  # A generator's card keeps the job it was made in, if any.
  defp job_of(_given, %{job_id: job_id}) when is_integer(job_id), do: job_id
  defp job_of(_given, _actor), do: nil

  @doc """
  The values the origin filter takes, as `{value, label}`: each origin, and
  `none` for the cards made before origins were kept.
  """
  def buckets, do: Enum.map(@names, &{&1, &1}) ++ [{"none", "no origin"}]

  @doc "How an origin reads: `agent (job #12)`, `sweep`, or nil for none."
  def label(nil, _job_id), do: nil
  def label(origin, nil), do: origin
  def label(origin, job_id), do: "#{origin} (job ##{job_id})"
end
