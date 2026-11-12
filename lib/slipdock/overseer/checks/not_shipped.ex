defmodule Slipdock.Overseer.Checks.NotShipped do
  @moduledoc """
  Merged, not shipped (#2819): a card on the tree merged longer ago than
  the board's `not_shipped_minutes` and no succeeded deploy names it
  (`Slipdock.Deployments.NotShipped`). One condition a card; it clears
  when a deploy covers the card.

  Unlike the other checks it runs **whether or not the overseer is on**
  (`Slipdock.Overseer.tick/1`): it costs no tokens, and a board that
  records its deploys has asked to know about them. What turns it on is
  the board's delivery metrics; `not_shipped_minutes` 0 turns it off.
  """
  @behaviour Slipdock.Overseer.Check

  alias Slipdock.Deployments.NotShipped
  alias Slipdock.Overseer.Check

  @impl true
  def key, do: "not_shipped"

  @impl true
  def label, do: "Merged, not shipped"

  @impl true
  def find(ctx) do
    for line <- NotShipped.in_tree(ctx.root, ctx.board_ids, ctx.now) do
      sha = NotShipped.short(line.sha)

      # No running duration here: the watch rewrites a condition whose
      # words change, and these would change every minute.
      %{
        subject: "card:#{line.card_id}",
        card_id: line.card_id,
        title: "#{Check.ref(%{id: line.card_id, title: line.title})} merged, not shipped",
        why:
          "Merged as #{sha} at #{Calendar.strftime(line.merged_at, "%-d %b %H:%M")} UTC, and " <>
            "#{Check.duration(line.minutes * 60)} later no succeeded deploy names it: " <>
            "the pipeline may have failed before its deploy job, or never run.",
        todo:
          "Look at the build for #{sha} and run the deploy again. This clears when a " <>
            "succeeded deploy names the card; archive the card if it will never ship."
      }
    end
  end
end
