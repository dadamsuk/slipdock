defmodule SlipdockWeb.SearchLinks do
  @moduledoc """
  Where a search match lives, as a link that lands on it rather than on the
  card it belongs to: the comment, the status update, the meeting quote, the
  part of a recording's transcript, or the section of a wiki page.

  A card is opened with `?at=<dom id>` (see `at/1`), which the card panel
  scrolls to and lights up, opening a transcript at the part that matched.
  The search page, the API and the MCP search tool all link through here, so
  a person and an agent are pointed at the same place.
  """

  alias Slipdock.Boards.Card
  alias Slipdock.Wiki.{Files, Page, WikiFile}

  @doc "The path of `match` (a chunk with `kind`, `source_id` and `section`) within its card or page."
  def path(%Card{} = card, match) do
    base = "/boards/#{card.board_id}/cards/#{card.id}"

    case anchor(match) do
      nil -> base
      at -> base <> "?" <> URI.encode_query(at: at)
    end
  end

  def path(%WikiFile{} = file, _match), do: Files.open_path(file)

  def path(%Page{} = page, match) do
    base = "/boards/#{page.board_id}/wiki/#{page.slug}"

    case match do
      %{kind: "page_document"} ->
        base

      %{section: section} when is_binary(section) and section != "" ->
        base <> "#" <> SlipdockWeb.Wiki.Renderer.anchor(section_title(section))

      _ ->
        base
    end
  end

  @doc "The DOM id a card's chunk is drawn under in the card panel, or nil for the card itself."
  def anchor(%{kind: "comment", source_id: id}), do: "comment-#{id}"
  def anchor(%{kind: "status_update", source_id: id}), do: "status-update-#{id}"
  def anchor(%{kind: "provenance", source_id: id}), do: "provenance-#{id}"

  def anchor(%{kind: "transcript", source_id: id, section: "part " <> n}),
    do: "transcript-#{id}-part-#{n}"

  def anchor(%{kind: "transcript", source_id: id}), do: "transcript-#{id}"

  def anchor(%{kind: "document", source_id: id, section: "part " <> n}),
    do: "document-#{id}-part-#{n}"

  def anchor(%{kind: "document", source_id: id}), do: "document-#{id}"
  def anchor(_), do: nil

  @doc """
  An `?at=` value as the card panel accepts it: one of the shapes `anchor/1`
  writes, or nil. Anything else is ignored rather than looked for.
  """
  def at(value) when is_binary(value) do
    if value =~ ~r/\A(comment|status-update|provenance|transcript|document)-\d+(-part-\d+)?\z/,
      do: value
  end

  def at(_), do: nil

  @doc "A page section's own heading: `Deploy/Rollback#2` is the second part of Rollback."
  def section_title(section) do
    section
    |> String.split("#", parts: 2)
    |> hd()
    |> String.split("/")
    |> List.last()
  end

  @doc """
  What to call a match in a list of results: the page section's heading,
  "transcript of call.mp3, part 2 of 5", or what kind of thing it is.
  """
  def label(%{kind: kind, section: section})
      when kind in ["page", "page_section"] and section != "",
      do: section_title(section)

  def label(%{kind: "transcript", body: body}) do
    case Regex.run(~r/\ATranscript of the recording “([^”]*)”.*?(part \d+ of \d+)?:\n/u, body) do
      [_, file, part] -> "transcript of #{file}, #{part}"
      [_, file] -> "transcript of #{file}"
      _ -> "recording transcript"
    end
  end

  def label(%{kind: kind, body: body}) when kind in ~w(document page_document file_document) do
    case Regex.run(~r/\AText of the file “([^”]*)”.*?(part \d+ of \d+)?:\n/u, body) do
      [_, file, part] -> "text of #{file}, #{part}"
      [_, file] -> "text of #{file}"
      _ -> "text in a file"
    end
  end

  def label(%{kind: kind}), do: Slipdock.Search.Embedding.label(kind)
end
