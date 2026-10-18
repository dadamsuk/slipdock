defmodule SlipdockWeb.MCP.Resources.Render do
  @moduledoc "A resource `SlipdockWeb.MCP.Resources` has found, as Markdown."

  alias SlipdockWeb.MCP.Prompts.Context

  @doc "The Markdown for a resolved resource."
  def render({:board, board}, _context), do: "# #{Context.board_heading(board)}\n"
  def render({:card, card}, _context), do: "# #{Context.card_line(card)}\n"
  def render({:page, page}, _context), do: "# #{page.code} #{page.title}\n\n#{page.body}"
  def render({:view, board, view}, _context), do: "# #{view.name} (#{board.name})\n"
  def render(:work, _context), do: "# My work\n"
end
