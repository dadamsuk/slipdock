defmodule SlipdockWeb.Ops.LeaveHandoff do
  @moduledoc """
  Where a card was left (W-1804), defined once (#3187): the one next step
  and a note for whoever picks the card up next, `clear: true` to clear it,
  or `delete: true` to delete the current one (#1214). REST has two routes
  for it, `POST /api/cards/:id/handoff` and `DELETE` on the same path: the
  second is this definition with `delete` settled true
  (`CardController.delete_handoff/2`).

  Before it, REST took `via` (`cli` from the command line) to record which
  way a handoff came in, and MCP recorded `mcp`: now every surface reads it
  from the caller's actor (the CLI says so in its `x-slipdock-client`
  header), and a `via` param is ignored.
  """
  @behaviour SlipdockWeb.Ops.Op

  import SlipdockWeb.Ops.Shared, only: [actor: 1]

  alias Slipdock.Boards.Handoffs
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.API.JSON, as: V

  @impl true
  def definition do
    %{
      name: "leave_handoff",
      title: "Leave a handoff on a card",
      summary:
        "Leaves the card's handoff for whoever picks it up next: write one whenever you " <>
          "stop unfinished. It replaces the last (kept as history); get_card shows it " <>
          "first. next_step: one line; body: the note. clear: true clears it; delete: " <>
          "true deletes it.",
      verb: :post,
      path: "/api/cards/:id/handoff",
      permission: {:card, :comment},
      writes?: true,
      # A handoff written is made (201); one deleted is not.
      status: &if(Map.has_key?(&1, :deleted), do: :ok, else: :created),
      params: [
        %{name: "card", type: :integer, required: true, in_path: "id"},
        %{
          name: "next_step",
          type: :string,
          doc: "The one next step. One line, at most 280."
        },
        %{
          name: "body",
          type: :string,
          doc:
            "Markdown, at most 8000. State: what is done and half-done. Gotchas: what bit you. " <>
              "Open: questions waiting on someone. Pointers: branch, files, commits, pages."
        },
        %{
          name: "clear",
          type: :boolean,
          default: false,
          doc: "Clear the handoff instead of writing one."
        },
        %{
          name: "delete",
          type: :boolean,
          default: false,
          doc:
            "Delete the current handoff instead of writing one: gone from the history too, and " <>
              "the one before it is current again. Its author or someone who can edit the card."
        }
      ],
      cli: %{
        command: "handoff",
        positional: ["card"],
        flags: %{
          "next" => %{param: "next_step"},
          "body" => %{param: "body"},
          "clear" => %{param: "clear", value: true},
          "delete" => %{param: "delete", value: true}
        }
      }
    }
  end

  @impl true
  def run(%{"card" => id, "delete" => true}, auth) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         {:ok, deleted} <- CardWrites.delete_handoff(auth, card) do
      current = Handoffs.current_handoff(card)
      {:ok, %{card: card.id, deleted: V.handoff(deleted), handoff: current && V.handoff(current)}}
    end
  end

  def run(%{"card" => id} = params, auth) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(auth, card, :comment),
         {:ok, handoff} <-
           CardWrites.write_handoff(card, auth.assigns.current_user, params, via(auth)) do
      {:ok, %{card: card.id, handoff: V.handoff(handoff)}}
    end
  end

  # The way it came in, as the handoff records it.
  defp via(auth) do
    case actor(auth).via do
      via when via in ["cli", "mcp"] -> via
      _ -> "api"
    end
  end
end
