defmodule Slipdock.Search.Chunk do
  @moduledoc """
  Turns a card, or a wiki page, into the pieces of text that get embedded.

  One chunk per thing that was written by a person: the card itself (title,
  description, checklist and its facets), each comment, each status update,
  and **each section of a page**. Embedding them separately rather than
  rolling a card into one vector is what lets a search for "the Stripe
  webhook problem" land on the comment that said it, and it means editing one
  comment — or one section — re-embeds one chunk rather than everything.

  A page is split by heading rather than by a fixed window, because a section
  is what a person wrote as a unit and a heading is a free label for it. A
  short page is one chunk; a long section is split on paragraph boundaries
  with its heading repeated.

  Every chunk repeats where it lives — board, list, card title, page path —
  because a vector has no context but its own text, and "waiting on legal"
  means very little on its own. The same text is what a result shows as its
  snippet and what the assistant is given to read, so it is written to be
  read.
  """

  alias Slipdock.Boards.{Card, Comment, StatusUpdate}
  alias Slipdock.Wiki.{Markup, Page, Section}

  @type t :: %{
          kind: String.t(),
          source_id: integer,
          section: String.t(),
          card_id: integer | nil,
          page_id: integer | nil,
          board_id: integer,
          body: String.t()
        }

  # Longer than this and one section is split; shorter and a page is one
  # chunk. Both are about what a single vector can usefully stand for.
  @max_section 1500
  @min_page 600

  @doc """
  Every chunk for `card`, which must be preloaded with `:board`, `:column`,
  `:tags`, `:assignee`, `:checklist_items`, `:comments` and `:status_updates`
  (see `Slipdock.Search.card_query/0`).
  """
  @spec for_card(Card.t()) :: [t]
  def for_card(%Card{} = card) do
    [card_chunk(card)] ++
      Enum.map(card.comments, &comment_chunk(&1, card)) ++
      Enum.map(card.status_updates, &status_chunk(&1, card))
  end

  @doc """
  Every chunk for a wiki page, which must be preloaded with `:board`.

  A short page is one `page` chunk. A longer one becomes a `page_section`
  chunk per heading, each carrying its own heading path so a result can link
  straight to it, and each repeating the board and page title so the vector
  has somewhere to stand.

  A draft is not indexed at all. Search has no idea who is asking at index
  time, and a half-written page turning up in someone's results is exactly
  what `status: draft` is for.
  """
  @spec for_page(Page.t()) :: [t]
  def for_page(%Page{status: "draft"}), do: []
  def for_page(%Page{archived_at: at}) when not is_nil(at), do: []

  def for_page(%Page{} = page) do
    body = plain(page.body)

    cond do
      String.trim(body) == "" and String.trim(to_string(page.summary)) == "" ->
        [page_chunk(page, whole_page_body(page, body))]

      String.length(body) <= @min_page ->
        [page_chunk(page, whole_page_body(page, body))]

      true ->
        case section_chunks(page, body) do
          [] -> [page_chunk(page, whole_page_body(page, body))]
          chunks -> chunks
        end
    end
  end

  @doc "The SHA-256 of a chunk body, as lower-case hex."
  @spec hash(String.t()) :: String.t()
  def hash(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  ## The chunks ---------------------------------------------------------------

  defp card_chunk(%Card{} = card) do
    body =
      [
        where(card),
        "Card: #{card.title}",
        facets(card),
        section("Description", card.description),
        checklist(card)
      ]
      |> join()

    %{
      kind: "card",
      source_id: card.id,
      section: "",
      card_id: card.id,
      page_id: nil,
      board_id: card.board_id,
      body: body
    }
  end

  defp comment_chunk(%Comment{} = comment, %Card{} = card) do
    body =
      [
        "Comment on card “#{card.title}” (#{where_inline(card)}), #{on(comment.inserted_at)}:",
        comment.body
      ]
      |> join()

    %{
      kind: "comment",
      source_id: comment.id,
      section: "",
      card_id: card.id,
      page_id: nil,
      board_id: card.board_id,
      body: body
    }
  end

  defp status_chunk(%StatusUpdate{} = update, %Card{} = card) do
    body =
      [
        "Status update on card “#{card.title}” (#{where_inline(card)}), #{on(update.inserted_at)}: " <>
          StatusUpdate.health_label(update.health),
        update.body
      ]
      |> join()

    %{
      kind: "status_update",
      source_id: update.id,
      section: "",
      card_id: card.id,
      page_id: nil,
      board_id: card.board_id,
      body: body
    }
  end

  ## Page chunks -------------------------------------------------------------

  defp whole_page_body(%Page{} = page, body) do
    [page_where(page), "Page: #{page.title}", page.summary, body] |> join()
  end

  defp page_chunk(%Page{} = page, body) do
    %{
      kind: "page",
      source_id: page.id,
      section: "",
      card_id: nil,
      page_id: page.id,
      board_id: page.board_id,
      body: body
    }
  end

  defp section_chunks(%Page{} = page, body) do
    case Section.headings(body) do
      [] ->
        []

      headings ->
        preamble = preamble_chunk(page, body, hd(headings))

        sections =
          Enum.flat_map(headings, fn heading ->
            case Section.read(body, heading.path) do
              {:ok, text} -> split_section(page, heading.path, text)
              _ -> []
            end
          end)

        preamble ++ sections
    end
  end

  # Whatever a page says before its first heading is often the summary of the
  # whole thing, and would otherwise never be embedded.
  defp preamble_chunk(%Page{} = page, body, first) do
    text = body |> String.split("\n") |> Enum.take(first.line) |> Enum.join("\n") |> String.trim()

    if text == "" do
      []
    else
      [section_chunk(page, "", [page_where(page), "Page: #{page.title}", page.summary, text])]
    end
  end

  defp split_section(%Page{} = page, path, text) do
    if String.length(text) <= @max_section do
      [section_chunk(page, path, [page_where(page), "Page: #{page.title} › #{path}", text])]
    else
      text
      |> String.split(~r/\n\s*\n/)
      |> chunk_paragraphs()
      |> Enum.with_index(1)
      |> Enum.map(fn {part, n} ->
        section_chunk(page, "#{path}##{n}", [
          page_where(page),
          "Page: #{page.title} › #{path} (part #{n})",
          part
        ])
      end)
    end
  end

  # Paragraphs are gathered until adding the next would overflow, so a split
  # never lands in the middle of a sentence.
  defp chunk_paragraphs(paragraphs) do
    paragraphs
    |> Enum.reduce([], fn paragraph, acc ->
      case acc do
        [current | rest] when byte_size(current) + byte_size(paragraph) < @max_section ->
          [current <> "\n\n" <> paragraph | rest]

        _ ->
          [paragraph | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp section_chunk(%Page{} = page, path, parts) do
    %{
      kind: "page_section",
      source_id: page.id,
      section: path,
      card_id: nil,
      page_id: page.id,
      board_id: page.board_id,
      body: join(parts)
    }
  end

  defp page_where(%Page{board: %{name: name}, code: code}), do: "Board: #{name} › wiki (#{code})"
  defp page_where(%Page{code: code}), do: "Wiki page #{code}"

  # A vector should be built from words, not from syntax: `[[Retry policy]]`
  # embeds as "Retry policy", and a live query block embeds as nothing at all
  # since its answer is not part of what the page says.
  defp plain(nil), do: ""

  defp plain(body) do
    body
    |> String.replace(~r/^\s*(```|~~~)(?:slipdock|kanban).*?^\s*\1\s*$/ms, "")
    |> Markup.to_plain()
  end

  ## Pieces -------------------------------------------------------------------

  defp where(%Card{} = card) do
    board = board_name(card)
    column = card.column && card.column.name

    cond do
      board && column -> "Board: #{board} › list: #{column}"
      board -> "Board: #{board}"
      true -> nil
    end
  end

  defp where_inline(%Card{} = card), do: board_name(card) || "unknown board"

  defp board_name(%Card{board: %{name: name}}), do: name
  defp board_name(_), do: nil

  # The facets a person would search by in words rather than filters: "the
  # critical billing card", "what is Ana blocked on", "anything due in March".
  defp facets(%Card{} = card) do
    [
      card.priority not in [nil, "none"] && "priority #{card.priority}",
      card.completed && "completed",
      card.archived_at && "archived",
      card.start_date && "starts #{card.start_date}",
      card.due_date && "due #{card.due_date}",
      card.percent_complete && "#{card.percent_complete}% complete",
      assignee(card),
      tags(card),
      flags(card)
    ]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp assignee(%Card{assignee: %{} = user}),
    do: "assigned to #{Slipdock.Accounts.User.display_name(user)}"

  defp assignee(_), do: nil

  defp tags(%Card{tags: tags}) when is_list(tags) and tags != [],
    do: "tags: " <> Enum.map_join(tags, ", ", & &1.name)

  defp tags(_), do: nil

  defp flags(%Card{flags: flags}) when is_list(flags) and flags != [],
    do: "flags: " <> Enum.join(flags, ", ")

  defp flags(_), do: nil

  defp checklist(%Card{checklist_items: items}) when is_list(items) and items != [] do
    "Checklist:\n" <>
      Enum.map_join(items, "\n", &"- [#{if &1.done, do: "x", else: " "}] #{&1.text}")
  end

  defp checklist(_), do: nil

  defp section(_title, nil), do: nil

  defp section(title, text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> "#{title}:\n#{trimmed}"
    end
  end

  defp on(%DateTime{} = at), do: Date.to_iso8601(DateTime.to_date(at))
  defp on(_), do: "undated"

  defp join(parts) do
    parts
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("\n")
  end
end
