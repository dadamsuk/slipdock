defmodule SlipdockWeb.BoardLive.CardComponent.HandoffEvents do
  @moduledoc """
  The card panel's events on where the card was left: writing the note,
  drafting it with the reader's model, clearing, restoring and deleting it.

  `BoardLive.CardComponent.handle_event/3` hands these over once it has
  decided the reader may do them. The clauses run in the component's own
  process, with its socket, as they did when they were its own.
  """
  use SlipdockWeb.WikiLive.Events

  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.Boards
  alias SlipdockWeb.Params
  alias SlipdockWeb.BoardLive.CardComponent.{Glance, State}

  # Where it was left (W-1804): anybody who may comment may write it.
  def handle_event("edit_handoff", _, socket) do
    current = Glance.current_handoff(socket.assigns.card)

    form =
      to_form(
        %{"next_step" => current && current.next_step, "body" => current && current.body},
        as: :handoff
      )

    {:noreply, assign(socket, editing_handoff: true, handoff_form: form, handoff_draft: nil)}
  end

  def handle_event("cancel_handoff", _, socket),
    do:
      {:noreply,
       socket
       |> cancel_async(:handoff_draft)
       |> assign(editing_handoff: false, handoff_form: nil, handoff_draft: nil)}

  # Auto generate (#1099): the person's model drafts the note from what has
  # happened on the card lately, into the form. Nothing is written until they
  # save it.
  def handle_event("draft_handoff", _, socket) do
    %{card: card, board: board, current_user: user} = socket.assigns

    cond do
      not socket.assigns.editing_handoff ->
        {:noreply, socket}

      not Slipdock.AI.configured?(user) ->
        {:noreply,
         assign(socket,
           handoff_draft:
             {:error, "Auto generate needs an AI model: set one under Account → AI model."}
         )}

      true ->
        {:noreply,
         socket
         |> assign(handoff_draft: :running)
         |> start_async(:handoff_draft, fn ->
           Slipdock.AI.HandoffDrafter.draft(card, board, user: user)
         end)}
    end
  end

  def handle_event("leave_handoff", %{"handoff" => params}, socket) do
    %{card: card, current_user: user} = socket.assigns
    attrs = %{next_step: params["next_step"], body: params["body"], via: "ui"}

    case Boards.Handoffs.leave_handoff(card, user, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(editing_handoff: false, handoff_form: nil, handoff_draft: nil)
         |> State.reload()
         |> State.assign_pages()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, handoff_form: to_form(changeset, as: :handoff, action: :insert))}
    end
  end

  def handle_event("clear_handoff", _, socket) do
    %{card: card, current_user: user} = socket.assigns
    {:ok, _} = Boards.Handoffs.clear_handoff(card, user, %{via: "ui"})

    {:noreply,
     socket
     |> assign(editing_handoff: false, handoff_form: nil)
     |> State.reload()
     |> State.assign_pages()}
  end

  # An earlier handoff made current again (#1214): written anew, as from the
  # UI, so the history says who brought it back and when.
  def handle_event("restore_handoff", %{"id" => id}, socket) do
    %{card: card, current_user: user} = socket.assigns

    with id when is_integer(id) <- Params.id(id),
         %{next_step: next, body: body} when next not in [nil, ""] <-
           Enum.find(Boards.Handoffs.handoff_history(card), &(&1.id == id)),
         {:ok, _} <-
           Boards.Handoffs.leave_handoff(card, user, %{next_step: next, body: body, via: "ui"}) do
      {:noreply,
       socket
       |> assign(editing_handoff: false, handoff_form: nil)
       |> State.reload()
       |> State.assign_pages()}
    else
      _ -> {:noreply, notice(socket, :error, "That one can't be restored.")}
    end
  end

  # Deleting the current handoff (#1214): its author, or anyone who can edit
  # the card. The one before it, if any, shows again.
  def handle_event("delete_handoff", _, socket) do
    %{card: card, current_user: user, can_write: can_write?} = socket.assigns

    case Boards.Handoffs.current_handoff(card) do
      nil ->
        {:noreply, State.reload(socket)}

      handoff ->
        if Boards.Handoffs.may_delete_handoff?(handoff, user, can_write?) do
          {:ok, _} = Boards.Handoffs.delete_handoff(card)

          {:noreply,
           socket
           |> assign(editing_handoff: false, handoff_form: nil)
           |> State.reload()
           |> State.assign_pages()}
        else
          {:noreply,
           notice(
             socket,
             :error,
             "Only its author or someone who can edit the card can delete it."
           )}
        end
    end
  end
end
