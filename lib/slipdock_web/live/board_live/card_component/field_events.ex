defmodule SlipdockWeb.BoardLive.CardComponent.FieldEvents do
  @moduledoc """
  The card panel's events on the card's own fields: its title, dates, people,
  time, flags, tags, cover and borders, its description and attachments,
  who it is shared with, its runner jobs, and copying, archiving or
  deleting it.

  `BoardLive.CardComponent.handle_event/3` hands these over once it has
  decided the reader may do them. The clauses run in the component's own
  process, with its socket, as they did when they were its own.
  """
  use SlipdockWeb.WikiLive.Events

  import SlipdockWeb.BoardLive.Helpers
  import SlipdockWeb.BoardLive.Items

  alias Slipdock.{Access, Boards, Palette, Runners}
  alias SlipdockWeb.BoardLive.CardComponent.State
  alias SlipdockWeb.BoardLive.{Paths, Sharing}
  alias SlipdockWeb.Params

  @time_fields ~w(time_spent time_estimate time_unit)

  def handle_event("cancel_job", %{"job" => id}, socket) do
    with %{} = job <- Enum.find(socket.assigns.card_jobs, &(to_string(&1.id) == id)),
         {:ok, job} <- Runners.cancel_job(job) do
      message =
        if job.status == "cancelled",
          do: "Job ##{job.id} cancelled.",
          else: "Asked the runner to stop job ##{job.id}."

      {:noreply, socket |> State.assign_jobs() |> notice(:info, message)}
    else
      {:error, message} -> {:noreply, socket |> State.assign_jobs() |> notice(:error, message)}
      nil -> {:noreply, State.assign_jobs(socket)}
    end
  end

  def handle_event("share", %{"level" => _} = params, socket) do
    %{card: card, groups: groups, current_user: user} = socket.assigns

    case Sharing.share(card, params, groups, user) do
      {:ok, _} ->
        send(self(), :refresh_assignable)
        {:noreply, socket |> update(:share_key, &(&1 + 1)) |> State.assign_pages()}

      {:error, message} ->
        {:noreply, notice(socket, :error, message)}
    end
  end

  def handle_event("revoke_grant", %{"id" => id}, socket) do
    case Sharing.revoke(id, socket.assigns.card) do
      {:ok, _} ->
        send(self(), :refresh_assignable)
        {:noreply, State.assign_pages(socket)}

      _ ->
        {:noreply, notice(socket, :error, "Couldn't remove that access.")}
    end
  end

  def handle_event("card_change", %{"card" => params} = event, socket) do
    card = socket.assigns.card
    socket = drop_invalid_uploads(socket, :desc_image)

    case scope_assignees(changed_fields(params, event), card, socket.assigns.current_user) do
      {:ok, params} ->
        move_to_list(card, params, socket.assigns.current_user)
        card = Boards.Cards.get_card!(card.id)

        case Boards.Cards.update_card(card, Map.delete(params, "column_id"),
               by: socket.assigns.current_user
             ) do
          {:ok, card} ->
            {:noreply,
             socket
             |> assign(card: State.fresh(socket, card.id))
             |> keep_bar_open(params)}

          {:error, cs} ->
            {:noreply, socket |> assign(card_form: to_form(cs)) |> keep_bar_open(params)}
        end

      :error ->
        {:noreply, notice(socket, :error, "That person can't be put on this card.")}
    end
  end

  # The inferred profile, accepted from the panel's hint (#2018): a person
  # setting it, like choosing it in the select.
  def handle_event("accept_profile", %{"profile" => profile}, socket),
    do: handle_event("card_change", %{"card" => %{"profile" => profile}}, socket)

  def handle_event("card_timer", %{"action" => action}, socket) do
    with {:ok, card} <- State.writable(socket),
         {:ok, _} <-
           if(action == "stop",
             do: Boards.Cards.stop_timer(card),
             else: Boards.Cards.start_timer(card)
           ) do
      {:noreply, assign(socket, card: State.fresh(socket, card.id))}
    else
      _ -> {:noreply, notice(socket, :error, "You have read-only access to that card.")}
    end
  end

  def handle_event("log_time", %{"amount" => amount}, socket) do
    case State.writable(socket) do
      {:ok, card} -> log_time(socket, card, amount)
      _ -> {:noreply, notice(socket, :error, "You have read-only access to that card.")}
    end
  end

  def handle_event("remove_assignee", %{"id" => id}, socket) do
    {:ok, _} = Boards.Cards.update_card(socket.assigns.card, %{"remove_assignee_ids" => [id]})
    {:noreply, socket}
  end

  def handle_event("toggle_flag", %{"flag" => flag}, socket) do
    {:ok, _} = Boards.Cards.toggle_flag(socket.assigns.card, flag, State.by_me(socket))
    {:noreply, socket}
  end

  def handle_event("toggle_tag", %{"id" => id}, socket) do
    if tag = tag_by_id(socket.assigns.board, id),
      do: {:ok, _} = Boards.Tags.toggle_card_tag(socket.assigns.card, tag)

    {:noreply, socket}
  end

  # "New tag" from the card's tag picker (#1727): a tag of that name on the
  # board tree, put on the card. A name the board already has (in any case)
  # is that tag, put on the card if it isn't already, never a second one.
  # Making a new one changes the tree's tag list, which is the root's, so it
  # asks write on the root board, as the tag manager does (#2751, #2990); a
  # card writer, or a writer of a sub-board alone, still applies one it has.
  def handle_event("create_tag", %{"name" => name}, socket) do
    %{board: board, card: card, current_user: user} = socket.assigns
    name = String.trim(name)
    on_card? = fn tag -> Enum.any?(card.tags, &(&1.id == tag.id)) end

    cond do
      name == "" ->
        {:noreply, socket}

      tag = Enum.find(board.tags, &(String.downcase(&1.name) == String.downcase(name))) ->
        if not on_card?.(tag), do: {:ok, _} = Boards.Tags.toggle_card_tag(card, tag)
        {:noreply, socket}

      not Access.can_edit_tags?(user, board) ->
        {:noreply,
         notice(
           socket,
           :error,
           "Tag not made: only someone who can edit the top board makes a new tag. " <>
             "Pick one it has."
         )}

      true ->
        colours = Palette.names()
        colour = Enum.at(colours, rem(length(board.tags), length(colours)))

        case Boards.Tags.create_tag(board, %{"name" => name, "color" => colour}) do
          {:ok, tag} ->
            {:ok, _} = Boards.Tags.toggle_card_tag(card, tag)
            {:noreply, socket}

          {:error, changeset} ->
            {:noreply, notice(socket, :error, "Tag not made: #{field_errors(changeset)}.")}
        end
    end
  end

  def handle_event("set_cover", %{"color" => color}, socket) do
    {:ok, _} = Boards.Cards.update_card(socket.assigns.card, %{"color" => color})
    {:noreply, socket}
  end

  # An edge of the card's front, or all four, in a colour (#1209).
  def handle_event("set_border", %{"edge" => edge, "color" => color}, socket) do
    case border_fields(edge) do
      [] ->
        :ok

      fields ->
        {:ok, _} =
          Boards.Cards.update_card(
            socket.assigns.card,
            Map.new(fields, &{Atom.to_string(&1), color})
          )
    end

    {:noreply, socket}
  end

  # A copy as the card is now, straight after it, and opened (W-1802).
  def handle_event("duplicate_card", _, socket) when socket.assigns.can_add != true do
    {:noreply, notice(socket, :error, "Duplicating needs write access to the board.")}
  end

  def handle_event("duplicate_card", _, socket) do
    %{card: card, current_user: user} = socket.assigns

    case Boards.Cards.copy_card(card, nil, at: :after, by: user) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> notice(:info, "Duplicated as ##{copy.id}.")
         |> assign(notice_for: copy.id)
         |> push_patch(to: Paths.card_path(socket.assigns, copy.id))}

      {:error, refused} ->
        message = Slipdock.Quota.refusal_message(refused) || "Couldn't duplicate the card."
        {:noreply, notice(socket, :error, message)}
    end
  end

  def handle_event("archive_card", _, socket) do
    {:ok, _} = Boards.Cards.archive_card(socket.assigns.card, State.by_me(socket))
    {:noreply, push_patch(socket, to: socket.assigns.close_path)}
  end

  def handle_event("delete_card", _, socket) do
    {:ok, _} = Boards.Cards.delete_card(socket.assigns.card)
    {:noreply, push_patch(socket, to: socket.assigns.close_path)}
  end

  def handle_event("comment_change", _, socket),
    do: {:noreply, drop_invalid_uploads(socket, :comment_image)}

  def handle_event("edit_description", _, socket),
    do: {:noreply, assign(socket, editing_description: true)}

  def handle_event("reveal_sections", _, socket),
    do: {:noreply, assign(socket, reveal_sections: true)}

  def handle_event("stop_editing_description", _, socket),
    do: {:noreply, assign(socket, editing_description: false)}

  # The bar shows as Markdown (#3001); Edit swaps in its box, Done puts the
  # rendered view back.
  def handle_event("edit_bar", _, socket),
    do: {:noreply, assign(socket, editing_bar: true)}

  def handle_event("stop_editing_bar", _, socket),
    do: {:noreply, assign(socket, editing_bar: false)}

  def handle_event("validate_attachments", _, socket),
    do: {:noreply, drop_invalid_uploads(socket, :attachment)}

  def handle_event("cancel_upload", %{"name" => name, "ref" => ref}, socket)
      when name in ~w(attachment desc_image comment_image) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(name), ref)}
  end

  def handle_event("delete_attachment", %{"id" => id}, socket) do
    if attachment = card_attachment(socket, id) do
      {:ok, _} = Boards.Attachments.delete_attachment(attachment)
    end

    {:noreply, socket}
  end

  # `hide` is the state asked for, not a toggle: a double click, or a panel
  # drawn before someone else's change, cannot flip it back the wrong way.
  def handle_event("hide_on_card", %{"id" => id, "hide" => hide}, socket)
      when hide in ~w(true false) do
    if attachment = card_attachment(socket, id) do
      {:ok, _} = Boards.Attachments.hide_attachment_on_card(attachment, hide == "true")
    end

    {:noreply, socket}
  end

  def handle_event("transcribe", %{"id" => id}, socket) do
    if attachment = card_attachment(socket, id) do
      case Slipdock.Transcription.transcribe_attachment(attachment, socket.assigns.current_user) do
        {:ok, _} ->
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, notice(socket, :error, Slipdock.Transcription.describe(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("read_text", %{"id" => id}, socket) do
    with %{} = attachment <- card_attachment(socket, id),
         {:error, reason} <- Slipdock.OCR.retry(attachment) do
      {:noreply, notice(socket, :error, Slipdock.OCR.describe(reason))}
    else
      _ -> {:noreply, socket}
    end
  end

  # The card's own attachment, or nil: the id is the client's, and may name
  # another card's file or one deleted since the panel drew.
  defp card_attachment(socket, id),
    do: Boards.Attachments.get_card_attachment(socket.assigns.card.id, id)

  defp log_time(socket, card, amount) do
    case Boards.Cards.update_card(card, %{"log_time" => amount}, by: socket.assigns.current_user) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(card: State.fresh(socket, card.id))
         |> update(:form_key, &(&1 + 1))}

      {:error, _} ->
        {:noreply,
         notice(socket, :error, "Couldn't read “#{amount}” as a time — try 45m, 1.5h or 2d.")}
    end
  end

  # What a card form posted, as the change to make: only the fields it
  # carries, a blank date, percentage or assignee as none.
  defp changed_fields(params, event) do
    params
    |> Map.take(
      ~w(title description priority start_date due_date date_precision completed percent_complete column_id assignee_id add_assignee_id bar paths profile)
    )
    # The time form posts all three together, but spent and estimate are
    # typed in the unit on screen: re-sending them alongside a new unit would
    # read them in it. Only the field that changed goes through.
    |> Map.merge(Map.take(params, time_target(event)))
    |> Map.new(fn
      # Only the fields the changed form carries are touched: the title/description
      # form and the sidebar form both post here.
      {"start_date", ""} -> {"start_date", nil}
      {"due_date", ""} -> {"due_date", nil}
      {"percent_complete", ""} -> {"percent_complete", nil}
      {"assignee_id", ""} -> {"assignee_id", nil}
      # "Add someone" puts a person on the card beside whoever is there.
      {"add_assignee_id", id} -> {"add_assignee_ids", [id]}
      {"description", text} -> {"description", strip_upload_placeholder(text)}
      pair -> pair
    end)
  end

  # Another list chosen in the sidebar moves the card there; the list it is
  # already in, or none, moves nothing.
  defp move_to_list(card, params, user) do
    with %{"column_id" => col} when col != "" <- params,
         new_col when is_integer(new_col) and new_col != card.column_id <- Params.id(col) do
      Boards.Cards.move_card(card.id, new_col, nil, actor: Slipdock.Actor.web(user))
    end
  end

  defp time_target(%{"_target" => ["card", field]}) when field in @time_fields, do: [field]

  defp time_target(_), do: []

  defp border_fields("all"), do: Slipdock.Boards.Card.borders()

  defp border_fields(edge) when edge in ~w(top right bottom left),
    do: [String.to_existing_atom("border_" <> edge)]

  defp border_fields(_), do: []

  # A bar typed into its box keeps the box open (#3001): the first keys into
  # an empty bar would otherwise swap the box for the rendered view.
  defp keep_bar_open(socket, %{"bar" => _}), do: assign(socket, editing_bar: true)
  defp keep_bar_open(socket, _params), do: socket
end
