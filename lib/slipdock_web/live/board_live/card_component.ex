defmodule SlipdockWeb.BoardLive.CardComponent do
  @moduledoc """
  The card panel: everything about one card — its fields, assignees, flags
  and tags, description, attachments, checklist, subcards, dependencies,
  docs, links, web links, comments, time, health, custom fields, votes,
  cover, and who it is shared with.

  The board opens it for the card in the URL and hands over the card as it
  loaded it. The component checks that card is on the board it was given,
  and works out for itself what the reader may do with it: read it at all,
  change it, share it. With view-only access to the board that is the saved
  view's say, for a card the view shows (`BoardLive.Items.card_access/5`).
  Anything named by id — a tag, a dependency, a link, an attachment, a page,
  a subcard — is checked against this card or this board before it is used.

  It owns the card's uploads (attachments, and images pasted into the
  description or a comment), so they go when it does.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.ItemComponents
  import SlipdockWeb.ShareComponents
  import SlipdockWeb.BoardLive.Helpers
  import SlipdockWeb.BoardLive.Items
  import SlipdockWeb.BoardLive.CardPanel
  import SlipdockWeb.BoardLive.CardSections

  alias Slipdock.{Access, Boards, Palette, Runners, Wiki}
  alias Slipdock.Boards.{Attachment, Board, Card, CardLink}
  alias SlipdockWeb.Params
  alias SlipdockWeb.BoardLive.{ItemEvents, Paths, Sharing}

  @own_events ~w(card_change toggle_flag toggle_tag set_cover duplicate_card archive_card delete_card
    add_dependency remove_dependency create_sub_board remove_assignee delete_sub_board
    quick_add_subcard toggle_subcard edit_description stop_editing_description
    validate_attachments cancel_upload delete_attachment hide_on_card transcribe add_link remove_link write_up
    toggle_pin_doc doc_search attach_doc detach_doc card_timer log_time dep_direction
    dep_search link_search pick_template comment_change share revoke_grant cancel_job
    edit_handoff cancel_handoff leave_handoff clear_handoff
    edit_repeat repeat_change save_repeat cancel_repeat skip_repeat pause_repeat stop_repeat)
  @events @own_events ++ ItemEvents.events()
  # What a reader who can't change the card may still do: nothing stored
  # changes, only what the panel is showing.
  @read_events ~w(stop_editing_description dep_direction dep_search link_search pick_template)
  # What a commenter (#863) may do besides: join the discussion, and nothing
  # that changes the card itself. Deleting a comment is only their own
  # (`ItemEvents`).
  @comment_events ~w(add_comment delete_comment add_status_update vote comment_change
    edit_handoff cancel_handoff leave_handoff clear_handoff)
  # Sharing has a rule of its own: the board's owner, or anybody who can edit
  # the card.
  @share_events ~w(share revoke_grant)

  @image_accept ~w(.png .jpg .jpeg .gif .webp image/png image/jpeg image/gif image/webp)
  @uploads [:attachment, :desc_image, :comment_image]
  @time_fields ~w(time_spent time_estimate time_unit)

  @doc false
  # For the test that every `handle_event/3` clause is in the list.
  def events, do: @events

  @impl true
  def mount(socket) do
    opts = [auto_upload: true, progress: &handle_upload/3]

    {:ok,
     socket
     |> assign(
       card: nil,
       given: nil,
       card_form: nil,
       form_key: 0,
       share_key: 0,
       card_pages: [],
       card_grants: [],
       card_jobs: [],
       card_provenance: [],
       doc_query: "",
       doc_results: [],
       dep_direction: "blocked_by",
       dep_query: "",
       dep_results: [],
       link_kind: "relates",
       link_query: "",
       link_results: [],
       picking_template: false,
       editing_description: false,
       handoff_history: [],
       editing_handoff: false,
       handoff_form: nil,
       repeat: nil
     )
     |> allow_upload(
       :attachment,
       [accept: :any, max_entries: 10, max_file_size: Attachment.max_size()] ++ opts
     )
     |> allow_upload(
       :desc_image,
       [accept: @image_accept, max_entries: 5, max_file_size: Attachment.image_max_size()] ++ opts
     )
     |> allow_upload(
       :comment_image,
       [accept: @image_accept, max_entries: 5, max_file_size: Attachment.image_max_size()] ++ opts
     )}
  end

  # A runner took, reported on or finished one of this card's jobs (see
  # `Slipdock.Runners`): only the jobs list changes.
  @impl true
  def update(%{jobs_changed: card_id}, socket) do
    case socket.assigns.card do
      %Card{id: ^card_id} -> {:ok, assign_jobs(socket)}
      _ -> {:ok, socket}
    end
  end

  def update(assigns, socket) do
    %{card: given, board: board, current_user: user} = assigns

    socket =
      assign(socket,
        board: board,
        current_user: user,
        swim: assigns.swim,
        swim_view: assigns.swim_view,
        mode: assigns.mode,
        swim_query: assigns.swim_query,
        users: assigns.users,
        mention_people: assigns.mention_people,
        close_path: assigns.close_path,
        tags_path: assigns.tags_path,
        templates: assigns.templates,
        groups: assigns.groups,
        favourites: assigns.favourites,
        ai?: assigns.ai?,
        at: assigns[:at],
        parent: assigns.parent,
        close_navigate: assigns.close_navigate
      )

    {:ok, if(given != socket.assigns.given, do: take(socket, given), else: socket)}
  end

  # The board loaded the card afresh (it opened, or something changed). A
  # different card starts the panel over; the same one keeps what is being
  # typed into its pickers.
  defp take(socket, given) do
    %{card: current, board: board, current_user: user, swim: config, swim_view: view} =
      socket.assigns

    same = match?(%Card{id: id} when id == given.id, current)
    perm = Access.board_permission(user, board)

    {readable, level} =
      if given.board_id == board.id,
        do: card_access(given, user, perm == :view, config, view),
        else: {false, :none}

    writable = Access.can_write?(level)

    socket =
      if same,
        do: socket,
        else:
          socket
          |> cancel_all_uploads()
          |> assign(
            dep_query: "",
            dep_results: [],
            link_query: "",
            link_results: [],
            doc_query: "",
            doc_results: [],
            picking_template: false,
            editing_description: false,
            editing_handoff: false,
            handoff_form: nil,
            repeat: nil
          )

    if readable do
      socket
      |> assign(
        given: given,
        card: Access.hide_unreadable_dependencies(user, given),
        card_form: to_form(Boards.change_card(given)),
        can_write: writable,
        can_comment: Access.can_comment?(level),
        can_share: perm == :owner or writable
      )
      |> assign_pages()
    else
      assign(socket,
        given: given,
        card: nil,
        card_form: nil,
        can_write: false,
        can_comment: false,
        can_share: false
      )
    end
  end

  # The wiki pages that talk about this card, pinned first (see
  # `Slipdock.Wiki.Links`), and who it is shared with.
  defp assign_pages(%{assigns: %{card: %Card{} = card}} = socket) do
    assign(socket,
      card_pages: Wiki.pages_for_card(card, socket.assigns.current_user),
      card_grants: if(socket.assigns.can_share, do: Access.list_grants(card), else: []),
      handoff_history: Boards.handoff_history(card)
    )
    |> assign_jobs()
  end

  defp assign_pages(socket), do: socket

  # The jobs rules have sent this card to runners, newest first.
  defp assign_jobs(%{assigns: %{card: %Card{} = card}} = socket),
    do:
      assign(socket,
        card_jobs: Runners.list_card_jobs(card.id, 5),
        # Where it came from, when that was a meeting. Shown whether or not
        # meeting mode is on now: it is the card's own history (G11).
        card_provenance: Slipdock.Meetings.Provenance.for_card(card.id)
      )

  defp assign_jobs(socket), do: socket

  # An in-flight upload belongs to the card that was open when it started.
  defp cancel_all_uploads(socket) do
    Enum.reduce(@uploads, socket, fn name, socket ->
      Enum.reduce(socket.assigns.uploads[name].entries, socket, &cancel_upload(&2, name, &1.ref))
    end)
  end

  # The open card, fresh, when the reader may change it.
  defp writable(%{assigns: %{can_write: true, card: %Card{id: id}}}),
    do: {:ok, Boards.get_card!(id)}

  defp writable(_socket), do: :error

  # Called as each chunk lands; stores the file once the whole upload is in.
  defp handle_upload(name, entry, socket) do
    card = socket.assigns.card

    cond do
      not entry.done? ->
        {:noreply, socket}

      is_nil(card) or not socket.assigns.can_write ->
        {:noreply, cancel_upload(socket, name, entry.ref)}

      true ->
        meta = %{
          filename: entry.client_name,
          content_type: entry.client_type,
          size: entry.client_size
        }

        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok, Boards.add_attachment(card, meta, path)}
          end)

        {:noreply, uploaded(socket, name, result)}
    end
  end

  ## Events ------------------------------------------------------------------

  @impl true
  def handle_event(event, _params, socket) when event not in @events,
    do: {:noreply, flash(socket, :error, "That isn't something this page can do.")}

  def handle_event(_event, _params, %{assigns: %{card: nil}} = socket), do: {:noreply, socket}

  def handle_event(event, _params, %{assigns: %{can_share: false}} = socket)
      when event in @share_events,
      do: {:noreply, flash(socket, :error, "You can't share that.")}

  def handle_event(event, params, %{assigns: %{can_comment: true}} = socket)
      when event in @comment_events,
      do: dispatch(event, params, socket)

  def handle_event(event, _params, %{assigns: %{can_write: false}} = socket)
      when event not in @read_events and event not in @share_events,
      do: {:noreply, flash(socket, :error, read_only_message(socket))}

  def handle_event(event, params, socket), do: dispatch(event, params, socket)

  defp dispatch(event, params, socket) do
    if event in @own_events,
      do: event(event, params, socket),
      else: ItemEvents.handle(event, params, with_item(socket), &reload/1)
  end

  defp read_only_message(%{assigns: %{can_comment: true}}),
    do: "You can comment on this card, but not change it."

  defp read_only_message(_socket), do: "You have read-only access to this card."

  # Put a fresh copy of the card in front of the reader.
  defp reload(socket), do: assign(socket, card: fresh(socket, socket.assigns.card.id))

  # The card as this reader may see it: dependencies on boards they can't
  # read are hidden (see `Access.hide_unreadable_dependencies/3`).
  defp fresh(socket, id),
    do: Access.hide_unreadable_dependencies(socket.assigns.current_user, Boards.get_card!(id))

  # The item the shared sections (`BoardLive.ItemEvents`) act on is the card.
  defp with_item(socket), do: assign(socket, item: socket.assigns.card)

  defp event("cancel_job", %{"job" => id}, socket) do
    with %{} = job <- Enum.find(socket.assigns.card_jobs, &(to_string(&1.id) == id)),
         {:ok, job} <- Runners.cancel_job(job) do
      message =
        if job.status == "cancelled",
          do: "Job ##{job.id} cancelled.",
          else: "Asked the runner to stop job ##{job.id}."

      {:noreply, socket |> assign_jobs() |> flash(:info, message)}
    else
      {:error, message} -> {:noreply, socket |> assign_jobs() |> flash(:error, message)}
      nil -> {:noreply, assign_jobs(socket)}
    end
  end

  defp event("share", %{"level" => _} = params, socket) do
    %{card: card, groups: groups, current_user: user} = socket.assigns

    case Sharing.share(card, params, groups, user) do
      {:ok, _} ->
        send(self(), :refresh_assignable)
        {:noreply, socket |> update(:share_key, &(&1 + 1)) |> assign_pages()}

      {:error, message} ->
        {:noreply, flash(socket, :error, message)}
    end
  end

  defp event("revoke_grant", %{"id" => id}, socket) do
    case Sharing.revoke(id, socket.assigns.card) do
      {:ok, _} ->
        send(self(), :refresh_assignable)
        {:noreply, assign_pages(socket)}

      _ ->
        {:noreply, flash(socket, :error, "Couldn't remove that access.")}
    end
  end

  defp event("card_change", %{"card" => params} = event, socket) do
    card = socket.assigns.card
    socket = drop_invalid_uploads(socket, :desc_image)

    params =
      params
      |> Map.take(
        ~w(title description priority start_date due_date date_precision completed percent_complete column_id assignee_id add_assignee_id)
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

    with {:ok, params} <- scope_assignees(params, card, socket.assigns.current_user) do
      with %{"column_id" => col} when col != "" <- params,
           new_col when is_integer(new_col) and new_col != card.column_id <- Params.id(col) do
        Boards.move_card(card.id, new_col, nil)
      end

      card = Boards.get_card!(card.id)

      case Boards.update_card(card, Map.delete(params, "column_id"),
             by: socket.assigns.current_user
           ) do
        {:ok, card} ->
          {:noreply, assign(socket, card: fresh(socket, card.id))}

        {:error, cs} ->
          {:noreply, assign(socket, card_form: to_form(cs))}
      end
    else
      :error -> {:noreply, flash(socket, :error, "That person can't be put on this card.")}
    end
  end

  defp event("card_timer", %{"action" => action}, socket) do
    with {:ok, card} <- writable(socket),
         {:ok, _} <-
           if(action == "stop", do: Boards.stop_timer(card), else: Boards.start_timer(card)) do
      {:noreply, assign(socket, card: fresh(socket, card.id))}
    else
      _ -> {:noreply, flash(socket, :error, "You have read-only access to that card.")}
    end
  end

  defp event("log_time", %{"amount" => amount}, socket) do
    with {:ok, card} <- writable(socket) do
      case Boards.update_card(card, %{"log_time" => amount}, by: socket.assigns.current_user) do
        {:ok, card} ->
          {:noreply,
           socket
           |> assign(card: fresh(socket, card.id))
           |> update(:form_key, &(&1 + 1))}

        {:error, _} ->
          {:noreply,
           flash(socket, :error, "Couldn't read “#{amount}” as a time — try 45m, 1.5h or 2d.")}
      end
    else
      _ -> {:noreply, flash(socket, :error, "You have read-only access to that card.")}
    end
  end

  # "Write it up": a page for this card, pinned to it, from a template when
  # the board has one. It opens in the editor rather than being left to find.
  defp event("write_up", _params, socket) do
    card = socket.assigns.card

    case Wiki.create_page_from_card(card, user: socket.assigns.current_user, via: "web") do
      {:ok, page} ->
        {:noreply,
         socket
         |> put_flash(:info, "Started #{page.code} for “#{card.title}”.")
         |> push_navigate(to: ~p"/boards/#{page.board_id}/wiki/#{page.slug}/edit")}

      _ ->
        {:noreply, flash(socket, :error, "That page couldn't be started.")}
    end
  end

  # Attaching a page that already exists. "Write it up" is for the document
  # that does not exist yet; most of the time the writing is already there
  # and what is missing is the link to it.
  defp event("doc_search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(doc_query: q) |> assign_doc_results()}
  end

  defp event("attach_doc", %{"page" => page_id}, socket) do
    card = socket.assigns.card

    with {:ok, page} <- readable_page(socket, page_id),
         {:ok, _} <- Wiki.pin(page, {:card, card}) do
      {:noreply,
       socket
       |> flash(:info, "Attached #{page.code} to this card.")
       |> assign(doc_query: "", doc_results: [])
       |> assign_pages()}
    else
      _ -> {:noreply, flash(socket, :error, "That page couldn't be attached.")}
    end
  end

  defp event("detach_doc", %{"page" => page_id}, socket) do
    card = socket.assigns.card

    with {:ok, page} <- Wiki.find_page(page_id),
         {:ok, _} <- Wiki.unlink(page, {:card, card}) do
      {:noreply, assign_pages(socket)}
    else
      _ -> {:noreply, flash(socket, :error, "That page couldn't be detached.")}
    end
  end

  defp event("toggle_pin_doc", %{"page" => page_id}, socket) do
    card = socket.assigns.card

    with {:ok, page} <- readable_page(socket, page_id),
         link <- Enum.find(socket.assigns.card_pages, &(&1.page.id == page.id)),
         {:ok, _} <- Wiki.pin(page, {:card, card}, not (link && link.pinned)) do
      {:noreply, assign_pages(socket)}
    else
      _ -> {:noreply, flash(socket, :error, "That page couldn't be pinned.")}
    end
  end

  defp event("remove_assignee", %{"id" => id}, socket) do
    {:ok, _} = Boards.update_card(socket.assigns.card, %{"remove_assignee_ids" => [id]})
    {:noreply, socket}
  end

  defp event("toggle_flag", %{"flag" => flag}, socket) do
    {:ok, _} = Boards.toggle_flag(socket.assigns.card, flag)
    {:noreply, socket}
  end

  defp event("toggle_tag", %{"id" => id}, socket) do
    if tag = board_tag(socket, id),
      do: {:ok, _} = Boards.toggle_card_tag(socket.assigns.card, tag)

    {:noreply, socket}
  end

  defp event("set_cover", %{"color" => color}, socket) do
    {:ok, _} = Boards.update_card(socket.assigns.card, %{"color" => color})
    {:noreply, socket}
  end

  # A copy as the card is now, straight after it, and opened (W-1802).
  defp event("duplicate_card", _, socket) do
    %{card: card, current_user: user} = socket.assigns

    case Boards.copy_card(card, nil, at: :after, by: user) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> flash(:info, "Duplicated as ##{copy.id}.")
         |> push_patch(to: Paths.card_path(socket.assigns, copy.id))}

      {:error, refused} ->
        message = Slipdock.Quota.refusal_message(refused) || "Couldn't duplicate the card."
        {:noreply, flash(socket, :error, message)}
    end
  end

  defp event("archive_card", _, socket) do
    {:ok, _} = Boards.archive_card(socket.assigns.card)
    {:noreply, push_patch(socket, to: socket.assigns.close_path)}
  end

  defp event("delete_card", _, socket) do
    {:ok, _} = Boards.delete_card(socket.assigns.card)
    {:noreply, push_patch(socket, to: socket.assigns.close_path)}
  end

  defp event("comment_change", _, socket),
    do: {:noreply, drop_invalid_uploads(socket, :comment_image)}

  # Where it was left (W-1804): anybody who may comment may write it.
  defp event("edit_handoff", _, socket) do
    current = current_handoff(socket.assigns.card)

    form =
      to_form(
        %{"next_step" => current && current.next_step, "body" => current && current.body},
        as: :handoff
      )

    {:noreply, assign(socket, editing_handoff: true, handoff_form: form)}
  end

  defp event("cancel_handoff", _, socket),
    do: {:noreply, assign(socket, editing_handoff: false, handoff_form: nil)}

  defp event("leave_handoff", %{"handoff" => params}, socket) do
    %{card: card, current_user: user} = socket.assigns
    attrs = %{next_step: params["next_step"], body: params["body"], via: "ui"}

    case Boards.leave_handoff(card, user, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(editing_handoff: false, handoff_form: nil)
         |> reload()
         |> assign_pages()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, handoff_form: to_form(changeset, as: :handoff, action: :insert))}
    end
  end

  # Repeat… (W-1802): a series on the card, set from presets or a rule of
  # one's own, with what it would do shown before it is saved.
  defp event("edit_repeat", _, socket) do
    %{card: card, current_user: user} = socket.assigns
    series = card.recurrence
    zone = (series && series.timezone) || Slipdock.Timezones.of(user)
    ref = card.due_date || Slipdock.Timezones.today(zone)
    presets = Slipdock.Recurrence.presets(ref)
    preset_rules = Enum.map(presets, &elem(&1, 0))

    params =
      case series do
        nil ->
          %{"preset" => elem(Enum.at(presets, 2), 0), "custom" => "", "at" => "07:00"}

        s ->
          %{
            "preset" => if(s.rule in preset_rules, do: s.rule, else: "custom"),
            "custom" => if(s.rule in preset_rules, do: "", else: s.rule),
            "at" => Calendar.strftime(s.create_at, "%H:%M"),
            "lead_days" => to_string(s.lead_days),
            "on_missed" => s.on_missed,
            "ends" => s.ends,
            "ends_on" => s.ends_on && Date.to_iso8601(s.ends_on),
            "count" => s.count && to_string(s.count)
          }
      end

    {:noreply, assign(socket, repeat: repeat_state(params, presets, zone, ref))}
  end

  defp event("repeat_change", %{"repeat" => params}, %{assigns: %{repeat: %{} = r}} = socket),
    do: {:noreply, assign(socket, repeat: repeat_state(params, r.presets, r.zone, r.ref))}

  defp event("repeat_change", _, socket), do: {:noreply, socket}

  defp event("cancel_repeat", _, socket), do: {:noreply, assign(socket, repeat: nil)}

  defp event("save_repeat", %{"repeat" => params}, %{assigns: %{repeat: %{} = r}} = socket) do
    %{card: card, current_user: user} = socket.assigns

    case Slipdock.Recurrence.set(card, repeat_attrs(params, r.zone), user) do
      {:ok, _} ->
        {:noreply, socket |> assign(repeat: nil) |> reload()}

      {:error, message} ->
        state = repeat_state(params, r.presets, r.zone, r.ref)
        {:noreply, assign(socket, repeat: %{state | error: repeat_error(message)})}
    end
  end

  defp event("save_repeat", _, socket), do: {:noreply, socket}

  defp event("skip_repeat", _, socket) do
    case Slipdock.Recurrence.skip(socket.assigns.card) do
      {:ok, _} -> {:noreply, reload(socket)}
      {:error, message} when is_binary(message) -> {:noreply, flash(socket, :error, message)}
      _ -> {:noreply, socket}
    end
  end

  defp event("pause_repeat", _, socket) do
    %{card: card, current_user: user} = socket.assigns

    if series = card.recurrence,
      do: Slipdock.Recurrence.set(card, %{"paused" => not series.paused}, user)

    {:noreply, reload(socket)}
  end

  defp event("stop_repeat", _, socket) do
    Slipdock.Recurrence.stop(socket.assigns.card)
    {:noreply, socket |> assign(repeat: nil) |> reload()}
  end

  defp event("clear_handoff", _, socket) do
    %{card: card, current_user: user} = socket.assigns
    {:ok, _} = Boards.clear_handoff(card, user, %{via: "ui"})

    {:noreply,
     socket |> assign(editing_handoff: false, handoff_form: nil) |> reload() |> assign_pages()}
  end

  defp event("edit_description", _, socket),
    do: {:noreply, assign(socket, editing_description: true)}

  defp event("stop_editing_description", _, socket),
    do: {:noreply, assign(socket, editing_description: false)}

  defp event("validate_attachments", _, socket),
    do: {:noreply, drop_invalid_uploads(socket, :attachment)}

  defp event("cancel_upload", %{"name" => name, "ref" => ref}, socket)
       when name in ~w(attachment desc_image comment_image) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(name), ref)}
  end

  defp event("delete_attachment", %{"id" => id}, socket) do
    attachment = Boards.get_attachment!(id)

    if attachment.card_id == socket.assigns.card.id do
      {:ok, _} = Boards.delete_attachment(attachment)
    end

    {:noreply, socket}
  end

  # `hide` is the state asked for, not a toggle: a double click, or a panel
  # drawn before someone else's change, cannot flip it back the wrong way.
  defp event("hide_on_card", %{"id" => id, "hide" => hide}, socket) when hide in ~w(true false) do
    attachment = Boards.get_attachment!(id)

    if attachment.card_id == socket.assigns.card.id do
      {:ok, _} = Boards.hide_attachment_on_card(attachment, hide == "true")
    end

    {:noreply, socket}
  end

  defp event("transcribe", %{"id" => id}, socket) do
    attachment = Boards.get_attachment!(id)

    if attachment.card_id == socket.assigns.card.id do
      case Slipdock.Transcription.transcribe_attachment(attachment) do
        {:ok, _} ->
          {:noreply, socket}

        {:error, reason} ->
          send(self(), {:put_flash, :error, Slipdock.Transcription.describe(reason)})
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp event("dep_direction", %{"direction" => dir}, socket)
       when dir in ~w(blocked_by blocks) do
    {:noreply, socket |> assign(dep_direction: dir) |> assign_dep_results()}
  end

  defp event("dep_search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(dep_query: q) |> assign_dep_results()}
  end

  # The other card may be on another board: the blocked card needs write
  # access, the blocker read.
  defp event("add_dependency", %{"id" => id}, socket) do
    %{card: card, dep_direction: direction, current_user: user} = socket.assigns
    other = Boards.get_card!(id)

    {blocked, blocker} =
      case direction do
        "blocked_by" -> {card, other}
        "blocks" -> {other, card}
      end

    result =
      cond do
        not Access.can_write?(Access.card_permission(user, blocked)) ->
          {:error, "You can't change “#{blocked.title}”, so it can't be made to wait."}

        not Access.can_read?(Access.card_permission(user, blocker)) ->
          {:error, "You can't see that card."}

        true ->
          Boards.add_dependency(blocked, blocker)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket |> assign(dep_query: "", dep_results: []) |> update(:form_key, &(&1 + 1))}

      {:error, message} ->
        {:noreply, flash(socket, :error, message)}
    end
  end

  defp event("link_search", params, socket) do
    kind =
      if params["kind"] in CardLink.kind_keys(),
        do: params["kind"],
        else: socket.assigns.link_kind

    {:noreply,
     socket |> assign(link_kind: kind, link_query: params["q"] || "") |> assign_link_results()}
  end

  defp event("add_link", %{"id" => id}, socket) do
    %{card: card, link_kind: kind, current_user: user} = socket.assigns
    other = Boards.get_card!(id)

    with true <-
           Access.can_read?(Access.card_permission(user, other)) ||
             {:error, "You can't see that card."},
         {:ok, _} <- Boards.add_link(card, other, kind) do
      {:noreply,
       socket
       |> assign(link_query: "", link_results: [], card: fresh(socket, card.id))
       |> update(:form_key, &(&1 + 1))}
    else
      {:error, message} -> {:noreply, flash(socket, :error, message)}
    end
  end

  defp event("remove_link", %{"id" => id}, socket) do
    card = socket.assigns.card
    link = Boards.get_link!(id)

    if link.from_id == card.id or link.to_id == card.id do
      {:ok, _} = Boards.remove_link(link)
      {:noreply, assign(socket, card: fresh(socket, card.id))}
    else
      {:noreply, socket}
    end
  end

  defp event("remove_dependency", %{"id" => id}, socket) do
    {:ok, _} = Boards.remove_dependency(socket.assigns.card, Boards.get_card!(id))
    {:noreply, socket}
  end

  defp event("pick_template", _, socket) do
    {:noreply, update(socket, :picking_template, &(!&1))}
  end

  # Only a template the reader can see: the built-ins and their own.
  defp event("create_sub_board", %{"template" => id}, socket) do
    with {:ok, template} <- Boards.find_template(socket.assigns.current_user, id),
         {:ok, _} <- Boards.create_sub_board(socket.assigns.card, template) do
      {:noreply, assign(socket, picking_template: false)}
    else
      {:error, :not_found} -> {:noreply, flash(socket, :error, "That template has gone.")}
      {:error, message} -> {:noreply, flash(socket, :error, message)}
    end
  end

  defp event("delete_sub_board", _, socket) do
    case Boards.delete_sub_board(socket.assigns.card) do
      {:ok, _} -> {:noreply, socket}
      {:error, message} -> {:noreply, flash(socket, :error, message)}
    end
  end

  # Only into a list on the open card's own subcards board.
  defp event("quick_add_subcard", %{"column_id" => column_id, "title" => title}, socket) do
    column =
      case socket.assigns.card do
        %Card{sub_board: %Board{id: sub_id}} ->
          Boards.get_board_column(sub_id, column_id)

        _ ->
          nil
      end

    if column && String.trim(title) != "" do
      {:ok, _} = Boards.create_card(column, %{"title" => String.trim(title)})
    end

    {:noreply, update(socket, :form_key, &(&1 + 1))}
  end

  defp event("toggle_subcard", %{"id" => id}, socket) do
    card = Boards.get_card!(id)

    if socket.assigns.card && card.board_id == socket.assigns.card.sub_board.id do
      Boards.toggle_completed(card)
    end

    {:noreply, socket}
  end

  # A tag of this board's tree (they live on the root), or nil.
  defp board_tag(socket, id),
    do: Enum.find(socket.assigns.board.tags, &(to_string(&1.id) == to_string(id)))

  ## Render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-card">
      <.card_modal
        :if={@card}
        card={@card}
        at={@at}
        ai?={@ai?}
        current_user={@current_user}
        users={@users}
        form={@card_form}
        board={@board}
        mention_people={@mention_people}
        form_key={@form_key}
        close_path={@close_path}
        tags_path={@tags_path}
        card_link={&Paths.card_path(%{mode: @mode, board: @board, swim_query: @swim_query}, &1)}
        dep_direction={@dep_direction}
        dep_query={@dep_query}
        dep_results={@dep_results}
        link_kind={@link_kind}
        link_query={@link_query}
        link_results={@link_results}
        templates={@templates}
        picking_template={@picking_template}
        close_navigate={@close_navigate}
        can_write={@can_write}
        can_comment={@can_comment}
        can_share={@can_share}
        grants={@card_grants}
        pages={@card_pages}
        jobs={@card_jobs}
        provenance={@card_provenance}
        doc_query={@doc_query}
        doc_results={@doc_results}
        groups={@groups}
        share_key={@share_key}
        uploads={@uploads}
        editing_description={@editing_description}
        handoff_history={@handoff_history}
        editing_handoff={@editing_handoff}
        handoff_form={@handoff_form}
        repeat={@repeat}
        parent={@parent}
        favourites={@favourites}
        target={@myself}
      />
    </div>
    """
  end

  defp uploaded(socket, :attachment, {:ok, _}), do: socket

  defp uploaded(socket, name, {:ok, attachment}) do
    push_event(socket, "image_uploaded", %{
      upload: Atom.to_string(name),
      markdown: "![#{attachment.filename}](#{Boards.attachment_url(attachment)})"
    })
  end

  defp uploaded(socket, name, {:error, changeset}) do
    {field, {msg, _}} = List.first(changeset.errors) || {:file, {"could not be stored", []}}

    socket
    |> flash(:error, "Upload failed: #{field} #{msg}.")
    |> image_failed(name)
  end

  # Pages on this board's tree that are not already on the card. Titles and
  # summaries only: finding the page you mean is a different job from
  # searching its prose, which `/search` does by meaning.
  defp assign_doc_results(socket) do
    query = String.trim(socket.assigns.doc_query || "")
    attached = MapSet.new(socket.assigns.card_pages, & &1.page.id)

    results =
      if query == "" do
        []
      else
        socket.assigns.board
        |> Wiki.list_pages(q: query, template: false, archived: false)
        |> Enum.reject(&MapSet.member?(attached, &1.id))
        |> Enum.take(8)
      end

    assign(socket, doc_results: results)
  end

  defp time_target(%{"_target" => ["card", field]}) when field in @time_fields, do: [field]

  defp time_target(_), do: []

  # A wiki page the user may read, to attach to the open card.
  defp readable_page(socket, id) do
    with {:ok, page} <- Wiki.find_page(id),
         true <- Access.can_read?(Access.page_permission(socket.assigns.current_user, page)) do
      {:ok, page}
    else
      _ -> :error
    end
  end

  # Cards on any board the user can open — this one, the epic's parent board,
  # sibling sub-boards, other boards — minus this card and those already
  # linked. This board's own cards come first.
  defp assign_dep_results(%{assigns: %{card: %Card{} = card, dep_query: q}} = socket)
       when q != "" do
    linked = Enum.map(card.blocked_by ++ card.blocks, & &1.id)

    results =
      socket
      |> searchable_root_ids()
      |> Boards.search_cards_across(q, [card.id | linked])
      |> Enum.sort_by(&(&1.board_id != card.board_id))

    assign(socket, dep_results: results)
  end

  defp assign_dep_results(socket), do: assign(socket, dep_results: [])

  # Cards on any board the user can open, minus this card and those already linked.
  defp assign_link_results(%{assigns: %{card: %Card{} = card, link_query: q}} = socket)
       when q != "" do
    linked = Enum.map(card.links_out, & &1.to_id) ++ Enum.map(card.links_in, & &1.from_id)

    assign(socket,
      link_results: Boards.search_cards_across(searchable_root_ids(socket), q, [card.id | linked])
    )
  end

  defp assign_link_results(socket), do: assign(socket, link_results: [])

  defp searchable_root_ids(socket) do
    %{current_user: user, board: board} = socket.assigns

    Enum.uniq([
      Slipdock.Boards.Board.root_id(board)
      | Enum.map(Access.list_boards(user, archived: :all), & &1.id)
    ])
  end

  attr :card, Card, required: true
  attr :users, :list, required: true
  attr :form, :any, required: true
  attr :board, :any, required: true
  attr :form_key, :integer, required: true
  attr :close_path, :string, required: true
  attr :tags_path, :string, required: true
  attr :card_link, :any, required: true, doc: "fn card_id -> path"
  attr :target, :any, required: true
  attr :link_kind, :string, default: "relates"
  attr :link_query, :string, default: ""
  attr :link_results, :list, default: []
  attr :dep_direction, :string, required: true
  attr :dep_query, :string, required: true
  attr :dep_results, :list, required: true
  attr :templates, :list, required: true
  attr :picking_template, :boolean, required: true
  attr :mention_people, :string, default: nil
  attr :can_write, :boolean, required: true
  attr :can_comment, :boolean, default: false, doc: "may join the discussion (#863)"
  attr :can_share, :boolean, required: true
  attr :grants, :list, required: true
  attr :pages, :list, default: [], doc: "the wiki pages that talk about this card"
  attr :jobs, :list, default: [], doc: "the card's latest runner jobs"
  attr :provenance, :list, default: [], doc: "where it came from, when a meeting"
  attr :doc_query, :string, default: "", doc: "what is typed into the Docs picker"
  attr :doc_results, :list, default: [], doc: "pages the Docs picker is offering"
  attr :groups, :list, required: true
  attr :share_key, :integer, required: true
  attr :uploads, :map, required: true
  attr :editing_description, :boolean, required: true
  attr :handoff_history, :list, default: [], doc: "every handoff written, newest first"
  attr :editing_handoff, :boolean, default: false
  attr :handoff_form, :any, default: nil
  attr :repeat, :map, default: nil, doc: "the Repeat… form while it is open (W-1802)"
  attr :close_navigate, :boolean, default: false
  attr :parent, :any, default: nil
  attr :ai?, :boolean, default: false, doc: "offer the AI assistant on the card"
  attr :at, :string, default: nil, doc: "where in the card a search result points"

  attr :current_user, :any, default: nil

  attr :favourites, :any,
    default: nil,
    doc: "the reader's favourites (`Slipdock.Favourites.marks/1`)"

  defp card_modal(assigns) do
    {done, total, pct} = checklist_progress(assigns.card.checklist_items)
    assigns = assign(assigns, done: done, total: total, pct: pct)

    ~H"""
    <.modal
      id="card-modal"
      on_close={if @close_navigate, do: JS.navigate(@close_path), else: JS.patch(@close_path)}
      size="wide"
      keys
    >
      <%!-- Outside the fieldsets below, which are disabled for a read-only
            card: a favourite is the reader's own, not a change to the card.
            The heart's weight is in its top half, so in the same box as the
            close x it reads high: a pixel down lines the two up by eye. --%>
      <:actions>
        <.favourite_toggle
          kind="card"
          id={@card.id}
          name={@card.title}
          marks={@favourites}
          class="btn btn-ghost btn-sm btn-circle"
          size="size-5 translate-y-px"
        />
      </:actions>
      <div
        :if={@card.color}
        class={["h-3 rounded-t-2xl bg-gradient-to-r", Palette.gradient(@card.color)]}
      >
      </div>
      <p
        :if={!@can_write}
        id="card-access-note"
        class="flex items-center gap-2 bg-base-200 px-6 py-1.5 text-xs text-base-content/60"
      >
        <.icon name="hero-lock-closed" class="size-3.5" />
        {if @can_comment,
          do: "You can comment on this card, but not change it.",
          else: "You have read-only access to this card."}
      </p>
      <div
        :if={@parent}
        id="card-parent"
        class="flex min-w-0 items-center gap-3 bg-base-200/60 px-6 py-1.5 text-xs text-base-content/60"
      >
        <.link
          navigate={~p"/boards/#{@parent.board}/cards/#{@parent.card.id}"}
          class="flex min-w-0 items-center gap-1.5 hover:text-base-content"
          title={"Back to parent card: #{@parent.card.title}"}
        >
          <.icon name="hero-arrow-uturn-left" class="size-3.5 shrink-0" />
          <span class="shrink-0">Parent card</span>
          <span class="truncate font-medium">{@parent.card.title}</span>
        </.link>
        <.link
          navigate={~p"/boards/#{@parent.board}"}
          class="flex min-w-0 shrink items-center gap-1.5 hover:text-base-content"
          title={"Open the board that holds the parent card: #{@parent.board.name}"}
        >
          <.icon name="hero-squares-2x2" class="size-3.5 shrink-0" />
          <span class="shrink-0">Parent board</span>
          <span class="truncate font-medium">{@parent.board.name}</span>
        </.link>
      </div>
      <%!-- At the very top, so a card that is really an epic opens onto its
            board in one click instead of a scroll down to its subcards. --%>
      <div
        :if={@card.sub_board}
        id="card-open-board"
        class="flex min-w-0 items-center gap-2 bg-primary/5 py-1.5 pl-6 pr-24 text-xs text-base-content/70"
      >
        <.icon name="hero-squares-2x2" class="size-3.5 shrink-0 text-primary" />
        <span class="truncate">
          This card has subcards<span :for={{done, total} <- [Card.progress(@card)]}>
            · {done} of {total} done
          </span>
        </span>
        <.link
          navigate={~p"/boards/#{@card.sub_board.id}"}
          class="btn btn-primary btn-xs ml-auto shrink-0"
          title="Open this card's subcards as a board"
        >
          Open board <.icon name="hero-arrow-right" class="size-3.5" />
        </.link>
      </div>
      <%!-- Two kinds of control, two fieldsets: the card's own fields need
            write, the discussion (comments, status, votes) only comment. --%>
      <div class="grid grid-cols-1 md:grid-cols-[minmax(0,1fr)_260px]">
        <div class="min-w-0 space-y-7 p-6">
          <div class="space-y-3">
            <fieldset disabled={!@can_write} class="min-w-0">
              <.card_title_form
                board={@board}
                can_write={@can_write}
                card={@card}
                form={@form}
                handoff_link={
                  @can_comment and is_nil(current_handoff(@card)) and not @editing_handoff
                }
                target={@target}
              />
            </fieldset>
            <%!-- Where it was left (W-1804), just beneath the title, only once
                there is one or it is being written: most cards never get one,
                so until then it is a link on the meta line. Its own fieldset,
                since a commenter may write it. --%>
            <fieldset
              :if={current_handoff(@card) || @editing_handoff}
              disabled={!@can_comment}
              class="min-w-0"
            >
              <.handoff_panel
                card={@card}
                history={@handoff_history}
                editing={@editing_handoff}
                form={@handoff_form}
                can_comment={@can_comment}
                target={@target}
              />
            </fieldset>
            <fieldset disabled={!@can_write} class="min-w-0 space-y-7">
              <.card_header_form
                board={@board}
                can_write={@can_write}
                card={@card}
                current_user={@current_user}
                editing_description={@editing_description}
                form={@form}
                mention_people={@mention_people}
                tags_path={@tags_path}
                target={@target}
                uploads={@uploads}
              />

              <.attachments_section
                at={@at}
                can_write={@can_write}
                transcribe={Slipdock.Transcription.configured?()}
                card={@card}
                target={@target}
                uploads={@uploads}
              />

              <.checklist_section
                target={@target}
                item={@card}
                can_write={@can_write}
                form_key={@form_key}
                section_key="e"
              />
              <.subcards_section
                board={@board}
                can_write={@can_write}
                card={@card}
                form_key={@form_key}
                picking_template={@picking_template}
                target={@target}
                templates={@templates}
              />

              <.dependencies_section
                board={@board}
                card={@card}
                card_link={@card_link}
                dep_direction={@dep_direction}
                dep_query={@dep_query}
                dep_results={@dep_results}
                form_key={@form_key}
                target={@target}
              />

              <.docs_section
                board={@board}
                can_write={@can_write}
                doc_query={@doc_query}
                doc_results={@doc_results}
                pages={@pages}
                target={@target}
              />

              <.provenance_section :if={@provenance != []} provenance={@provenance} />

              <.jobs_section :if={@jobs != []} can_write={@can_write} jobs={@jobs} target={@target} />

              <.links_section
                board={@board}
                can_write={@can_write}
                card={@card}
                form_key={@form_key}
                link_kind={@link_kind}
                link_query={@link_query}
                link_results={@link_results}
                target={@target}
              />

              <.urls_section
                target={@target}
                item={@card}
                can_write={@can_write}
                form_key={@form_key}
                section_key="w"
              />
            </fieldset>
          </div>

          <fieldset disabled={!@can_comment} class="min-w-0">
            <%!-- Pasting an image attaches it to the card, so that is a writer's. --%>
            <.comments_section
              target={@target}
              item={@card}
              board={@board}
              current_user={@current_user}
              can_write={@can_write}
              can_comment={@can_comment}
              form_key={@form_key}
              uploads={@can_write && @uploads}
              mention_people={@mention_people}
              section_key="c"
            />
          </fieldset>
        </div>

        <.card_sidebar
          repeat={@repeat}
          board={@board}
          can_write={@can_write}
          can_comment={@can_comment}
          card={@card}
          current_user={@current_user}
          form={@form}
          form_key={@form_key}
          target={@target}
          users={@users}
        />
      </div>
      <div :if={@can_share} class="border-t border-base-content/10 px-6 py-4">
        <p class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Sharing this card
        </p>
        <.share_panel
          target={@target}
          resource="card"
          grants={@grants}
          groups={@groups}
          can_manage={@can_share}
          form_key={@share_key}
          compact
        />
      </div>
      <.live_component
        :if={@ai?}
        module={SlipdockWeb.AIChatComponent}
        id={"card-ai-#{@card.id}"}
        layout="inline"
        title="Ask AI about this card"
        placeholder="Ask about this card…"
        source={%{kind: :card, board: @board, card: @card, users: @users}}
        current_user={@current_user}
        can_write={@can_write}
      />
    </.modal>
    """
  end

  # The Repeat… form's state: what was typed, and what it would do.
  defp repeat_state(params, presets, zone, ref) do
    rule = repeat_rule(params)

    {preview, error} =
      case Slipdock.Recurrence.describe(rule, params["at"], zone, ref) do
        {:ok, preview} -> {preview, nil}
        {:error, message} -> {nil, repeat_error(message)}
      end

    %{
      form: to_form(params, as: :repeat),
      presets: presets,
      zone: zone,
      ref: ref,
      preview: preview,
      error: error
    }
  end

  defp repeat_rule(%{"preset" => "custom"} = params), do: params["custom"]
  defp repeat_rule(params), do: params["preset"]

  defp repeat_attrs(params, zone) do
    ends = params["ends"] || "never"

    %{
      "rule" => repeat_rule(params),
      "at" => params["at"],
      "timezone" => zone,
      "lead_days" => blank_nil(params["lead_days"]) || 0,
      "on_missed" => params["on_missed"] || "bump",
      "ends" => ends,
      "ends_on" => if(ends == "on", do: blank_nil(params["ends_on"])),
      "count" => if(ends == "after", do: blank_nil(params["count"]))
    }
  end

  defp blank_nil(""), do: nil
  defp blank_nil(v), do: v

  defp repeat_error(message) when is_binary(message), do: message

  defp repeat_error(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  # The card's handoff: nil if none was written or the newest is a clear.
  defp current_handoff(%Card{handoff: %Slipdock.Boards.Handoff{} = h}),
    do: if(Slipdock.Boards.Handoff.cleared?(h), do: nil, else: h)

  defp current_handoff(_), do: nil

  attr :card, :any, required: true
  attr :history, :list, required: true
  attr :editing, :boolean, required: true
  attr :form, :any, default: nil
  attr :can_comment, :boolean, required: true
  attr :target, :any, required: true

  # "Where it was left", beneath the title: the next step, the note, who,
  # when and how, with Update and the history on the byline; or, while it is
  # being written, the form, with the history under it. Shown only once there
  # is one or it is being written: the meta line's link opens the form.
  defp handoff_panel(assigns) do
    assigns = assign(assigns, current: current_handoff(assigns.card))

    ~H"""
    <section id="card-handoff" class="ml-1 space-y-1.5 border-l-2 border-info/40 pl-3">
      <div :if={@current && !@editing} id="handoff-current" class="space-y-1">
        <p class="flex items-start gap-1.5 text-sm">
          <.icon name="hero-arrow-uturn-left" class="mt-0.5 size-3.5 shrink-0 text-info" />
          <span>
            <span class="text-base-content/60">Left off — next:</span>
            <span class="font-medium" id="handoff-next">{@current.next_step}</span>
          </span>
        </p>
        <%!-- Hugging the text: pre-wrap would show the template's indent. --%>
        <p
          :if={@current.body}
          id="handoff-body"
          class="whitespace-pre-wrap font-mono text-xs text-base-content/70"
          phx-no-format
        >{@current.body}</p>
        <div class="flex flex-wrap items-center gap-x-1.5 text-2xs text-base-content/50">
          <span>{handoff_byline(@current)}</span>
          <span :if={@can_comment}>·</span>
          <button
            :if={@can_comment}
            id="handoff-edit"
            type="button"
            class="link link-hover hover:text-primary"
            phx-click="edit_handoff"
            phx-target={@target}
          >
            Update
          </button>
        </div>
        <.handoff_history :if={length(@history) > 1} history={@history} />
      </div>

      <.form
        :if={@editing && @form}
        for={@form}
        id="handoff-form"
        phx-submit="leave_handoff"
        phx-target={@target}
        class="space-y-2"
      >
        <.input
          field={@form[:next_step]}
          label="Next step"
          placeholder="The one next step"
          maxlength="280"
          required
        />
        <.input
          field={@form[:body]}
          type="textarea"
          label="Note"
          rows="5"
          class="textarea textarea-sm w-full font-mono text-xs"
          placeholder={Slipdock.Boards.Handoff.body_template()}
        />
        <div class="flex items-center gap-2">
          <button type="submit" class="btn btn-primary btn-xs">Save handoff</button>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="cancel_handoff"
            phx-target={@target}
          >
            Cancel
          </button>
          <button
            :if={@current}
            id="handoff-clear"
            type="button"
            class="btn btn-ghost btn-xs ml-auto"
            phx-click="clear_handoff"
            phx-target={@target}
            data-confirm="Clear the handoff? The history keeps it."
          >
            Clear
          </button>
        </div>
      </.form>

      <.handoff_history :if={@editing && @history != []} history={@history} />
    </section>
    """
  end

  attr :history, :list, required: true

  defp handoff_history(assigns) do
    ~H"""
    <details id="handoff-history" class="text-xs">
      <summary class="cursor-pointer text-base-content/50">History ({length(@history)})</summary>
      <ul class="mt-1 space-y-1">
        <li :for={h <- @history} id={"handoff-#{h.id}"} class="rounded bg-base-200/60 p-1.5">
          <span :if={!Slipdock.Boards.Handoff.cleared?(h)} class="font-medium">{h.next_step}</span>
          <span :if={Slipdock.Boards.Handoff.cleared?(h)} class="italic text-base-content/50">
            cleared
          </span>
          <span class="text-base-content/50">· {handoff_byline(h)}</span>
        </li>
      </ul>
    </details>
    """
  end

  defp handoff_byline(h) do
    who =
      cond do
        h.user -> Slipdock.Accounts.User.display_name(h.user)
        h.via == "runner" -> "a runner"
        true -> "someone"
      end

    job = if h.job_id, do: " · job ##{h.job_id}", else: ""
    "#{who} · #{relative_time(h.inserted_at)} · #{h.via}#{job}"
  end
end
