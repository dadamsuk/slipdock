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

  import SlipdockWeb.BoardLive.Helpers
  import SlipdockWeb.BoardLive.CardComponent.Modal

  alias Slipdock.Boards
  alias Slipdock.Boards.{Attachment, Card}
  alias SlipdockWeb.BoardLive.{ItemEvents, Paths, SubcardWaiting}

  alias SlipdockWeb.BoardLive.CardComponent.{
    FieldEvents,
    Glance,
    HandoffEvents,
    LinkEvents,
    RepeatEvents,
    State,
    WaitEvents
  }

  @own_events ~w(card_change toggle_flag toggle_tag create_tag set_cover set_border duplicate_card archive_card delete_card
    add_dependency remove_dependency create_sub_board remove_assignee delete_sub_board
    quick_add_subcard toggle_subcard edit_description stop_editing_description
    validate_attachments cancel_upload delete_attachment hide_on_card transcribe read_text add_link remove_link write_up
    toggle_pin_doc doc_search doc_focus attach_doc detach_doc card_timer accept_profile log_time dep_direction
    dep_search link_search pick_template comment_change share revoke_grant cancel_job
    edit_handoff cancel_handoff leave_handoff clear_handoff delete_handoff restore_handoff draft_handoff
    edit_repeat repeat_change save_repeat cancel_repeat skip_repeat pause_repeat stop_repeat
    answer_wait withdraw_wait skip_wait wait_change suggest_answer
    ask_questions ask_change ask_add ask_remove ask_save ask_cancel verify_work
    save_incident clear_incident reveal_sections)
  @events @own_events ++ ItemEvents.events()
  # What a reader who can't change the card may still do: nothing stored
  # changes, only what the panel is showing.
  @read_events ~w(stop_editing_description dep_direction dep_search link_search pick_template
    reveal_sections)
  # What a commenter (#863) may do besides: join the discussion, and nothing
  # that changes the card itself. Deleting a comment is only their own
  # (`ItemEvents`).
  @comment_events ~w(add_comment delete_comment add_status_update vote comment_change
    edit_handoff cancel_handoff leave_handoff clear_handoff delete_handoff restore_handoff draft_handoff)
  # Sharing has a rule of its own: the board's owner, or anybody who can edit
  # the card.
  @share_events ~w(share revoke_grant)

  @image_accept ~w(.png .jpg .jpeg .gif .webp image/png image/jpeg image/gif image/webp)

  # The modules the panel's own events are in: each names the ones it handles
  # (`events/0`), and between them they handle `@own_events` and nothing else.
  @event_modules [FieldEvents, WaitEvents, HandoffEvents, RepeatEvents, LinkEvents]

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
       panel_notice: nil,
       notice_for: nil,
       can_add: false,
       narrow?: false,
       # The sections the reader's card view hides, shown on this card
       # anyway after the hint's Show them (#2031).
       reveal_sections: false,
       form_key: 0,
       share_key: 0,
       card_pages: [],
       card_grants: [],
       card_jobs: [],
       card_loop: nil,
       card_authors: nil,
       card_findings: 0,
       card_timeline: nil,
       card_lead_time: nil,
       doc_query: "",
       doc_results: [],
       doc_pool: nil,
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
       handoff_draft: nil,
       wait_count: 0,
       wait_history: [],
       wait_answers: %{},
       wait_suggest: %{},
       asking: nil,
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
      %Card{id: ^card_id} -> {:ok, State.assign_jobs(socket)}
      _ -> {:ok, socket}
    end
  end

  # A page about this card was written from inside the panel, as Keep this
  # log does (#1872): the Docs section lists it straight away.
  def update(%{pages_changed: card_id}, socket) do
    case socket.assigns.card do
      %Card{id: ^card_id} -> {:ok, State.assign_pages(socket)}
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
        narrow?: assigns[:narrow?] || false,
        parent: assigns.parent,
        close_navigate: assigns.close_navigate,
        # The reader's card views (#2031): which sections the panel draws.
        card_view: assigns[:card_view]
      )

    socket = if given != socket.assigns.given, do: State.take(socket, given), else: socket

    # What in the epic's tree waits on the reader, over its subcard rows
    # (#2126): the board's entry for this card, as its tile shows it.
    {:ok, assign(socket, waiting: SubcardWaiting.build(assigns[:waiting], socket.assigns[:card]))}
  end

  # Called as each chunk lands; stores the file once the whole upload is in.
  defp handle_upload(_name, %{done?: false}, socket), do: {:noreply, socket}

  defp handle_upload(name, entry, socket) do
    socket = State.assign_access(socket)
    card = socket.assigns.card

    if is_nil(card) or not socket.assigns.can_write do
      {:noreply, cancel_upload(socket, name, entry.ref)}
    else
      meta = %{
        filename: entry.client_name,
        content_type: entry.client_type,
        size: entry.client_size
      }

      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Boards.Attachments.add_attachment(card, meta, path)}
        end)

      {:noreply, uploaded(socket, name, result)}
    end
  end

  ## Events ------------------------------------------------------------------

  @impl true
  def handle_event(event, _params, socket) when event not in @events,
    do: {:noreply, notice(socket, :error, "That isn't something this page can do.")}

  def handle_event(event, params, socket),
    do: guarded(event, params, State.assign_access(socket))

  defp guarded(_event, _params, %{assigns: %{card: nil}} = socket), do: {:noreply, socket}

  defp guarded(event, _params, %{assigns: %{can_share: false}} = socket)
       when event in @share_events,
       do: {:noreply, notice(socket, :error, "You can't share that.")}

  defp guarded(event, params, %{assigns: %{can_comment: true}} = socket)
       when event in @comment_events,
       do: dispatch(event, params, clear_notice(socket))

  defp guarded(event, _params, %{assigns: %{can_write: false}} = socket)
       when event not in @read_events and event not in @share_events,
       do: {:noreply, notice(socket, :error, read_only_message(socket))}

  defp guarded(event, params, socket), do: dispatch(event, params, clear_notice(socket))

  # Auto generate's draft (#1099), into the form if it is still open.
  @impl true
  def handle_async(:handoff_draft, {:ok, {:ok, draft}}, socket) do
    if socket.assigns.editing_handoff do
      form =
        to_form(%{"next_step" => draft.next_step, "body" => draft.body}, as: :handoff)

      {:noreply, assign(socket, handoff_form: form, handoff_draft: :done)}
    else
      {:noreply, assign(socket, handoff_draft: nil)}
    end
  end

  def handle_async(:handoff_draft, {:ok, {:error, message}}, socket),
    do: {:noreply, assign(socket, handoff_draft: {:error, message})}

  # Cancel while it ran: the form is gone, and so is the question.
  def handle_async(:handoff_draft, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, assign(socket, handoff_draft: nil)}

  # A suggested answer (#1220), into its box while the wait is still open.
  def handle_async({:wait_suggest, n}, {:ok, {:ok, text}}, socket) do
    socket = assign(socket, wait_suggest: Map.delete(socket.assigns.wait_suggest, n))

    if Card.open_wait(socket.assigns.card),
      do: {:noreply, assign(socket, wait_answers: Map.put(socket.assigns.wait_answers, n, text))},
      else: {:noreply, socket}
  end

  def handle_async({:wait_suggest, n}, {:ok, {:error, message}}, socket),
    do:
      {:noreply,
       assign(socket, wait_suggest: Map.put(socket.assigns.wait_suggest, n, {:error, message}))}

  def handle_async({:wait_suggest, n}, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         wait_suggest:
           Map.put(
             socket.assigns.wait_suggest,
             n,
             {:error, "The answer couldn't be suggested. Try again."}
           )
       )}

  def handle_async(:handoff_draft, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket, handoff_draft: {:error, "The draft couldn't be made. Try again."})}

  # One of the panel's own goes to the module that names it; the rest are the
  # shared sections' (`BoardLive.ItemEvents`), which act on the card as `item`.
  defp dispatch(event, params, socket) do
    case Enum.find(@event_modules, &Enum.member?(&1.events(), event)) do
      nil -> ItemEvents.handle(event, params, State.with_item(socket), &State.reload/1)
      module -> module.handle_event(event, params, socket)
    end
  end

  defp read_only_message(%{assigns: %{can_comment: true}}),
    do: "You can comment on this card, but not change it."

  defp read_only_message(_socket), do: "You have read-only access to this card."

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
        narrow?={@narrow?}
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
        can_add={@can_add}
        can_comment={@can_comment}
        can_share={@can_share}
        grants={@card_grants}
        pages={@card_pages}
        jobs={@card_jobs}
        loop={@card_loop}
        authors={@card_authors}
        findings={@card_findings}
        timeline={@card_timeline}
        lead_time={@card_lead_time}
        doc_query={@doc_query}
        doc_results={@doc_results}
        groups={@groups}
        share_key={@share_key}
        uploads={@uploads}
        editing_description={@editing_description}
        handoff_history={@handoff_history}
        shipped={assigns[:card_shipped] || []}
        deploy_failed={assigns[:card_deploy_failed] || []}
        release={assigns[:card_release]}
        not_shipped={assigns[:card_not_shipped]}
        incident={assigns[:card_incident]}
        incident_error={assigns[:incident_error]}
        panel_notice={@panel_notice}
        wait_count={@wait_count}
        wait_history={@wait_history}
        wait_answers={@wait_answers}
        wait_suggest={@wait_suggest}
        asking={@asking}
        editing_handoff={@editing_handoff}
        handoff_form={@handoff_form}
        handoff_draft={@handoff_draft}
        repeat={@repeat}
        parent={@parent}
        favourites={@favourites}
        waiting={@waiting}
        card_view={if @reveal_sections, do: nil, else: assigns[:card_view]}
        hidden_by_view={hidden_attention(@card, assigns[:card_view], @reveal_sections)}
        target={@myself}
      />
    </div>
    """
  end

  defp uploaded(socket, :attachment, {:ok, _}), do: socket

  defp uploaded(socket, name, {:ok, attachment}) do
    push_event(socket, "image_uploaded", %{
      upload: Atom.to_string(name),
      markdown: "![#{attachment.filename}](#{Boards.Attachments.attachment_url(attachment)})"
    })
  end

  defp uploaded(socket, name, {:error, changeset}) do
    {field, {msg, _}} = List.first(changeset.errors) || {:file, {"could not be stored", []}}

    socket
    |> notice(:error, "Upload failed: #{field} #{msg}.")
    |> image_failed(name)
  end

  @doc false
  defdelegate handoff_prose(body), to: Glance
end
