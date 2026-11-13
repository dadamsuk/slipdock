defmodule Slipdock.Runners.JobCost do
  @moduledoc """
  What a job spent (#1954), from what its log says: the model's and the
  tools' seconds (`Slipdock.Runners.TranscriptSummary`'s split) and the
  tokens its lines carried (`input`, `output`, `cache_read`,
  `cache_write`), or no tokens at all when no line carried `usage`.

  No prices and no currency: tokens and seconds are facts, and what they
  cost is the team's own arithmetic.

  The count is kept on the job (`model_seconds`, `tool_seconds`, `tokens`)
  with how many lines it covered (`cost_lines`), and redone only when the
  log has grown since. The retention sweep counts a log before deleting it,
  so a job's cost outlives its log. A job whose log never arrived has no
  cost (nil), not a cost of nothing.
  """

  import Ecto.Query

  alias Slipdock.Repo
  alias Slipdock.Runners.{Job, Transcript, TranscriptSummary}

  @type t :: %{
          model_seconds: non_neg_integer(),
          tool_seconds: non_neg_integer(),
          tokens: TranscriptSummary.tokens() | nil
        }

  @doc """
  The cost of `job`: counted again from its log when the log has lines the
  last count didn't see, else what was kept. Nil for a job with no log
  counted, ever.
  """
  def of(%Job{} = job) do
    job = if stale?(job), do: count(job), else: job
    kept(job)
  end

  @doc """
  Counts `job`'s log and keeps the result on the job, when the log has
  grown since the last count. Answers the job as it now is.
  """
  def count(%Job{} = job) do
    if stale?(job) do
      cost = job |> Transcript.read() |> TranscriptSummary.cost()

      {_, [job]} =
        Repo.update_all(from(j in Job, where: j.id == ^job.id, select: j),
          set: [
            model_seconds: cost.model_seconds,
            tool_seconds: cost.tool_seconds,
            tokens: cost.tokens && Map.new(cost.tokens, fn {k, v} -> {to_string(k), v} end),
            cost_lines: job.transcript_lines
          ]
        )

      job
    else
      job
    end
  end

  @doc "Counts the logs of the jobs with `ids` that have grown since (the sweep's first step)."
  def count_all(ids) when is_list(ids) do
    from(j in Job, where: j.id in ^ids and j.transcript_lines > j.cost_lines)
    |> Repo.all()
    |> Enum.each(&count/1)
  end

  @doc """
  The costs in `costs` added up (nils skipped): nil when every one is nil.
  Tokens are summed over the jobs that have them, and are nil when none
  does; `jobs` is how many costs were added.
  """
  def sum(costs) do
    case Enum.reject(costs, &is_nil/1) do
      [] ->
        nil

      known ->
        %{
          model_seconds: known |> Enum.map(& &1.model_seconds) |> Enum.sum(),
          tool_seconds: known |> Enum.map(& &1.tool_seconds) |> Enum.sum(),
          tokens: known |> Enum.map(& &1.tokens) |> sum_tokens(),
          jobs: known |> Enum.map(&Map.get(&1, :jobs, 1)) |> Enum.sum()
        }
    end
  end

  defp sum_tokens(tokens) do
    case Enum.reject(tokens, &is_nil/1) do
      [] -> nil
      known -> Enum.reduce(known, &Map.merge(&1, &2, fn _k, a, b -> a + b end))
    end
  end

  @doc "All of a cost's tokens added up, or nil when they aren't known."
  def total_tokens(%{tokens: %{} = t}), do: t |> Map.values() |> Enum.sum()
  def total_tokens(_), do: nil

  @doc """
  The tokens a cost's jobs spent new (#3003): input, output and cache
  write, leaving out the cache reads (the same context read again on each
  model turn, billed at a fraction of the input rate). Nil when the tokens
  aren't known.
  """
  def fresh_tokens(%{tokens: %{} = t}),
    do: Map.get(t, :input, 0) + Map.get(t, :output, 0) + Map.get(t, :cache_write, 0)

  def fresh_tokens(_), do: nil

  @doc """
  A cost in a few words: `"model 12m · tools 40m · 5.8M tokens (180.0k
  new)"`, the new ones (`fresh_tokens/1`) beside the total whenever cache
  reads make them differ, so a job that mostly re-read its context doesn't
  read as ten times the cost. The tokens are left out when they aren't
  known (never shown as 0). Nil for nil.
  """
  def text(nil), do: nil

  def text(cost) do
    [
      "model #{duration(cost.model_seconds)}",
      "tools #{duration(cost.tool_seconds)}",
      tokens_phrase(total_tokens(cost), fresh_tokens(cost))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp tokens_phrase(nil, _), do: nil
  defp tokens_phrase(n, n), do: "#{tokens_text(n)} tokens"
  defp tokens_phrase(n, fresh), do: "#{tokens_text(n)} tokens (#{tokens_text(fresh)} new)"

  @doc "A token count, short: `950`, `12.3k`, `1.2M`."
  def tokens_text(n) when n < 1000, do: to_string(n)
  def tokens_text(n) when n < 1_000_000, do: "#{Float.round(n / 1000, 1)}k"
  def tokens_text(n), do: "#{Float.round(n / 1_000_000, 1)}M"

  defp duration(s) when s < 60, do: "#{s}s"
  defp duration(s) when s < 3600, do: "#{div(s, 60)}m"
  defp duration(s), do: "#{div(s, 3600)}h #{rem(div(s, 60), 60)}m"

  @doc """
  A cost as JSON: `model_seconds`, `tool_seconds`, `jobs`, and `tokens`
  (the four counts, with `total` and `fresh`, `fresh_tokens/1`) only when
  they are known. Nil for nil.
  """
  def json(nil), do: nil

  def json(cost) do
    base = Map.take(cost, [:model_seconds, :tool_seconds, :jobs])

    case cost.tokens do
      nil ->
        base

      t ->
        tokens = Map.merge(t, %{total: total_tokens(cost), fresh: fresh_tokens(cost)})
        Map.put(base, :tokens, tokens)
    end
  end

  defp stale?(%Job{transcript_lines: lines, cost_lines: counted}), do: lines > (counted || 0)

  defp kept(%Job{cost_lines: n}) when n in [nil, 0], do: nil

  defp kept(%Job{} = job) do
    %{
      model_seconds: job.model_seconds || 0,
      tool_seconds: job.tool_seconds || 0,
      tokens: tokens(job.tokens)
    }
  end

  defp tokens(nil), do: nil

  defp tokens(%{} = t) do
    %{
      input: t["input"] || 0,
      output: t["output"] || 0,
      cache_read: t["cache_read"] || 0,
      cache_write: t["cache_write"] || 0
    }
  end
end
