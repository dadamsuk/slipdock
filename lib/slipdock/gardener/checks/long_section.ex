defmodule Slipdock.Gardener.Checks.LongSection do
  @moduledoc """
  Handbook sections too long to point at (#1790): a `##` section of a
  handbook page (or a decision) over `chars` characters, heading and
  subsections included. The seed asks for sections under about 1,500;
  past that, search splits a section in parts and a suggestion can only
  point at a part.

  Two sections are left alone: `## Rules`, whose length is how many rules
  the page has (splitting it would move rules out of it, and they would
  stop being rules), and the Index's `## Log`, which grows by design.

  Where the section has a `###` subsection, the fix splits it there: an
  `edit_section` that keeps every line and promotes that subsection's
  heading to `##`, so the section becomes two. It splits at the first
  `###` with text before it, and only when the result is unambiguous (no
  other `##` with that title on the page, and the section's path finds this
  section). Otherwise, and as the other choice, it comments on the Index
  naming the page and the section. Off on a board without a handbook.
  """
  @behaviour Slipdock.Gardener.Check

  alias Slipdock.Gardener.{HandbookNote, Steps}
  alias Slipdock.Wiki.Section

  @impl true
  def key, do: "long_section"
  @impl true
  def label, do: "Long handbook sections"
  @impl true
  def defaults, do: %{"enabled" => true, "chars" => 1500}

  @impl true
  def find(ctx, settings) do
    case HandbookNote.handbook(ctx) do
      nil ->
        []

      handbook ->
        for page <- HandbookNote.pages(handbook),
            finding <- page_findings(handbook, page, settings["chars"]),
            do: finding
    end
  end

  defp page_findings(handbook, page, limit) do
    headings = Section.headings(page.body)
    lines = String.split(page.body || "", "\n")

    for {h, i} <- Enum.with_index(headings),
        h.level == 2 and not exempt?(handbook, page, h),
        span = span(headings, i, length(lines)),
        text = lines |> Enum.slice(span) |> Enum.join("\n") |> String.trim_trailing(),
        String.length(text) > limit,
        do: finding(handbook, page, {h, span, text}, headings, limit)
  end

  defp exempt?(handbook, page, h) do
    case String.downcase(h.title) do
      "rules" -> true
      "log" -> page.id == handbook.index.id
      _ -> false
    end
  end

  # The lines a `##` section takes: up to the next heading of level 2 or above.
  defp span(headings, i, total) do
    h = Enum.at(headings, i)

    stop =
      headings
      |> Enum.drop(i + 1)
      |> Enum.find(&(&1.level <= 2))
      |> case do
        nil -> total
        next -> next.line
      end

    h.line..(stop - 1)//1
  end

  defp finding(handbook, page, {h, _span, text} = section, headings, limit) do
    chars = String.length(text)

    found =
      "§#{h.path} of “#{page.title}” is #{chars} characters, over #{limit}, " <>
        "so search splits it in parts"

    comment =
      HandbookNote.finding(
        handbook,
        [page],
        {h.path, Steps.section_hash(text)},
        found,
        "Split §#{h.path} of #{HandbookNote.name(page)} into `##` sections of one subject each, " <>
          "under #{limit} characters."
      )

    case split(page, section, headings) do
      nil ->
        comment

      {at, step} ->
        %{
          comment
          | proposal: [step],
            explanation: found <> ": split it at “### #{at.title}” into two `##` sections"
        }
        |> Map.put(:alternatives, %{"comment" => comment.proposal})
    end
  end

  # `{the ### heading, the edit_section step}` that splits the section in
  # two, or nil when there is nowhere to split it cleanly.
  defp split(page, {h, span, text}, headings) do
    with {:ok, ^text} <- read(page.body, h.path),
         %{} = at <- split_at(page.body, h, span, headings),
         false <- taken?(headings, at.title) do
      body =
        text
        |> String.split("\n")
        |> List.update_at(at.line - h.line, &promote/1)
        |> Enum.join("\n")

      {at,
       %{
         "op" => "edit_section",
         "page" => page.id,
         "section" => h.path,
         "body" => body,
         "base" => Steps.section_hash(text)
       }}
    else
      _ -> nil
    end
  end

  defp read(body, path) do
    with {:ok, text} <- Section.read(body, path), do: {:ok, String.trim_trailing(text)}
  end

  # The first `###` inside the section with some text above it.
  defp split_at(body, h, span, headings) do
    lines = String.split(body, "\n")

    Enum.find(headings, fn s ->
      s.level == 3 and Enum.member?(span, s.line) and
        lines |> Enum.slice((h.line + 1)..(s.line - 1)//1) |> Enum.any?(&(String.trim(&1) != ""))
    end)
  end

  defp taken?(headings, title) do
    Enum.any?(headings, &(&1.level == 2 and String.downcase(&1.title) == String.downcase(title)))
  end

  defp promote(line), do: String.replace(line, ~r/^(\s*)###/, "\\1##", global: false)
end
