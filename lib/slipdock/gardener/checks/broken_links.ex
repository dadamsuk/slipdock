defmodule Slipdock.Gardener.Checks.BrokenLinks do
  @moduledoc """
  `[[links]]` to pages that don't exist but nearly do (W-1807): the wanted
  title matches one existing page's title or alias ignoring case, or — when
  none does — is within `max_distance` edits (default 2) of exactly one.
  Short titles (under four letters) only match exactly; two candidates is
  ambiguous and suggests nothing. The fix rewrites the link to the page,
  on every page that has it.
  """
  @behaviour Slipdock.Gardener.Check

  import Ecto.Query

  alias Slipdock.Repo
  alias Slipdock.Wiki.{Links, Page}

  @impl true
  def key, do: "broken_links"
  @impl true
  def label, do: "Links that nearly match a page"
  @impl true
  def defaults, do: %{"enabled" => true, "max_distance" => 2}

  @min_fuzzy 4

  @impl true
  def find(ctx, %{"max_distance" => max}) do
    pages =
      from(p in Page,
        where: p.board_id in ^ctx.board_ids and is_nil(p.archived_at),
        select: struct(p, [:id, :title, :aliases, :board_id])
      )
      |> Repo.all()

    names =
      for p <- pages,
          name <- [p.title | p.aliases || []],
          name not in [nil, ""],
          do: {String.downcase(String.trim(name)), p}

    for {title, from} <- wanted(ctx.board_ids),
        from != [],
        %Page{} = target <- [match(title, names, max)] do
      linking = Enum.sort_by(from, & &1.id)

      %{
        subject: %{"pages" => Enum.map(linking, & &1.id) ++ [target.id]},
        state: String.downcase(title),
        proposal:
          for(
            p <- linking,
            do: %{"op" => "rewrite_link", "page" => p.id, "from" => title, "to" => target.title}
          ),
        explanation:
          "[[#{title}]] on #{on_pages(linking)} leads nowhere; “#{target.title}” is probably the page meant"
      }
    end
  end

  # Wanted titles, the ways of writing one that differ only in case taken
  # together (resolving ignores case, and so does the rewrite), with every
  # page on the run's boards that links to it.
  defp wanted(board_ids) do
    board_ids
    |> Links.wanted()
    |> Enum.map(&{String.trim(&1.title), &1.from})
    |> Enum.reject(fn {title, _} -> title == "" or String.contains?(title, "/") end)
    |> Enum.group_by(fn {title, _} -> String.downcase(title) end)
    |> Enum.map(fn {_, [{title, _} | _] = group} ->
      from =
        group
        |> Enum.flat_map(&elem(&1, 1))
        |> Enum.filter(&(&1.board_id in board_ids))
        |> Enum.uniq_by(& &1.id)

      {title, from}
    end)
  end

  # The one page `title` most likely means, or nil.
  defp match(title, names, max) do
    down = String.downcase(title)

    case uniq_pages(for {name, p} <- names, name == down, do: p) do
      [page] ->
        page

      [] ->
        if String.length(down) < @min_fuzzy do
          nil
        else
          close =
            for {name, p} <- names,
                String.length(name) >= @min_fuzzy,
                abs(String.length(name) - String.length(down)) <= max,
                distance(name, down) <= max,
                do: p

          case uniq_pages(close) do
            [page] -> page
            _ -> nil
          end
        end

      _ambiguous ->
        nil
    end
  end

  defp uniq_pages(pages), do: Enum.uniq_by(pages, & &1.id)

  defp on_pages([page]), do: "“#{page.title}”"
  defp on_pages(pages), do: "#{length(pages)} pages"

  @doc "The Levenshtein distance between two strings, by grapheme."
  def distance(a, b) do
    a = String.graphemes(a)
    b = String.graphemes(b)
    first = Enum.to_list(0..length(b))

    a
    |> Enum.with_index(1)
    |> Enum.reduce(first, fn {ca, i}, prev ->
      {row, _} =
        b
        |> Enum.zip(Enum.zip(prev, tl(prev)))
        |> Enum.reduce({[i], i}, fn {cb, {diag, up}}, {row, left} ->
          cost = if ca == cb, do: 0, else: 1
          value = Enum.min([up + 1, left + 1, diag + cost])
          {[value | row], value}
        end)

      Enum.reverse(row)
    end)
    |> List.last()
  end
end
