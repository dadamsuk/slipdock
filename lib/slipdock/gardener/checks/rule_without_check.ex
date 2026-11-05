defmodule Slipdock.Gardener.Checks.RuleWithoutCheck do
  @moduledoc """
  Handbook rules worth a second look (#1790, `Slipdock.Handbook.Rules`):

    * a `must` rule whose check has been `judgement` for more than `days`
      days: a nudge to write the test that enforces it;
    * a rule id used more than once, across the handbook's pages or on one.

  How long a rule has been `judgement` comes from the page's revisions:
  every save writes one, so it is the oldest of the newest revisions in a
  row whose body has a line with the rule's id and `judgement` on it. A
  rule given a test and later set back to `judgement` starts again from
  then; a page with no revision that has it counts from its creation.

  The fix comments on the Index saying what to change and where. Rules are
  never edited by a suggestion: they change only with a person's yes. Off
  on a board without a handbook.
  """
  @behaviour Slipdock.Gardener.Check

  import Ecto.Query

  alias Slipdock.Gardener.HandbookNote
  alias Slipdock.Handbook.Rules
  alias Slipdock.Repo
  alias Slipdock.Wiki.Revision

  @impl true
  def key, do: "rule_without_check"
  @impl true
  def label, do: "Rules without a test"
  @impl true
  def defaults, do: %{"enabled" => true, "days" => 30}

  @impl true
  def find(ctx, settings) do
    case HandbookNote.handbook(ctx) do
      nil -> []
      handbook -> judged(handbook, ctx.now, settings["days"]) ++ duplicates(handbook)
    end
  end

  ## Judgement for too long -----------------------------------------------------

  defp judged(handbook, now, days) do
    rules =
      handbook
      |> Rules.rules()
      |> Enum.filter(&(&1.severity == "must" and &1.check == "judgement"))

    for page <- handbook.pages,
        mine = Enum.filter(rules, &(&1.page == page.code)),
        mine != [],
        finding <- page_judged(handbook, page, mine, now, days),
        do: finding
  end

  defp page_judged(handbook, page, rules, now, days) do
    history = history(page)

    for rule <- rules,
        since = judgement_since(history, rule.id) || page.inserted_at,
        age = DateTime.diff(now, since, :day),
        age > days,
        do: judged_finding(handbook, page, rule, age)
  end

  # The page's revisions, newest first, as `{inserted_at, body}`.
  defp history(page) do
    from(r in Revision,
      where: r.page_id == ^page.id,
      order_by: [desc: r.inserted_at, desc: r.id],
      select: {r.inserted_at, r.body}
    )
    |> Repo.all()
  end

  @doc false
  # When the rule `id` last became `judgement`, by the revisions (newest
  # first), or nil when none has it so.
  def judgement_since(history, id) do
    history
    |> Enum.take_while(fn {_at, body} -> judgement_line?(body, id) end)
    |> List.last()
    |> case do
      nil -> nil
      {at, _body} -> at
    end
  end

  defp judgement_line?(body, id) do
    body
    |> String.split("\n")
    |> Enum.any?(
      &(String.contains?(&1, "**#{id}**") and Regex.match?(~r/(?<!\w)judge?ment(?!\w)/i, &1))
    )
  end

  defp judged_finding(handbook, page, rule, age) do
    HandbookNote.finding(
      handbook,
      [page],
      {rule.id, rule.severity, rule.check, rule.text},
      "#{rule.id} (must) on “#{page.title}” has been checked by judgement for #{age} days",
      "Write the test that enforces #{rule.id} on #{HandbookNote.name(page)} " <>
        "(§#{rule.section}, line #{rule.line}: “#{rule.text}”), then put its path in place " <>
        "of `judgement`. If no test can check it, say so on the rule, or make it a `should`."
    )
  end

  ## Ids used twice ---------------------------------------------------------------

  defp duplicates(handbook) do
    handbook.pages
    |> Enum.flat_map(fn page ->
      {rules, _problems} = Rules.parse_page(page)
      Enum.map(rules, &{page, &1})
    end)
    |> Enum.group_by(fn {_page, rule} -> rule.id end)
    |> Enum.filter(fn {_id, uses} -> length(uses) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {id, uses} -> duplicate_finding(handbook, id, uses) end)
  end

  defp duplicate_finding(handbook, id, [{first, rule} | _] = uses) do
    pages = uses |> Enum.map(&elem(&1, 0)) |> Enum.uniq_by(& &1.id)

    where =
      Enum.map_join(uses, ", ", fn {page, r} -> "#{page.code || page.title} line #{r.line}" end)

    state = Enum.map(uses, fn {page, r} -> {page.id, r.line, r.text} end)

    HandbookNote.finding(
      handbook,
      pages,
      state,
      "Rule id #{id} is used #{length(uses)} times: #{where}",
      "Keep #{id} on #{first.code || first.title} line #{rule.line}, and give the others " <>
        "new ids, the next free number on their page: ids are never reused, " <>
        "and a review cites a rule by its id."
    )
  end
end
