defmodule SlipdockWeb.API.GardenJSON do
  @moduledoc """
  The gardener's runs, suggestions and settings as the API, the MCP tools
  and the CLI see them (W-1807).
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Gardener
  alias Slipdock.Gardener.{Run, Settings, Steps, Suggestion}
  alias Slipdock.Repo
  alias Slipdock.Wiki.Page

  @doc "A run: when, why and what it found."
  def run(nil), do: nil

  def run(%Run{} = r) do
    %{
      id: r.id,
      board_id: r.board_id,
      trigger: r.trigger,
      started_at: r.started_at,
      finished_at: r.finished_at,
      counts: r.counts
    }
  end

  @doc """
  Suggestions, their subjects named (one query for the cards, one for the
  pages). Each step on a page keeps its `page` id, which applying it
  reads, and gains the page's `page_code` (`W-1944`), which a reader
  needs (#2592).
  """
  def suggestions(list) when is_list(list) do
    card_ids = list |> Enum.flat_map(&Suggestion.card_ids/1) |> Enum.uniq()

    page_ids =
      list
      |> Enum.flat_map(&(Suggestion.page_ids(&1) ++ step_page_ids(&1)))
      |> Enum.uniq()

    cards =
      from(c in Card,
        where: c.id in ^card_ids,
        select: {c.id, %{id: c.id, title: c.title, board_id: c.board_id}}
      )
      |> Repo.all()
      |> Map.new()

    pages =
      from(p in Page,
        where: p.id in ^page_ids,
        select: {p.id, %{id: p.id, title: p.title, code: p.code, board_id: p.board_id}}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(list, &suggestion(&1, cards, pages))
  end

  @doc "One suggestion."
  def suggestion(%Suggestion{} = s), do: hd(suggestions([s]))

  defp suggestion(%Suggestion{} = s, cards, pages) do
    %{
      id: s.id,
      board_id: s.board_id,
      run_id: s.run_id,
      check: s.check,
      label: Gardener.label(s.check),
      state: s.state,
      explanation: s.explanation,
      cards: s |> Suggestion.card_ids() |> Enum.map(&(cards[&1] || %{id: &1, title: nil})),
      pages: s |> Suggestion.page_ids() |> Enum.map(&(pages[&1] || %{id: &1, title: nil})),
      proposal: coded(s.proposal, pages),
      findings: Map.get(s.subject, "findings", []),
      person_only: Gardener.person_only?(s),
      alternatives: Map.new(s.alternatives || %{}, fn {k, steps} -> {k, coded(steps, pages)} end),
      needs_keep: Steps.needs_pick?(s.proposal),
      decided_by_id: s.decided_by_id,
      decided_at: s.decided_at,
      created_at: s.inserted_at
    }
  end

  # The pages the proposal and its alternatives' steps are on.
  defp step_page_ids(%Suggestion{proposal: steps, alternatives: alts}) do
    [steps | Map.values(alts || %{})]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.flat_map(fn
      %{"page" => id} when is_integer(id) -> [id]
      _ -> []
    end)
  end

  defp coded(steps, pages) when is_list(steps), do: Enum.map(steps, &coded_step(&1, pages))
  defp coded(steps, _pages), do: steps

  defp coded_step(%{"page" => id} = step, pages) when is_integer(id) do
    case pages[id] do
      %{code: code} when is_binary(code) -> Map.put(step, "page_code", code)
      _ -> step
    end
  end

  defp coded_step(step, _pages), do: step

  @doc "Every check, with what it runs with on `board`."
  def checks(%Board{} = board) do
    for check <- Gardener.checks() do
      settings = Settings.for(board, check)

      %{
        key: check.key(),
        label: check.label(),
        enabled: settings["enabled"],
        settings: Map.delete(settings, "enabled"),
        defaults: check.defaults()
      }
    end
  end
end
