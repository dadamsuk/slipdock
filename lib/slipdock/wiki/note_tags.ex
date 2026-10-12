defmodule Slipdock.Wiki.NoteTags do
  @moduledoc """
  The tags a note gives itself, the way Obsidian reads them (W-103 R3.4):
  its front matter's `tags`, and every inline `#tag` or nested `#area/sub`
  in its body.

  Only on a board that belongs to a vault. Everywhere else `#word` is just a
  word, as it always was, and a page's `note_tags` stay empty. They are kept
  apart from the board's tags (the ones cards wear, chosen from a picker): a
  vault of notes can carry hundreds, and none of them belongs in that picker.

  What counts as an inline tag:

    * `#` at the start of a word — so `example.com/#top` is a URL, not a tag;
    * letters, digits, `_`, `-` and `/` after it;
    * not in code, a heading, a link or raw HTML;
    * not a card: a tag whose first segment is all digits (`#412`, `#2026/q1`)
      stays the card reference it has always been.

  Tags are stored lower-case and once each, so `#Ideas` and `#ideas` are one.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Repo, Vaults}
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.{FrontMatter, Page}

  @inline ~r/(?<![^\s(\[{,;:'"])#([\p{L}\p{N}_][\p{L}\p{N}_\-\/]*)/u

  @doc "Every tag `body` and `front_matter` (a stored header) give a note, sorted."
  @spec extract(String.t() | nil, String.t() | nil) :: [String.t()]
  def extract(body, front_matter) do
    (front_matter_tags(front_matter) ++ inline(body || ""))
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == "" or card?(&1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The inline `#tags` in a Markdown body, as written, outside code, headings and links."
  def inline(body) do
    case MDEx.parse_document(body,
           extension: [table: true, tasklist: true, strikethrough: true, autolink: true]
         ) do
      {:ok, doc} ->
        doc
        |> texts()
        |> Enum.flat_map(fn text -> Regex.scan(@inline, text, capture: :all_but_first) end)
        |> List.flatten()

      _ ->
        []
    end
  end

  # Text nodes, not descending into the nodes whose text is not prose.
  defp texts(%MDEx.Text{literal: literal}), do: [literal]

  defp texts(%type{})
       when type in [
              MDEx.Heading,
              MDEx.Link,
              MDEx.Image,
              MDEx.Code,
              MDEx.CodeBlock,
              MDEx.HtmlBlock,
              MDEx.HtmlInline
            ],
       do: []

  defp texts(%{nodes: nodes}) when is_list(nodes), do: Enum.flat_map(nodes, &texts/1)
  defp texts(_), do: []

  defp front_matter_tags(nil), do: []

  defp front_matter_tags(header) do
    case header |> FrontMatter.yaml() |> FrontMatter.get("tags") do
      nil -> []
      list when is_list(list) -> list
      # `tags: a, b` and `tags: a b` both mean two tags in Obsidian.
      text -> String.split(text, ~r/[,\s]+/, trim: true)
    end
  end

  defp normalize(tag) do
    tag
    |> String.trim()
    |> String.trim_leading("#")
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp card?(tag), do: tag |> String.split("/") |> hd() |> String.match?(~r/\A\d+\z/)

  @doc """
  Brings a saved page's `note_tags` up to date: what its text says when its
  board is in a vault, nothing when it is not. Writes only on a change, and
  hands back the page as it now stands.
  """
  def refresh(%Page{} = page) do
    wanted =
      if Vaults.in_vault?(page.board_id), do: extract(page.body, page.front_matter), else: []

    if wanted != page.note_tags do
      Repo.update_all(from(p in Page, where: p.id == ^page.id), set: [note_tags: wanted])
    end

    %{page | note_tags: wanted}
  end

  @doc "Every page of a board, after the board joins or leaves a vault."
  def refresh_board(%Board{id: id}), do: refresh_board(id)

  def refresh_board(board_id) when is_integer(board_id) do
    from(p in Page, where: p.board_id == ^board_id)
    |> Repo.all()
    |> Enum.each(&refresh/1)
  end

  @doc """
  A board's note tags with how many pages carry each, most-used first. A tag
  counts for its parents too, as in Obsidian: a page tagged `area/sub` is
  under `area`.
  """
  def counts(%Board{id: board_id}) do
    from(p in Page,
      where: p.board_id == ^board_id and is_nil(p.archived_at),
      select: p.note_tags
    )
    |> Repo.all()
    |> Enum.flat_map(fn tags -> tags |> Enum.flat_map(&with_parents/1) |> Enum.uniq() end)
    |> Enum.frequencies()
    |> Enum.map(fn {tag, count} -> %{tag: tag, count: count} end)
    |> Enum.sort_by(&{-&1.count, &1.tag})
  end

  defp with_parents(tag) do
    parts = String.split(tag, "/")
    for n <- 1..length(parts), do: parts |> Enum.take(n) |> Enum.join("/")
  end

  @doc "Narrows a page query to pages tagged `tag` or anything nested under it."
  def where_tagged(query, tag) do
    tag = normalize(tag)

    where(
      query,
      [p],
      fragment(
        "EXISTS (SELECT 1 FROM unnest(?) AS t WHERE t = ? OR starts_with(t, ? || '/'))",
        p.note_tags,
        ^tag,
        ^tag
      )
    )
  end
end
