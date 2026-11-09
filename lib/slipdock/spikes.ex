defmodule Slipdock.Spikes do
  @moduledoc """
  Spikes in planning (#2348): when planning stops to answer a question by
  building, the questions become `spike` subcards of the epic
  (`Slipdock.Profiles.spike?/1`), and planning resumes once every one is
  answered.

  The resume wait (#2350): when a spike is accepted (`answered/2`, from
  `Slipdock.Verified.saved/3`) and no other spike on its sub-board is still
  open, the server opens one wait on the epic, routed `product`: "Spikes
  answered (#a, #b): resume planning", naming each spike and its answer
  page. A person answers it by resuming planning, and the plan skill reads
  the answers and writes the Spec. Nothing resumes by itself.

    * A spike is accepted when its `verify_state` becomes `accepted` or
      `merging`, or, on a board that doesn't verify work, when it is
      completed.
    * Open means neither completed nor archived: an archived spike counts
      as answered, and a spike submitted but not yet accepted is still
      open.
    * A spike's answer page is a page that references it, pinned first
      (`Slipdock.Wiki.Links.for_card/2`): the answer page pinned to the
      epic names its spike.
    * No second wait: the epic takes one open wait at a time
      (`Slipdock.Boards.open_wait/3` refuses another), so an epic already
      waiting gets none. A spike with no epic above it opens nothing.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.{Profiles, Repo}

  @purpose "spikes_answered"

  @doc "The resume wait's `purpose`."
  def purpose, do: @purpose

  @doc """
  After `before` has been saved as `updated`: when that accepted a spike,
  the resume wait on its epic if it was the last open one. Returns what
  `resume/1` does, or `:none`.
  """
  def answered(%Card{} = before, %Card{} = updated) do
    if accepted_now?(before, updated) and Profiles.spike?(updated),
      do: resume(updated),
      else: :none
  end

  defp accepted_now?(before, updated), do: accepted?(updated) and not accepted?(before)

  defp accepted?(%Card{verify_state: state}) when state in ["accepted", "merging"], do: true

  # On a board that doesn't verify work, completing is accepting.
  defp accepted?(%Card{verify_state: nil, completed: true} = card), do: not verifies?(card)
  defp accepted?(_card), do: false

  defp verifies?(%Card{board_id: id}), do: Repo.get!(Board, id).verify_work

  @doc """
  The resume wait for `spike`'s epic, when no spike under it is open:
  `{:ok, wait}`, `:none` (no epic, or a spike still open) or `{:error,
  why}` (the epic has a wait open already, say).
  """
  def resume(%Card{} = spike) do
    board = Repo.get!(Board, spike.board_id)

    with %Board{parent_card_id: epic_id} when not is_nil(epic_id) <- board,
         spikes = spikes_on(board),
         [] <- Enum.filter(spikes, &open?/1) do
      epic = Repo.get!(Card, epic_id)
      answered = Enum.reject(spikes, & &1.archived_at)

      Slipdock.Boards.open_wait(epic, Slipdock.Verified.server_actor(), %{
        needs: needs(answered),
        question: "product",
        purpose: @purpose
      })
    else
      _ -> :none
    end
  end

  defp spikes_on(%Board{id: id}) do
    from(c in Card, where: c.board_id == ^id, order_by: c.id, preload: :tags)
    |> Repo.all()
    |> Enum.filter(&Profiles.spike?/1)
  end

  defp open?(%Card{archived_at: nil, completed: false}), do: true
  defp open?(_card), do: false

  @doc """
  The resume wait's question: the spikes, each with its answer page (or
  that none references it), and what to do.
  """
  def needs(spikes) do
    ids = Enum.map_join(spikes, ", ", &"##{&1.id}")
    answers = Enum.map_join(spikes, "; ", &"##{&1.id} #{answer(&1)}")

    ("Spikes answered (#{ids}): resume planning. Answers: #{answers}. " <>
       "Planning resumes at Spec: the plan skill reads the answers and writes it.")
    |> String.slice(0, 990)
  end

  defp answer(spike) do
    case spike
         |> Slipdock.Wiki.Links.for_card()
         |> Enum.map(& &1.page)
         |> Enum.reject(&is_nil/1)
         |> Enum.uniq_by(& &1.id) do
      [] -> "(no answer page references it)"
      pages -> Enum.map_join(pages, ", ", &page_name/1)
    end
  end

  defp page_name(%{code: code, title: title}) when is_binary(code), do: "#{code} #{title}"
  defp page_name(%{title: title}), do: title
end
