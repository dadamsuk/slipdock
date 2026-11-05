defmodule Slipdock.Gardener.HandbookNote do
  @moduledoc """
  What the handbook hygiene checks share (#1790): the handbook they look
  at, and the fix they fall back on when it isn't mechanical, a comment on
  the handbook's Index page saying what to change and where.

  A finding made this way is about the page it names and the Index (so the
  Tidy-up page can name both); its one step is a `comment` on the Index.
  """

  alias Slipdock.Handbook

  @doc "The handbook of the run's board, or nil: every hygiene check is off without one."
  def handbook(ctx), do: Handbook.find(ctx.board)

  @doc "Every page of `handbook` worth checking: its pages, then its decisions."
  def pages(handbook), do: handbook.pages ++ Handbook.decisions(handbook)

  @doc "The step that comments `text` on the Index of `handbook`."
  def comment(handbook, text),
    do: %{"op" => "comment", "page" => handbook.index.id, "body" => text}

  @doc """
  A finding about `pages` whose fix is a comment on the Index: the
  explanation, then `advice` on what to change.
  """
  def finding(handbook, pages, state, explanation, advice) do
    ids = pages |> Enum.map(& &1.id) |> Kernel.++([handbook.index.id]) |> Enum.uniq()

    %{
      subject: %{"pages" => ids},
      state: state,
      proposal: [comment(handbook, body(explanation, advice))],
      explanation: explanation
    }
  end

  @doc "A comment's text: what was found, then what to do."
  def body(explanation, advice),
    do: "**Handbook upkeep.** #{explanation}.\n\n#{advice}"

  @doc "How a page is named in a comment: its title, and its code when it has one."
  def name(page) do
    if page.code, do: "“#{page.title}” (#{page.code})", else: "“#{page.title}”"
  end
end
