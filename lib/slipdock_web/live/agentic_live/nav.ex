defmodule SlipdockWeb.AgenticLive.Nav do
  @moduledoc """
  The subnav the Agentic Building area shares (#2012): the board's name,
  then, on Findings, Ledger and Health while the board's switch is on, a
  link back to its Agentic Building page, so the four read as one area.
  With the switch off those pages still open by URL and show the board
  alone.
  """
  use SlipdockWeb, :html

  alias Slipdock.{AgenticBuilding, Palette}

  attr :board, :map, required: true
  attr :back, :boolean, default: true, doc: "link back to Agentic Building (off on its own page)"

  def subnav(assigns) do
    ~H"""
    <nav class="flex min-w-0 items-center gap-1 text-sm" aria-label="Where you are">
      <.link
        navigate={~p"/boards/#{@board}"}
        class="flex min-w-0 items-center gap-2 rounded-lg px-2 py-1 hover:bg-base-200"
      >
        <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
        <span class="truncate font-semibold">{@board.name}</span>
      </.link>
      <%= if @back and AgenticBuilding.on?(@board) do %>
        <.icon name="hero-chevron-right" class="size-3.5 shrink-0 text-base-content/60" />
        <.link
          navigate={~p"/boards/#{@board}/agentic"}
          id="agentic-back"
          class="flex shrink-0 items-center gap-1.5 rounded-lg px-2 py-1 text-base-content/80 hover:bg-base-200"
        >
          <.icon name="hero-wrench-screwdriver" class="size-4" />
          <span class="hidden sm:inline">Agentic Building</span>
          <span class="sr-only sm:hidden">Agentic Building</span>
        </.link>
      <% end %>
    </nav>
    """
  end
end
