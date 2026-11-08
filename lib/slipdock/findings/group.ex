defmodule Slipdock.Findings.Group do
  @moduledoc """
  The second step of matching across cards (#2118, W-2310 §Findings): the
  model groups what the near match (`Slipdock.Findings.Lesson.alike?/2`) left.

  A finding a pass has just written that matched nothing (open, counted once,
  on one card) goes to one `Slipdock.AI` call along with the tree's open
  findings it could repeat: those on other cards, of the kinds that can be one
  lesson across cards (`gotcha`, `tooling`, `process`; never `rule` or
  `handbook-wrong`), in its scope (and runner, for a runner's), the newest
  40 at most. The model says whether it repeats one of them, which, and
  why. A yes merges it into that one as `same-lesson-ai`, with the reason in
  the note, so a person can see why and reopen it; the count moves and
  `Slipdock.Findings.Promote` looks again (through `Findings.triage/3`). A no, an answer naming no
  candidate, an error or AI off changes nothing.

  One call per unmatched finding, never one per pair, and none when there
  are no candidates. It runs under `Slipdock.TaskSupervisor`, as Promote
  does, unless `config :slipdock, :findings, async: false` (tests); `group:
  false` there turns it off.
  """
  require Logger

  import Ecto.Query

  alias Slipdock.{AI, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Findings
  alias Slipdock.Findings.Finding

  @kinds ~w(gotcha tooling process)
  @shortlist 40
  @cause "same-lesson-ai"

  @doc "What a merge made here is marked with (`Finding.cause`)."
  def cause, do: @cause

  @doc """
  Looks at each of these findings that is still unmatched, in the background
  unless configured otherwise. Returns `:ok`.
  """
  def consider(findings) do
    ids = findings |> List.wrap() |> Enum.filter(&unmatched?/1) |> Enum.map(& &1.id)
    if ids != [] and on?(), do: run(fn -> Enum.each(ids, &check/1) end), else: :ok
  end

  # `config :slipdock, :findings, group: false` turns it off (the test
  # suite's default).
  defp on?, do: Slipdock.Config.get(:findings, [])[:group] != false

  # Made by this comment and matched nothing: open, said once, by an agent.
  defp unmatched?(%Finding{status: "open", source: "agent", count: 1, kind: kind}),
    do: Enum.member?(@kinds, kind)

  defp unmatched?(_), do: false

  defp run(fun) do
    if Slipdock.Config.get(:findings, [])[:async] == false do
      fun.()
    else
      case Task.Supervisor.start_child(Slipdock.TaskSupervisor, fun) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.warning("Findings.Group not started: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc """
  Asks once whether finding `id` repeats one of its candidates:
  `{:merged, into}`, or `:skip` (not unmatched any more, no candidates, AI off,
  no match, or a failed call).
  """
  def check(id) do
    with %Finding{} = finding <- Repo.get(Finding, id),
         true <- unmatched?(finding),
         [_ | _] = candidates <- candidates(finding),
         owner = owner(finding),
         true <- AI.configured?(owner) or AI.configured?(),
         {:ok, %Finding{} = into, reason} <- ask(finding, candidates, owner),
         {:ok, _} <- merge(finding, into, reason) do
      {:merged, Repo.get!(Finding, into.id)}
    else
      _ -> :skip
    end
  rescue
    e ->
      Logger.warning("Findings.Group failed for ##{id}: #{Exception.message(e)}")
      :skip
  end

  @doc "The open findings `finding` could repeat, newest first, at most 40."
  def candidates(%Finding{} = f) do
    from(c in Finding,
      where:
        c.board_id == ^f.board_id and c.status == "open" and c.id != ^f.id and
          c.kind in @kinds and c.scope == ^f.scope and
          (is_nil(c.card_id) or c.card_id != ^f.card_id),
      order_by: [desc: c.id],
      limit: @shortlist
    )
    |> same_runner(f)
    |> Repo.all()
  end

  defp same_runner(q, %Finding{scope: "runner", runner_id: nil}),
    do: where(q, [c], is_nil(c.runner_id))

  defp same_runner(q, %Finding{scope: "runner", runner_id: id}),
    do: where(q, [c], c.runner_id == ^id)

  defp same_runner(q, _f), do: q

  defp owner(%Finding{board_id: id}) do
    with %Board{owner_id: owner_id} <- Repo.get(Board, id), do: Repo.get(User, owner_id)
  end

  # One call. A plain completion in JSON mode, decoded here, so a reply that
  # isn't JSON is a no rather than a second call.
  defp ask(finding, candidates, owner) do
    with {:ok, text} <-
           AI.complete(messages(finding, candidates),
             json: true,
             user: owner,
             max_tokens: 200,
             temperature: 0.0
           ),
         {:ok, %{"match" => match} = answer} <- AI.decode_json(text),
         %Finding{} = into <- Enum.find(candidates, &(&1.id == to_id(match))) do
      {:ok, into, reason(answer["reason"])}
    else
      _ -> :no
    end
  end

  defp to_id(n) when is_integer(n), do: n

  defp to_id(s) when is_binary(s) do
    case Integer.parse(String.trim_leading(s, "#")) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_id(_), do: nil

  defp reason(r) when is_binary(r) and r != "", do: r |> String.trim() |> String.slice(0, 300)
  defp reason(_), do: "the same lesson"

  defp merge(finding, into, reason) do
    note = "same lesson as ##{into.id}, by the model: #{reason}"

    with {:ok, merged} <- Findings.triage(finding, "merge", %{"into" => into.id, "note" => note}) do
      {:ok, merged |> Ecto.Changeset.change(cause: @cause) |> Repo.update!()}
    end
  end

  defp messages(finding, candidates) do
    listed = Enum.map_join(candidates, "\n", &"- ##{&1.id} (#{&1.kind}): #{one_line(&1.text)}")

    [
      %{
        role: "system",
        content: """
        Agents working on a software project write down what each task taught
        them. Different agents often write the same lesson in different words.
        Decide whether a new note repeats one already kept: the same lesson,
        the same cause and the same thing to do about it, not merely the same
        topic. Answer with JSON: {"match": <the kept note's number, or null>,
        "reason": "<one short sentence saying why>"}.
        """
      },
      %{
        role: "user",
        content: """
        The new note (#{finding.kind}): #{one_line(finding.text)}

        The notes kept:
        #{listed}
        """
      }
    ]
  end

  defp one_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
