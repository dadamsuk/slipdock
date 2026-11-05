defmodule Slipdock.Handbook.Rules do
  @moduledoc """
  A handbook's rules (#1773, spec W-2310 §Rules): the statements a change
  must (or should) keep to, each one citable and checkable.

  Rules live in a `## Rules` section of the handbook page they belong to,
  one list item each:

      - **UX-4** must · test/slipdock_web/design_tokens_test.exs · No hex, rgb() or oklch() under lib/slipdock_web.
      - **DATA-2** should · scope priv/repo/migrations/** · judgement · A migration never edits one already run.

  The parts are separated by ` · ` (a middle dot with a space either side):

    * **id**, in bold: the page's prefix (`prefix/1`), a dash and a number,
      never reused;
    * **severity**: `must` (a verifier rejects work that breaks it) or
      `should` (it is noted);
    * **scope**, optional: `scope` and the path globs it applies to,
      separated by commas. Without one, the page's `covers:` is the scope,
      and a page that covers nothing makes the rule apply everywhere (`**`);
    * **check**: the test that enforces it (a path, or several separated by
      commas), or `judgement` when an agent has to judge it;
    * the **text**, the rest of the item. Indented lines under it continue
      it.

  `### ` headings inside `## Rules` group rules; each rule records the
  section it is in. Anything in the section that is not a list item (an
  italic hint, a paragraph) is ignored, so the skeleton's hint is harmless.

  Parsing never raises: an item that doesn't read as a rule is left out and
  reported, with the page and the line, by `parse/1`.
  """

  alias Slipdock.Handbook
  alias Slipdock.Wiki.{Page, Section}

  @prefixes %{
    "specification" => "SPEC",
    "architecture" => "ARCH",
    "ux" => "UX",
    "components" => "COMP",
    "data-model" => "DATA",
    "shared-modules" => "MOD",
    "testing" => "TEST",
    "operations" => "OPS"
  }

  @severities ~w(must should)
  @sep ~r/[ \t]+·[ \t]+/u
  @item ~r/^[-*+][ \t]+(.*)$/
  @id ~r/^\*\*([A-Z][A-Z0-9]*)-(\d+)\*\*[ \t]*(.*)$/
  @check_path ~r{^[\w.\-*/:]+$}

  @type rule :: %{
          id: String.t(),
          page: String.t(),
          page_title: String.t(),
          section: String.t(),
          line: pos_integer,
          severity: String.t(),
          scope: [String.t()],
          check: String.t(),
          text: String.t()
        }

  @type problem :: %{page: String.t(), line: pos_integer, item: String.t(), problem: String.t()}

  @doc """
  The rule-id prefix for a page's `handbook:` key: `UX` for `ux`, `DATA` for
  `data-model` and so on for the built-in sections; any other key upcased,
  without its dashes.
  """
  def prefix(key) when is_binary(key),
    do: Map.get(@prefixes, key, key |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, ""))

  def prefix(_), do: nil

  @doc "Every rule in `handbook` (as `Handbook.find/1` returns it), page by page."
  @spec rules(map | nil) :: [rule]
  def rules(handbook), do: handbook |> parse() |> elem(0)

  @doc "What `parse/1` couldn't read as a rule, with the page and line of each."
  @spec problems(map | nil) :: [problem]
  def problems(handbook), do: handbook |> parse() |> elem(1)

  @doc """
  The rules and the problems of a whole handbook. An id used twice is kept
  where it first appears (pages in the handbook's order) and reported where
  it appears again.
  """
  @spec parse(map | nil) :: {[rule], [problem]}
  def parse(nil), do: {[], []}

  def parse(%{pages: pages}) do
    {rules, problems} =
      pages
      |> Enum.map(&parse_page/1)
      |> Enum.reduce({[], []}, fn {r, p}, {rules, problems} ->
        {rules ++ r, problems ++ p}
      end)

    {rules, dupes} = drop_duplicates(rules)
    {rules, problems ++ dupes}
  end

  @doc "The rules and problems of one page."
  @spec parse_page(Page.t()) :: {[rule], [problem]}
  def parse_page(%Page{} = page) do
    page.body
    |> rules_spans()
    |> Enum.flat_map(&items(page.body, &1))
    |> Enum.map(&read_item(&1, page))
    |> Enum.split_with(&match?({:rule, _}, &1))
    |> then(fn {rules, problems} ->
      {Enum.map(rules, &elem(&1, 1)), Enum.map(problems, &elem(&1, 1))}
    end)
  end

  # Each `## Rules` section as {first line, end line, its path}, 0-based and
  # end-exclusive, heading line excluded.
  defp rules_spans(body) do
    headings = Section.headings(body)
    total = length(String.split(body || "", "\n"))

    for {h, i} <- Enum.with_index(headings),
        h.level == 2 and String.downcase(String.trim(h.title)) == "rules" do
      stop =
        headings
        |> Enum.drop(i + 1)
        |> Enum.find(&(&1.level <= 2))
        |> case do
          nil -> total
          next -> next.line
        end

      inner = Enum.filter(headings, &(&1.line > h.line and &1.line < stop))
      {h.line + 1, stop, h.path, inner}
    end
  end

  # The list items of one span as {line (1-based), text, section path}.
  # Indented lines continue the item above them.
  defp items(body, {from, stop, path, inner}) do
    body
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.slice(from..(stop - 1)//1)
    |> Enum.reduce({[], path, false, false}, fn {line, index}, {items, section, open, fenced} ->
      heading = Enum.find(inner, &(&1.line == index))
      section = if heading, do: heading.path, else: section
      {items, open, fenced} = step(line, index, section, {items, open, fenced or heading != nil})
      {items, section, open, fenced and is_nil(heading)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # One line of a Rules section: `{items, open, fenced}` after it, where
  # `open` says an item is waiting for continuation lines. A heading line
  # arrives as fenced, so it is skipped like fenced code.
  defp step(line, index, section, {items, open, fenced}) do
    cond do
      String.starts_with?(String.trim_leading(line), ["```", "~~~"]) ->
        {items, false, not fenced}

      fenced ->
        {items, false, fenced}

      match = Regex.run(@item, line) ->
        [_, text] = match
        {[{index + 1, String.trim(text), section} | items], true, false}

      open and Regex.match?(~r/^[ \t]+\S/, line) ->
        [{at, text, sec} | rest] = items
        {[{at, text <> " " <> String.trim(line), sec} | rest], true, false}

      true ->
        {items, false, false}
    end
  end

  defp read_item({line, text, section}, page) do
    problem = fn reason ->
      {:problem, %{page: page.code, line: line, item: text, problem: reason}}
    end

    with {:id, [_, pre, num, rest]} <- {:id, Regex.run(@id, text)},
         [severity | parts] = String.split(rest, @sep),
         severity = String.downcase(String.trim(severity)),
         {:severity, true} <- {:severity, Enum.member?(@severities, severity)},
         {scope, parts} = scope(parts, page),
         {:check, [check | words]} <- {:check, parts},
         {:check, check} when check != nil <- {:check, check(check)},
         text = words |> Enum.join(" · ") |> String.trim(),
         {:text, true} <- {:text, text != ""} do
      {:rule,
       %{
         id: "#{pre}-#{num}",
         page: page.code,
         page_title: page.title,
         section: section,
         line: line,
         severity: severity,
         scope: scope,
         check: check,
         text: text
       }}
      |> wrong_prefix(pre, page, problem)
    else
      {:id, _} -> problem.("no rule id: start the item with one in bold, like **UX-1**")
      {:severity, _} -> problem.("no severity: `must` or `should` after the id")
      {:check, _} -> problem.("no check: a test path, or `judgement`")
      {:text, _} -> problem.("no text: say what the rule is after the check")
    end
  end

  # A rule whose id doesn't carry its page's prefix still counts, and is
  # reported so somebody renames it.
  defp wrong_prefix({:rule, rule} = ok, pre, page, problem) do
    case prefix(Handbook.key(page)) do
      nil ->
        ok

      ^pre ->
        ok

      wanted ->
        {:problem, p} = problem.("#{rule.id} should start #{wanted}- on this page")
        {:rule, Map.put(rule, :problem, p)}
    end
  end

  defp scope([first | rest] = parts, page) do
    case Regex.run(~r/^scope[ \t]+(.+)$/i, String.trim(first)) do
      [_, globs] -> {split_list(globs), rest}
      nil -> {covers(page), parts}
    end
  end

  defp scope([], page), do: {covers(page), []}

  defp covers(page) do
    case page |> Handbook.field("covers") |> List.wrap() |> Enum.filter(&is_binary/1) do
      [] -> ["**"]
      globs -> globs
    end
  end

  defp check(part) do
    part = part |> String.trim() |> String.trim("`")

    cond do
      Enum.member?(["judgement", "judgment"], String.downcase(part)) ->
        "judgement"

      (paths = split_list(part)) != [] and
          Enum.all?(paths, &(Regex.match?(@check_path, &1) and String.contains?(&1, "/"))) ->
        Enum.join(paths, ", ")

      true ->
        nil
    end
  end

  defp split_list(text) do
    text
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.trim("`")))
    |> Enum.reject(&(&1 == ""))
  end

  defp drop_duplicates(rules) do
    {kept, dupes, _} =
      Enum.reduce(rules, {[], [], %{}}, fn rule, {kept, dupes, seen} ->
        case seen[rule.id] do
          nil ->
            {[rule | kept], dupes, Map.put(seen, rule.id, rule)}

          first ->
            problem = %{
              page: rule.page,
              line: rule.line,
              item: rule.id,
              problem: "#{rule.id} is already used on #{first.page} line #{first.line}"
            }

            {kept, [problem | dupes], seen}
        end
      end)

    kept = Enum.reverse(kept)
    prefix_problems = for %{problem: p} <- kept, do: p
    {Enum.map(kept, &Map.delete(&1, :problem)), prefix_problems ++ Enum.reverse(dupes)}
  end
end
