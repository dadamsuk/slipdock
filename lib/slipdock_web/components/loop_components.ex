defmodule SlipdockWeb.LoopComponents do
  @moduledoc """
  The runner loop holding a card (#2027), drawn beside its assignees.

  A runner's agent signs in with its owner's token, so an assignment it made
  itself would name that person. The loop is worked out from the card's
  claimed or running job instead (`Slipdock.CardState.loop/1`) and is never
  an assignee: it goes when the job ends, and no assignee filter sees it.
  """
  use SlipdockWeb, :html

  alias Slipdock.CardState

  attr :loop, :map,
    default: nil,
    doc: "`Slipdock.CardState.loop/1` of the card; nil draws nothing"

  attr :href, :string,
    default: nil,
    doc: "where the chip leads: the job in the card's Runner jobs"

  attr :id, :string, default: nil
  attr :with_name, :boolean, default: true

  @doc """
  The loop as a chip: a CPU icon, the runner's name and the job's kind
  ("Mac Studio · verify"), linked to the job.
  """
  def loop_chip(%{loop: nil} = assigns), do: ~H""

  def loop_chip(assigns) do
    assigns = assign(assigns, :label, CardState.loop_label(assigns.loop))

    ~H"""
    <.link
      id={@id}
      href={@href}
      class="inline-flex min-w-0 max-w-full items-center gap-1 rounded-full bg-base-200 py-0.5 pr-1.5 pl-1 text-xs text-base-content/80 transition hover:bg-base-300"
      title={"Held by the runner loop #{@label} (job ##{@loop.job_id}): not an assignee"}
      data-loop-job={@loop.job_id}
    >
      <.icon name="hero-cpu-chip" class="size-3.5 shrink-0 text-info" />
      <span :if={@with_name} class="truncate">{@label}</span>
    </.link>
    """
  end

  @doc "The card page's address for a job in its Runner jobs."
  def job_href(card, %{job_id: job_id}),
    do: ~p"/boards/#{card.board_id}/cards/#{card.id}" <> "#card-job-#{job_id}"

  def job_href(_card, _loop), do: nil
end
