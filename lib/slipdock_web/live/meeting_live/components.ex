defmodule SlipdockWeb.MeetingLive.Components do
  @moduledoc """
  What the meeting pages share: the board's breadcrumb with Meetings (and the
  capture, when there is one) after it, and the strip with the view menu.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents, only: [view_tabs: 1]

  alias Slipdock.Palette

  attr :board, :any, required: true
  attr :capture, :any, default: nil

  @doc "The header's breadcrumb: the board, Meetings, and the capture if any."
  def meeting_nav(assigns) do
    ~H"""
    <nav class="flex min-w-0 items-center gap-1 text-sm">
      <.link
        navigate={~p"/boards/#{@board}"}
        class="flex min-w-0 items-center gap-2 rounded-lg px-2 py-1 hover:bg-base-200"
      >
        <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
        <span class="truncate font-semibold">{@board.name}</span>
      </.link>
      <.icon name="hero-chevron-right" class="size-3 shrink-0 text-base-content/40" />
      <.link
        navigate={~p"/boards/#{@board}/meetings"}
        class="rounded-lg px-2 py-1 font-semibold hover:bg-base-200"
      >
        Meetings
      </.link>
      <span :if={@capture} class="flex min-w-0 items-center gap-1">
        <.icon name="hero-chevron-right" class="size-3 shrink-0 text-base-content/40" />
        <span class="truncate px-2 py-1">{@capture.title}</span>
      </span>
    </nav>
    """
  end

  attr :board, :any, required: true
  attr :marks, :any, default: nil
  attr :meetings, :atom, default: :tab
  slot :inner_block

  @doc "The strip under the header: the view menu, then whatever the page adds."
  def meeting_toolbar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-2 gap-y-2 border-b border-base-300 bg-base-100/70 px-3 py-2 text-sm">
      <.view_tabs board={@board} mode={:meetings} view={nil} marks={@marks} meetings={@meetings} />
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "How a capture's state reads to a person (a capture, or a state)."
  def state_label(%{state: "committed", undone_at: %DateTime{}}), do: "undone"
  def state_label(%{state: state}), do: state_label(state)
  def state_label("receiving"), do: "receiving"
  def state_label("reading"), do: "reading"
  def state_label("needs_review"), do: "needs you"
  def state_label("ready"), do: "ready"
  def state_label("committed"), do: "committed"
  def state_label("discarded"), do: "discarded"
  def state_label("failed"), do: "failed"
  def state_label(other), do: other

  @doc "The badge colour for a state (a capture, or a state)."
  def state_class(%{state: "committed", undone_at: %DateTime{}}), do: "badge-ghost"
  def state_class(%{state: state}), do: state_class(state)
  def state_class("needs_review"), do: "badge-warning"
  def state_class("ready"), do: "badge-success"
  def state_class("committed"), do: "badge-primary"
  def state_class("failed"), do: "badge-error"
  def state_class(_), do: "badge-ghost"

  @doc "A millisecond offset as a clock: 7:38, or 1:02:05."
  def clock(nil), do: nil

  def clock(ms) do
    total = div(ms, 1000)
    {h, m, s} = {div(total, 3600), rem(div(total, 60), 60), rem(total, 60)}
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{m}:#{pad.(s)}"
  end
end
