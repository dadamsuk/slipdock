defmodule Slipdock.Gardener.Checks.StaleDecision do
  @moduledoc """
  Decision pages that lost their thread (#1790): the handbook keeps one
  page per decision in `Handbook/Decisions`, titled `Decision: …`, and a
  decision that replaces another links back to it, so the old page's
  backlinks lead to the new one.

    * A decision that supersedes another without linking to it: a line of
      the new page says it supersedes (or replaces) the old one by its
      title but has no link to it, or a line of the old page says it is
      "superseded by" the new one, which doesn't link back.
    * A page in `Handbook/Decisions` without `Decision:` in its title.

  A page is named by its title, or its title without `Decision:` when that
  leaves at least eight characters (so a short word isn't taken for one).
  A link is any link the wiki recorded from the page's body to the other
  page (`Slipdock.Wiki.Links`): a `[[link]]`, or its bare code (`W-12`),
  which the wiki reads as a link, so naming a page by its code links it.

  The fix comments on the Index saying what to change and where; deciding
  is a person's. Contradictions between pages are left to the triage pass.
  Off on a board without a handbook.
  """
  @behaviour Slipdock.Gardener.Check

  import Ecto.Query

  alias Slipdock.Gardener.HandbookNote
  alias Slipdock.Handbook
  alias Slipdock.Repo
  alias Slipdock.Wiki.Link

  @short 8

  @impl true
  def key, do: "stale_decision"
  @impl true
  def label, do: "Decisions out of order"
  @impl true
  def defaults, do: %{"enabled" => true}

  @impl true
  def find(ctx, _settings) do
    case HandbookNote.handbook(ctx) do
      nil ->
        []

      handbook ->
        decisions = Handbook.decisions(handbook)
        untitled(handbook, decisions) ++ unlinked(handbook, decisions)
    end
  end

  ## Not titled as a decision -----------------------------------------------------

  defp untitled(handbook, decisions) do
    for page <- decisions,
        not String.contains?(String.downcase(page.title), "decision:"),
        do:
          HandbookNote.finding(
            handbook,
            [page],
            page.title,
            "“#{page.title}” is filed in #{Handbook.decisions_folder()} " <>
              "without “Decision:” in its title",
            "Rename #{HandbookNote.name(page)} to “Decision: <what was chosen>”, " <>
              "or file it out of #{Handbook.decisions_folder()} if it isn't a decision."
          )
  end

  ## Superseded without a link back -------------------------------------------------

  defp unlinked(handbook, decisions) do
    links = links(decisions)

    decisions
    |> pairs()
    |> Enum.reject(fn {new, old} -> MapSet.member?(links, {new.id, old.id}) end)
    |> Enum.map(fn {new, old} -> unlinked_finding(handbook, new, old) end)
  end

  @doc false
  # `{newer, older}` for each decision that supersedes another, as either
  # page says it.
  def pairs(decisions) do
    for page <- decisions,
        line <- String.split(page.body || "", "\n"),
        pair <- line_pairs(page, line, decisions),
        uniq: true,
        do: pair
  end

  defp line_pairs(page, line, decisions) do
    cond do
      Regex.match?(~r/superseded\s+by/i, line) ->
        for other <- named(line, page, decisions), do: {other, page}

      Regex.match?(~r/\b(supersedes?|replaces)\b/iu, line) ->
        for other <- named(line, page, decisions), do: {page, other}

      true ->
        []
    end
  end

  # The other decisions `line` names.
  defp named(line, page, decisions) do
    lower = String.downcase(line)
    Enum.filter(decisions, &(&1.id != page.id and names?(lower, &1)))
  end

  defp names?(lower, page) do
    title = String.downcase(page.title)
    short = title |> String.replace(~r/^\s*decision:\s*/, "") |> String.trim()

    String.contains?(lower, title) or
      (String.length(short) >= @short and String.contains?(lower, short))
  end

  # `{from, to}` for each link the pages' bodies make to another page.
  defp links(pages) do
    ids = Enum.map(pages, & &1.id)

    from(l in Link,
      where: l.page_id in ^ids and not is_nil(l.target_page_id),
      select: {l.page_id, l.target_page_id}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp unlinked_finding(handbook, new, old) do
    HandbookNote.finding(
      handbook,
      [new, old],
      {old.id, new.content_hash, old.content_hash},
      "“#{new.title}” supersedes “#{old.title}” without linking back to it",
      "Link #{HandbookNote.name(new)} to the decision it replaces " <>
        "(`Supersedes [[#{old.title}]].`), so whoever reads the old one finds the new one " <>
        "in its backlinks."
    )
  end
end
