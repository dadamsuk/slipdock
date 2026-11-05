defmodule Slipdock.Gardener.Checks.RuleChanged do
  @moduledoc """
  Rules an agent changed without a person's yes (#1791, W-2310 §Upkeep).

  Agents may edit any page: rather than guard every write, this check
  catches a change to a handbook page's rules after the fact. It compares
  the rules in each page's `## Rules` (`Slipdock.Handbook.Rules`) with the
  last version a person approved:

    * the newest revision a person made (any door but an agent's, `api`,
      `mcp` or `cli`; a suggestion a person applied is `gardener`), or
    * the rules a person kept by dismissing an earlier suggestion of this
      check, which records them,

  whichever is newer. A rule added, removed or reworded since (its
  severity, scope, check or text) makes one suggestion per page, naming
  the rules. Applying it reverts the page's `## Rules` to the approved
  text (an `edit_section` step, so the rest of the page is left alone, and
  a section edited again since is refused); dismissing it keeps them, and
  is the approval. Both are a person's to do (`Gardener.person_only?/1`).

  Description and decision pages are free to agents: only rules are
  compared. Off on a board without a handbook.
  """
  @behaviour Slipdock.Gardener.Check

  import Ecto.Query

  alias Slipdock.Gardener.{HandbookNote, Steps, Suggestion}
  alias Slipdock.Handbook.Rules
  alias Slipdock.Repo
  alias Slipdock.Wiki.{Revision, Section}

  @agent_vias ~w(api mcp cli)

  @impl true
  def key, do: "rule_changed"
  @impl true
  def label, do: "Rules changed by an agent"
  @impl true
  def defaults, do: %{"enabled" => true}

  @doc "The doors a revision came through that count as an agent's."
  def agent_vias, do: @agent_vias

  @impl true
  def find(ctx, _settings) do
    case HandbookNote.handbook(ctx) do
      nil ->
        []

      handbook ->
        kept = kept(ctx.board.id)

        for page <- handbook.pages,
            page.id != handbook.index.id,
            finding <- page_finding(page, kept[page.id]),
            do: finding
    end
  end

  defp page_finding(page, kept) do
    with {path, now_text} <- rules_section(page.body),
         {:ok, approved_text} <- approved(page, kept),
         [_ | _] = changes <- changes(page, approved_text, now_text) do
      [finding(page, path, now_text, approved_text, changes)]
    else
      _ -> []
    end
  end

  # The approved Rules text: the newer of the last person's revision and
  # the last keep. Nothing to compare when no person ever wrote the page.
  defp approved(page, kept) do
    person = last_person_revision(page)

    case {person, kept} do
      {nil, nil} -> :none
      {nil, {_, text}} -> {:ok, text}
      {%Revision{body: body}, nil} -> {:ok, rules_text(body)}
      {rev, {at, text}} -> {:ok, newer_of(rev, at, text)}
    end
  end

  defp newer_of(rev, kept_at, kept_text) do
    if DateTime.compare(kept_at, rev.inserted_at) == :lt,
      do: rules_text(rev.body),
      else: kept_text
  end

  defp last_person_revision(page) do
    from(r in Revision,
      where: r.page_id == ^page.id and (is_nil(r.via) or r.via not in @agent_vias),
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: 1
    )
    |> Repo.one()
  end

  # page id => {decided_at, the Rules text kept}, the newest keep each.
  defp kept(board_id) do
    from(s in Suggestion,
      where: s.board_id == ^board_id and s.check == "rule_changed" and s.state == "dismissed",
      order_by: [asc: s.decided_at, asc: s.id]
    )
    |> Repo.all()
    |> Enum.flat_map(fn s ->
      for id <- Suggestion.page_ids(s), do: {id, {s.decided_at, s.subject["rules"] || ""}}
    end)
    |> Map.new()
  end

  ## Comparing ----------------------------------------------------------------------

  @doc false
  # The page's `## Rules` section, as {its heading path, its text}, or nil.
  def rules_section(body) do
    with %{path: path} <- body |> Section.headings() |> Enum.find(&rules_heading?/1),
         {:ok, text} <- Section.read(body, path) do
      {path, text}
    else
      _ -> nil
    end
  end

  defp rules_heading?(h), do: h.level == 2 and String.downcase(String.trim(h.title)) == "rules"

  defp rules_text(body) do
    case rules_section(body) do
      {_path, text} -> text
      nil -> ""
    end
  end

  @doc false
  # What changed between two Rules texts: `{:added | :removed | :reworded, id}`,
  # in id order.
  def changes(page, before_text, after_text) do
    before = by_id(page, before_text)
    after_ = by_id(page, after_text)

    added = for id <- Map.keys(after_) -- Map.keys(before), do: {:added, id}
    removed = for id <- Map.keys(before) -- Map.keys(after_), do: {:removed, id}

    reworded =
      for {id, rule} <- after_, Map.has_key?(before, id), before[id] != rule, do: {:reworded, id}

    Enum.sort_by(added ++ removed ++ reworded, fn {_, id} -> id_order(id) end)
  end

  defp by_id(page, text) do
    {rules, _problems} = Rules.parse_page(%{page | body: text})
    Map.new(rules, &{&1.id, {&1.severity, &1.scope, &1.check, &1.text}})
  end

  defp id_order(id) do
    case String.split(id, "-") do
      [prefix, n] -> {prefix, String.to_integer(n)}
      _ -> {id, 0}
    end
  end

  ## The suggestion -------------------------------------------------------------------

  defp finding(page, path, now_text, approved_text, changes) do
    revert = %{
      "op" => "edit_section",
      "page" => page.id,
      "section" => path,
      "body" => approved_text,
      "base" => Steps.section_hash(now_text)
    }

    %{
      subject: %{"pages" => [page.id], "rules" => now_text},
      state: Steps.section_hash(now_text),
      proposal: [revert],
      explanation:
        "An agent changed the rules on #{HandbookNote.name(page)} since a person last approved them: " <>
          describe(changes) <>
          ". Apply puts back the approved rules; Dismiss keeps the change"
    }
  end

  defp describe(changes) do
    changes
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> then(fn groups ->
      for kind <- [:added, :reworded, :removed],
          ids = groups[kind],
          ids != nil,
          do: "#{kind} #{Enum.join(ids, ", ")}"
    end)
    |> Enum.join("; ")
  end
end
