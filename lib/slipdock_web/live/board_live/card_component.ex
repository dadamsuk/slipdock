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

  alias Slipdock.{Access, Boards, Dates, Palette, Wiki}
  alias Slipdock.Boards.{Attachment, Board, Card, CardLink}
  alias SlipdockWeb.{Params, RichText}
  alias SlipdockWeb.BoardLive.{ItemEvents, Paths, Sharing}

  @own_events ~w(card_change toggle_flag toggle_tag set_cover archive_card delete_card
    add_dependency remove_dependency create_sub_board remove_assignee delete_sub_board
    quick_add_subcard toggle_subcard edit_description stop_editing_description
    validate_attachments cancel_upload delete_attachment add_link remove_link write_up
    toggle_pin_doc doc_search attach_doc detach_doc card_timer log_time dep_direction
    dep_search link_search pick_template comment_change share revoke_grant)
  @events @own_events ++ ItemEvents.events()
  # What a reader who can't change the card may still do: nothing stored
  # changes, only what the panel is showing.
  @read_events ~w(stop_editing_description dep_direction dep_search link_search pick_template)
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
       doc_query: "",
       doc_results: [],
       dep_direction: "blocked_by",
       dep_query: "",
       dep_results: [],
       link_kind: "relates",
       link_query: "",
       link_results: [],
       picking_template: false,
       editing_description: false
     )
     |> allow_upload(
       :attachment,
       [accept: :any, max_entries: 10, max_file_size: Attachment.max_size()] ++ opts
     )
     |> allow_upload(
       :desc_image,
       [accept: @image_accept, max_entries: 5, max_file_size: 10_000_000] ++ opts
     )
     |> allow_upload(
       :comment_image,
       [accept: @image_accept, max_entries: 5, max_file_size: 10_000_000] ++ opts
     )}
  end

  @impl true
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

    {readable, writable} =
      if given.board_id == board.id,
        do: card_access(given, user, perm == :view, config, view),
        else: {false, false}

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
            editing_description: false
          )

    if readable do
      socket
      |> assign(
        given: given,
        card: given,
        card_form: to_form(Boards.change_card(given)),
        can_write: writable,
        can_share: perm == :owner or writable
      )
      |> assign_pages()
    else
      assign(socket, given: given, card: nil, card_form: nil, can_write: false, can_share: false)
    end
  end

  # The wiki pages that talk about this card, pinned first (see
  # `Slipdock.Wiki.Links`), and who it is shared with.
  defp assign_pages(%{assigns: %{card: %Card{} = card}} = socket) do
    assign(socket,
      card_pages: Wiki.pages_for_card(card, socket.assigns.current_user),
      card_grants: if(socket.assigns.can_share, do: Access.list_grants(card), else: [])
    )
  end

  defp assign_pages(socket), do: socket

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

  def handle_event(event, _params, %{assigns: %{can_write: false}} = socket)
      when event not in @read_events and event not in @share_events,
      do: {:noreply, flash(socket, :error, "You have read-only access to this card.")}

  def handle_event(event, params, socket) do
    if event in @own_events,
      do: event(event, params, socket),
      else: ItemEvents.handle(event, params, with_item(socket), &reload/1)
  end

  # Put a fresh copy of the card in front of the reader.
  defp reload(socket), do: assign(socket, card: Boards.get_card!(socket.assigns.card.id))

  # The item the shared sections (`BoardLive.ItemEvents`) act on is the card.
  defp with_item(socket), do: assign(socket, item: socket.assigns.card)

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
          {:noreply, assign(socket, card: Boards.get_card!(card.id))}

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
      {:noreply, assign(socket, card: Boards.get_card!(card.id))}
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
           |> assign(card: Boards.get_card!(card.id))
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

  defp event("dep_direction", %{"direction" => dir}, socket)
       when dir in ~w(blocked_by blocks) do
    {:noreply, socket |> assign(dep_direction: dir) |> assign_dep_results()}
  end

  defp event("dep_search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(dep_query: q) |> assign_dep_results()}
  end

  defp event("add_dependency", %{"id" => id}, socket) do
    %{card: card, dep_direction: direction} = socket.assigns
    other = Boards.get_card!(id)

    result =
      case direction do
        "blocked_by" -> Boards.add_dependency(card, other)
        "blocks" -> Boards.add_dependency(other, card)
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
       |> assign(link_query: "", link_results: [], card: Boards.get_card!(card.id))
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
      {:noreply, assign(socket, card: Boards.get_card!(card.id))}
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

  defp event("create_sub_board", %{"template" => id}, socket) do
    case Boards.create_sub_board(socket.assigns.card, Boards.get_template!(id)) do
      {:ok, _} -> {:noreply, assign(socket, picking_template: false)}
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
        can_share={@can_share}
        grants={@card_grants}
        pages={@card_pages}
        doc_query={@doc_query}
        doc_results={@doc_results}
        groups={@groups}
        share_key={@share_key}
        uploads={@uploads}
        editing_description={@editing_description}
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

  defp assign_dep_results(%{assigns: %{card: %Card{} = card, dep_query: q}} = socket)
       when q != "" do
    linked = Enum.map(card.blocked_by ++ card.blocks, & &1.id)
    assign(socket, dep_results: Boards.search_cards(card.board_id, q, [card.id | linked]))
  end

  defp assign_dep_results(socket), do: assign(socket, dep_results: [])

  # Cards on any board the user can open, minus this card and those already linked.
  defp assign_link_results(%{assigns: %{card: %Card{} = card, link_query: q}} = socket)
       when q != "" do
    %{current_user: user, board: board} = socket.assigns

    root_ids =
      Enum.uniq([
        Slipdock.Boards.Board.root_id(board)
        | Enum.map(Access.list_boards(user, archived: :all), & &1.id)
      ])

    linked = Enum.map(card.links_out, & &1.to_id) ++ Enum.map(card.links_in, & &1.from_id)
    assign(socket, link_results: Boards.search_cards_across(root_ids, q, [card.id | linked]))
  end

  defp assign_link_results(socket), do: assign(socket, link_results: [])

  attr :card, :map, required: true

  defp contributions_bar(assigns) do
    contributions = Card.contributions(assigns.card)

    assigns =
      assign(assigns,
        total: length(contributions),
        done: Enum.count(contributions, & &1.completed)
      )

    ~H"""
    <div :if={@total > 0} class="flex items-center gap-2 text-xs" id="card-contributions">
      <progress class="progress progress-primary h-1.5 w-24" value={@done} max={@total}></progress>
      <span class="font-mono text-base-content/70">{@done}/{@total}</span>
      <span class="text-base-content/50">contributions done</span>
    </div>
    """
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
  attr :can_share, :boolean, required: true
  attr :grants, :list, required: true
  attr :pages, :list, default: [], doc: "the wiki pages that talk about this card"
  attr :doc_query, :string, default: "", doc: "what is typed into the Docs picker"
  attr :doc_results, :list, default: [], doc: "pages the Docs picker is offering"
  attr :groups, :list, required: true
  attr :share_key, :integer, required: true
  attr :uploads, :map, required: true
  attr :editing_description, :boolean, required: true
  attr :close_navigate, :boolean, default: false
  attr :parent, :any, default: nil
  attr :ai?, :boolean, default: false, doc: "offer the AI assistant on the card"

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
      size="lg"
      keys
    >
      <%!-- Outside the fieldset below, which is disabled for a read-only
            card: a favourite is the reader's own, not a change to the card. --%>
      <.favourite_toggle
        kind="card"
        id={@card.id}
        name={@card.title}
        marks={@favourites}
        class="btn btn-ghost btn-sm btn-circle absolute right-12 top-3 z-10"
        size="size-5"
      />
      <div
        :if={@card.color}
        class={["h-3 rounded-t-2xl bg-gradient-to-r", Palette.gradient(@card.color)]}
      >
      </div>
      <p
        :if={!@can_write}
        class="flex items-center gap-2 bg-base-200 px-6 py-1.5 text-xs text-base-content/60"
      >
        <.icon name="hero-lock-closed" class="size-3.5" /> You have read-only access to this card.
      </p>
      <.link
        :if={@parent}
        navigate={~p"/boards/#{@parent.board}/cards/#{@parent.card.id}"}
        class="flex min-w-0 items-center gap-1.5 bg-base-200/60 px-6 py-1.5 text-xs text-base-content/60 hover:text-base-content"
        title={"Back to parent card: #{@parent.card.title}"}
      >
        <.icon name="hero-arrow-uturn-left" class="size-3.5 shrink-0" />
        <span class="shrink-0">Parent card</span>
        <span class="truncate font-medium">{@parent.card.title}</span>
        <span class="shrink-0 text-base-content/40">on {@parent.board.name}</span>
      </.link>
      <fieldset disabled={!@can_write} class="contents">
        <div class="grid grid-cols-1 md:grid-cols-[minmax(0,1fr)_260px]">
          <div class="min-w-0 space-y-7 p-6">
            <.form
              phx-target={@target}
              for={@form}
              id="card-form"
              phx-change="card_change"
              phx-submit="card_change"
              class="space-y-3"
            >
              <div class="flex items-start gap-3 pr-8">
                <button
                  type="button"
                  class={[
                    "mt-1.5 shrink-0",
                    if(@card.completed,
                      do: "text-success",
                      else: "text-base-content/30 hover:text-success"
                    )
                  ]}
                  phx-click="toggle_complete"
                  phx-value-id={@card.id}
                  title={if @card.completed, do: "Mark incomplete", else: "Mark complete"}
                >
                  <.icon
                    name={
                      if @card.completed, do: "hero-check-circle-solid", else: "hero-check-circle"
                    }
                    class="size-6"
                  />
                </button>
                <textarea
                  name={@form[:title].name}
                  id="card-title"
                  rows="1"
                  phx-debounce="500"
                  phx-hook="AutoGrow"
                  data-single-line
                  class={[
                    "w-full resize-none rounded-lg bg-transparent px-1 text-xl font-bold leading-tight outline-none ring-primary/40 focus:bg-base-200/60 focus:ring-2 sm:text-2xl",
                    @card.completed && "opacity-60"
                  ]}
                  placeholder="Card title"
                >{@form[:title].value}</textarea>
              </div>
              <p :if={@form[:title].errors != []} class="text-sm text-error">Title can't be blank.</p>
              <div class="flex flex-wrap items-center gap-x-1.5 px-1 text-sm text-base-content/50">
                <span>in list</span>
                <%!-- The quickest way to move a card, and the only practical one
                      on a phone, where dragging it across a board that shows one
                      list at a time is no way to live. The sidebar keeps its own
                      copy of this field; `card_change` touches only what the form
                      it came from carried. --%>
                <select
                  :if={@can_write}
                  name="card[column_id]"
                  class="select select-ghost select-sm w-auto max-w-[12rem] pl-1 font-medium text-base-content/80"
                  title="Move this card to another list"
                  aria-label="List"
                >
                  <option
                    :for={{name, id} <- column_options(@board)}
                    value={id}
                    selected={id == @card.column_id}
                  >
                    {name}
                  </option>
                </select>
                <span :if={!@can_write} class="font-medium text-base-content/80">
                  {@card.column.name}
                </span>
                <%!-- `type="button"` matters: this sits inside the card form. --%>
                <button
                  :if={@can_write}
                  type="button"
                  id="card-move-board"
                  phx-click="open_move_board"
                  phx-target="#board-move"
                  phx-value-id={@card.id}
                  class="link link-hover text-base-content/60 hover:text-primary"
                  title="Move this card to another board, with its subcards"
                >
                  another board…
                </button>
                <span>· created {relative_time(@card.inserted_at)}</span>
              </div>

              <div class="space-y-1.5 px-1 pt-2" data-section-key="f">
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  <.keyed_label key="f" label="Flags" />
                </p>
                <div class="flex flex-wrap gap-1.5">
                  <.flag_toggle
                    :for={{flag, _, _, _, _} <- flags()}
                    phx-target={@target}
                    flag={flag}
                    active={flag in @card.flags}
                    phx-click="toggle_flag"
                    phx-value-flag={flag}
                  />
                </div>
              </div>

              <div class="space-y-1.5 px-1" data-section-key="t">
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  <.keyed_label key="t" label="Tags" />
                </p>
                <div class="flex flex-wrap items-center gap-1.5">
                  <.tag_toggle
                    :for={tag <- @board.tags}
                    phx-target={@target}
                    tag={tag}
                    active={Enum.any?(@card.tags, &(&1.id == tag.id))}
                    phx-click="toggle_tag"
                    phx-value-id={tag.id}
                  />
                  <.link patch={@tags_path} class="btn btn-ghost btn-xs">
                    <.icon name="hero-plus" class="size-3.5" /> New tag
                  </.link>
                </div>
              </div>

              <div class="space-y-1.5 px-1" data-section-key="d">
                <div class="flex items-center justify-between">
                  <label
                    for="card-description"
                    class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60"
                  >
                    <.icon name="hero-bars-3-bottom-left" class="size-3.5" />
                    <.keyed_label key="d" label="Description" />
                  </label>
                  <button
                    :if={@can_write and not @editing_description and (@card.description || "") != ""}
                    phx-target={@target}
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="edit_description"
                  >
                    <.icon name="hero-pencil" class="size-3.5" /> Edit
                  </button>
                  <button
                    :if={@editing_description}
                    phx-target={@target}
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="stop_editing_description"
                  >
                    <.icon name="hero-check" class="size-3.5" /> Done
                  </button>
                </div>
                <div
                  :if={@editing_description}
                  id="card-description-paste"
                  phx-hook="PasteImage"
                  data-upload="desc_image"
                  class="space-y-1"
                >
                  <div
                    id="card-description-mention"
                    phx-hook="Mention"
                    data-people={@mention_people}
                  >
                    <textarea
                      phx-target={@target}
                      id="card-description"
                      name={@form[:description].name}
                      phx-debounce="700"
                      phx-hook="AutoGrow"
                      phx-keydown="stop_editing_description"
                      phx-key="Escape"
                      autofocus
                      rows="3"
                      placeholder="Add more detail…"
                      class="textarea w-full resize-none text-sm leading-relaxed"
                    >{@form[:description].value}</textarea>
                  </div>
                  <.live_file_input upload={@uploads.desc_image} class="hidden" />
                  <p class="text-2xs text-base-content/60">
                    Paste or drop an image to add it; type @ to mention somebody. Click Done or press Escape when finished.
                  </p>
                </div>
                <div
                  :if={not @editing_description and (@card.description || "") != ""}
                  phx-target={@target}
                  id="card-description-view"
                  class={[
                    "rounded-lg px-1 py-1 text-sm leading-relaxed whitespace-pre-wrap break-words",
                    @can_write && "cursor-text hover:bg-base-200/60"
                  ]}
                  phx-click={@can_write && "edit_description"}
                  phx-no-format
                >{RichText.render(@card.description, board: @board, as: @current_user)}</div>
                <button
                  :if={not @editing_description and (@card.description || "") == "" and @can_write}
                  phx-target={@target}
                  type="button"
                  class="w-full rounded-lg bg-base-200/60 px-3 py-2 text-left text-sm text-base-content/50 hover:bg-base-200"
                  phx-click="edit_description"
                >
                  Add more detail…
                </button>
                <p
                  :if={
                    not @editing_description and (@card.description || "") == "" and not @can_write
                  }
                  class="px-1 text-sm italic text-base-content/40"
                >
                  No description.
                </p>
              </div>
            </.form>

            <section
              id="card-attachments"
              class="space-y-2 rounded-xl px-1 transition-colors"
              phx-drop-target={@uploads.attachment.ref}
              data-section-key="a"
            >
              <div class="flex items-center justify-between">
                <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  <.icon name="hero-paper-clip" class="size-3.5" />
                  <.keyed_label key="a" label="Attachments" />
                  <span :if={@card.attachments != []} class="font-normal">({length(@card.attachments)})</span>
                </h3>
                <form
                  :if={@can_write}
                  phx-target={@target}
                  id="attach-form"
                  phx-change="validate_attachments"
                  phx-submit="validate_attachments"
                >
                  <label class="btn btn-ghost btn-xs cursor-pointer">
                    <.icon name="hero-arrow-up-tray" class="size-3.5" /> Attach
                    <.live_file_input upload={@uploads.attachment} class="hidden" />
                  </label>
                </form>
              </div>
              <ul :if={@card.attachments != []} class="grid grid-cols-1 gap-2 sm:grid-cols-2">
                <li
                  :for={a <- @card.attachments}
                  id={"attachment-#{a.id}"}
                  class="group flex items-center gap-3 rounded-xl bg-base-200/70 p-2"
                >
                  <a
                    href={Boards.attachment_url(a)}
                    target="_blank"
                    rel="noopener"
                    class="flex size-12 shrink-0 items-center justify-center overflow-hidden rounded-lg bg-base-300/60"
                    title={a.filename}
                  >
                    <img
                      :if={Attachment.image?(a)}
                      src={Boards.attachment_url(a)}
                      alt={a.filename}
                      loading="lazy"
                      class="size-full object-cover"
                    />
                    <.icon
                      :if={not Attachment.image?(a)}
                      name={attachment_icon(a)}
                      class="size-6 text-base-content/50"
                    />
                  </a>
                  <div class="min-w-0 flex-1">
                    <a
                      href={Boards.attachment_url(a)}
                      target="_blank"
                      rel="noopener"
                      class="block truncate text-sm font-medium hover:underline"
                    >
                      {a.filename}
                    </a>
                    <p class="text-xs text-base-content/50">
                      {human_size(a.size)} · {relative_time(a.inserted_at)}
                    </p>
                  </div>
                  <button
                    :if={@can_write}
                    phx-target={@target}
                    type="button"
                    class="btn btn-ghost btn-xs btn-square shrink-0 opacity-0 group-hover:opacity-100 focus:opacity-100 no-hover:opacity-100"
                    phx-click="delete_attachment"
                    phx-value-id={a.id}
                    data-confirm={"Delete #{a.filename}?"}
                    title="Delete attachment"
                  >
                    <.icon name="hero-trash" class="size-3.5" />
                  </button>
                </li>
              </ul>
              <div
                :for={entry <- @uploads.attachment.entries}
                id={"upload-#{entry.ref}"}
                class="flex items-center gap-3 rounded-xl bg-base-200/40 px-3 py-2"
              >
                <.icon name="hero-arrow-up-tray" class="size-4 shrink-0 text-base-content/50" />
                <div class="min-w-0 flex-1 space-y-1">
                  <p class="truncate text-xs">{entry.client_name}</p>
                  <progress
                    class="progress progress-primary h-1 w-full"
                    value={entry.progress}
                    max="100"
                  ></progress>
                </div>
                <button
                  phx-target={@target}
                  type="button"
                  class="btn btn-ghost btn-xs btn-square"
                  phx-click="cancel_upload"
                  phx-value-name="attachment"
                  phx-value-ref={entry.ref}
                  title="Cancel upload"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </div>
              <p
                :if={@card.attachments == [] and @uploads.attachment.entries == [] and @can_write}
                class="text-xs text-base-content/40"
              >
                Drop files here, or paste images straight into the description or a comment.
              </p>
            </section>

            <.checklist_section
              target={@target}
              item={@card}
              can_write={@can_write}
              form_key={@form_key}
              section_key="e"
            />
            <section class="space-y-2 px-1" data-section-key="s">
              <div class="flex items-center justify-between">
                <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  <.icon name="hero-squares-2x2" class="size-3.5" />
                  <.keyed_label key="s" label="Subcards" />
                </h3>
                <div class="flex items-center gap-1.5">
                  <button
                    :if={@can_write and Board.sprints?(@board)}
                    id="card-sprint-add-cards"
                    type="button"
                    class="btn btn-xs"
                    phx-click="open_sprint_picker"
                    phx-target="#board-sprints"
                    phx-value-id={@card.id}
                    title="Pick cards from your boards to add to this sprint"
                  >
                    <.icon name="hero-queue-list" class="size-3.5" /> Add cards…
                  </button>
                  <.link
                    :if={@card.sub_board}
                    navigate={~p"/boards/#{@card.sub_board.id}"}
                    class="btn btn-xs btn-primary"
                  >
                    Open board <.icon name="hero-arrow-right" class="size-3.5" />
                  </.link>
                </div>
              </div>

              <%= if @card.sub_board do %>
                <div
                  :for={{done, total} <- [Card.progress(@card)]}
                  class="flex items-center gap-2 text-xs text-base-content/60"
                >
                  <progress
                    class={[
                      "progress h-1.5 flex-1",
                      if(total > 0 and done == total,
                        do: "progress-success",
                        else: "progress-primary"
                      )
                    ]}
                    value={done}
                    max={max(total, 1)}
                  ></progress>
                  <span>{done}/{total} done</span>
                  <span
                    :if={@card.rollup && @card.rollup.depth > 1}
                    title="Counting every level beneath this card"
                  >
                    · {@card.rollup.depth} levels
                  </span>
                  <.health_pill health={Card.health(@card)} />
                </div>
                <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
                  <div :for={col <- @card.sub_board.columns} class="rounded-xl bg-base-200/60 p-2">
                    <p class="mb-1 flex items-center gap-1.5 px-1 text-xs font-semibold">
                      <span :if={col.color} class={["size-2 rounded-full", Palette.dot(col.color)]}></span>
                      {col.name}
                      <span class="ml-auto font-mono text-2xs text-base-content/50">{Enum.count(
                        @card.sub_board.cards,
                        &(&1.column_id == col.id)
                      )}</span>
                    </p>
                    <ul class="space-y-0.5">
                      <li
                        :for={sub <- Enum.filter(@card.sub_board.cards, &(&1.column_id == col.id))}
                        id={"subcard-#{sub.id}"}
                        class="flex items-center gap-1.5 rounded px-1 py-0.5 text-sm hover:bg-base-100/60"
                      >
                        <button
                          phx-target={@target}
                          type="button"
                          phx-click="toggle_subcard"
                          phx-value-id={sub.id}
                          class={
                            if(sub.completed,
                              do: "text-success",
                              else: "text-base-content/30 hover:text-success"
                            )
                          }
                          title="Toggle complete"
                        >
                          <.icon
                            name={
                              if sub.completed,
                                do: "hero-check-circle-solid",
                                else: "hero-check-circle"
                            }
                            class="size-4"
                          />
                        </button>
                        <.link
                          navigate={~p"/boards/#{@card.sub_board.id}/cards/#{sub.id}"}
                          class={[
                            "truncate hover:underline",
                            sub.completed && "text-base-content/50"
                          ]}
                        >
                          {sub.title}
                        </.link>
                      </li>
                    </ul>
                    <form
                      phx-target={@target}
                      id={"add-subcard-#{col.id}-#{@form_key}"}
                      phx-submit="quick_add_subcard"
                      class="mt-1"
                    >
                      <input type="hidden" name="column_id" value={col.id} />
                      <input
                        type="text"
                        name="title"
                        placeholder="Add a subcard…"
                        class="input input-xs w-full"
                        autocomplete="off"
                        required
                      />
                    </form>
                  </div>
                </div>
                <button
                  phx-target={@target}
                  type="button"
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_sub_board"
                  data-confirm="Remove all subcards of this card? This deletes them permanently."
                >
                  <.icon name="hero-trash" class="size-3.5" /> Remove subcards
                </button>
              <% else %>
                <p class="text-xs text-base-content/50">
                  Turn this card into a board of its own. Pick a template for its lists.
                </p>
                <button
                  :if={!@picking_template}
                  phx-target={@target}
                  type="button"
                  class="btn btn-sm"
                  phx-click="pick_template"
                >
                  <.icon name="hero-squares-plus" class="size-4" /> Add subcards
                </button>
                <div
                  :if={@picking_template}
                  class="kanban-pop space-y-1 rounded-xl bg-base-200/60 p-2"
                >
                  <button
                    :for={t <- @templates}
                    phx-target={@target}
                    type="button"
                    class="flex w-full items-start gap-2 rounded-lg px-2 py-1.5 text-left hover:bg-base-100"
                    phx-click="create_sub_board"
                    phx-value-template={t.id}
                  >
                    <.icon name="hero-view-columns" class="mt-0.5 size-4 shrink-0 text-primary" />
                    <span class="min-w-0">
                      <span class="block text-sm font-medium">{t.name}</span>
                      <span class="block truncate text-xs text-base-content/50">{Enum.map_join(
                        t.columns,
                        " · ",
                        & &1["name"]
                      )}</span>
                    </span>
                  </button>
                  <p :if={@templates == []} class="px-2 text-xs text-base-content/50">
                    No templates yet.
                  </p>
                  <div class="flex items-center justify-between px-1 pt-1">
                    <.link navigate={~p"/templates"} class="text-xs text-primary hover:underline">Manage templates</.link>
                    <button
                      phx-target={@target}
                      type="button"
                      class="btn btn-ghost btn-xs"
                      phx-click="pick_template"
                    >Cancel</button>
                  </div>
                </div>
              <% end %>
            </section>

            <section :if={not @board.simple} class="space-y-2 px-1" data-section-key="p">
              <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                <.icon name="hero-link" class="size-3.5" />
                <.keyed_label key="p" label="Dependencies" />
              </h3>
              <div
                :for={
                  {label, cards, icon} <- [
                    {"Blocked by", @card.blocked_by, "hero-lock-closed"},
                    {"Blocks", @card.blocks, "hero-arrow-right-circle"}
                  ]
                }
                :if={cards != []}
                class="space-y-1"
              >
                <p class="text-xs text-base-content/60">{label}</p>
                <ul class="space-y-1">
                  <li
                    :for={dep <- cards}
                    id={"dep-#{label == "Blocks" && "blocks" || "by"}-#{dep.id}"}
                    class="group flex items-center gap-2 rounded-lg px-1 py-1 hover:bg-base-200/60"
                  >
                    <.icon
                      name={if dep.completed, do: "hero-check-circle-solid", else: icon}
                      class={[
                        "size-4 shrink-0",
                        if(dep.completed, do: "text-success", else: "text-error")
                      ]}
                    />
                    <.link
                      patch={@card_link.(dep.id)}
                      class={[
                        "min-w-0 flex-1 truncate text-sm hover:underline",
                        dep.completed && "text-base-content/50"
                      ]}
                    >
                      {dep.title}
                    </.link>
                    <span :if={dep.archived_at} class="badge badge-ghost badge-xs">archived</span>
                    <button
                      phx-target={@target}
                      type="button"
                      class="btn btn-ghost btn-xs btn-square opacity-0 group-hover:opacity-100 no-hover:opacity-100"
                      phx-click="remove_dependency"
                      phx-value-id={dep.id}
                      title="Remove dependency"
                    >
                      <.icon name="hero-x-mark" class="size-3.5" />
                    </button>
                  </li>
                </ul>
              </div>
              <form
                phx-target={@target}
                id={"dep-search-#{@form_key}"}
                phx-change="dep_search"
                phx-submit="dep_search"
                class="space-y-1.5"
              >
                <div class="flex items-center gap-1">
                  <div class="join">
                    <button
                      :for={{value, label} <- [{"blocked_by", "Blocked by"}, {"blocks", "Blocks"}]}
                      phx-target={@target}
                      type="button"
                      class={[
                        "btn btn-xs join-item",
                        if(@dep_direction == value, do: "btn-neutral", else: "btn-ghost")
                      ]}
                      phx-click="dep_direction"
                      phx-value-direction={value}
                    >
                      {label}
                    </button>
                  </div>
                  <input
                    type="search"
                    name="q"
                    value={@dep_query}
                    placeholder={
                      if @dep_direction == "blocked_by",
                        do: "Find the card this one waits for…",
                        else: "Find the card this one holds up…"
                    }
                    class="input input-sm flex-1"
                    phx-debounce="200"
                    autocomplete="off"
                  />
                </div>
                <ul :if={@dep_results != []} class="menu menu-sm rounded-xl bg-base-200/70 p-1">
                  <li :for={result <- @dep_results}>
                    <button
                      phx-target={@target}
                      type="button"
                      phx-click="add_dependency"
                      phx-value-id={result.id}
                    >
                      <.icon name="hero-plus" class="size-3.5" />
                      <span class={result.completed && "opacity-60"}>{result.title}</span>
                      <span class="ml-auto text-xs opacity-50">{column_name(@board, result.column_id)}</span>
                    </button>
                  </li>
                </ul>
                <p
                  :if={@dep_query != "" and @dep_results == []}
                  class="px-1 text-xs text-base-content/50"
                >
                  No other cards match.
                </p>
              </form>
            </section>

            <%!-- Docs: the wiki pages that talk about this card. A pinned page
                  is *the* spec, runbook or retro for it, which is a person's
                  judgement rather than something the prose says — so it leads,
                  and it survives whoever next edits the page. --%>
            <section class="space-y-2 px-1" id="card-docs" data-section-key="o">
              <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                <.icon name="hero-document-text" class="size-3.5" />
                <.keyed_label key="o" label="Docs" />
              </h3>
              <ul :if={@pages != []} class="space-y-1">
                <li
                  :for={link <- @pages}
                  id={"card-doc-#{link.id}"}
                  class="group flex items-center gap-2 text-sm"
                >
                  <.icon
                    name={if link.pinned, do: "hero-bookmark-solid", else: "hero-document-text"}
                    class={[
                      "size-4 shrink-0",
                      if(link.pinned, do: "text-primary", else: "text-base-content/40")
                    ]}
                  />
                  <.link
                    navigate={~p"/boards/#{link.page.board_id}/wiki/#{link.page.slug}"}
                    class="min-w-0 flex-1 truncate hover:underline"
                    title={link.page.summary || link.page.title}
                  >
                    {link.page.title}
                  </.link>
                  <span class="shrink-0 font-mono text-2xs text-base-content/40">{link.page.code}</span>
                  <button
                    :if={@can_write}
                    phx-target={@target}
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="toggle_pin_doc"
                    phx-value-page={link.page.id}
                    title={
                      if link.pinned, do: "Unpin this doc", else: "Pin: this is the doc for this card"
                    }
                  >
                    <.icon
                      name={if link.pinned, do: "hero-bookmark-slash", else: "hero-bookmark"}
                      class="size-3.5"
                    />
                  </button>
                  <%!-- Only a link the prose does not make can be taken off
                        here: a page that really names this card keeps saying
                        so (see `Slipdock.Wiki.Links.unlink/2`). --%>
                  <button
                    :if={@can_write and link.count == 0}
                    phx-target={@target}
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="detach_doc"
                    phx-value-page={link.page.id}
                    title="Detach this doc"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </li>
              </ul>
              <p :if={@pages == []} class="text-xs text-base-content/50">
                Nothing written about this card yet.
              </p>
              <div :if={@can_write} class="flex flex-wrap items-center gap-1">
                <button
                  phx-target={@target}
                  type="button"
                  class="btn btn-ghost btn-xs gap-1"
                  phx-click="write_up"
                >
                  <.icon name="hero-pencil-square" class="size-3.5" /> Write it up
                </button>
                <.link navigate={~p"/boards/#{@board}/wiki"} class="btn btn-ghost btn-xs">
                  Open the wiki
                </.link>
              </div>
              <%!-- Most of the time the document already exists and what is
                    missing is the link to it. --%>
              <form
                :if={@can_write}
                phx-target={@target}
                id="card-doc-search"
                phx-change="doc_search"
                phx-submit="doc_search"
                class="relative"
              >
                <.icon
                  name="hero-magnifying-glass"
                  class="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-base-content/40"
                />
                <input
                  type="search"
                  name="q"
                  value={@doc_query}
                  placeholder="Attach a page already written…"
                  phx-debounce="200"
                  autocomplete="off"
                  class="input input-xs w-full rounded-full pl-7"
                />
              </form>
              <ul :if={@doc_results != []} class="space-y-0.5">
                <li :for={page <- @doc_results}>
                  <button
                    phx-target={@target}
                    type="button"
                    phx-click="attach_doc"
                    phx-value-page={page.id}
                    class="flex w-full items-center gap-1.5 rounded-lg px-1.5 py-1 text-left text-xs hover:bg-base-200"
                  >
                    <.icon name="hero-plus" class="size-3 shrink-0 text-base-content/40" />
                    <span class="min-w-0 flex-1 truncate">{page.title}</span>
                    <span class="shrink-0 font-mono text-2xs text-base-content/40">{page.code}</span>
                  </button>
                </li>
              </ul>
            </section>

            <section class="space-y-2 px-1" id="card-links" data-section-key="n">
              <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                <.icon name="hero-arrows-right-left" class="size-3.5" />
                <.keyed_label key="n" label="Links" />
              </h3>
              <ul :if={@card.links_out != [] or @card.links_in != []} class="space-y-1">
                <li
                  :for={
                    {link, other, dir} <-
                      Enum.map(@card.links_out, &{&1, &1.to, :out}) ++
                        Enum.map(@card.links_in, &{&1, &1.from, :in})
                  }
                  id={"link-#{link.id}"}
                  class="flex items-center gap-2 text-xs"
                >
                  <span class="chip chip-line shrink-0 text-2xs">{CardLink.label(link.kind, dir)}</span>
                  <.link
                    navigate={~p"/boards/#{other.board_id}/cards/#{other.id}"}
                    class={[
                      "min-w-0 flex-1 truncate hover:underline",
                      other.completed && "text-base-content/60"
                    ]}
                    title={other.title}
                  >
                    {other.title}
                  </.link>
                  <span
                    :if={other.board_id != @board.id and match?(%{name: _}, other.board)}
                    class="max-w-32 shrink-0 truncate text-2xs text-base-content/50"
                    title={"On board #{other.board.name}"}
                  >
                    {other.board.name}
                  </span>
                  <button
                    :if={@can_write}
                    phx-target={@target}
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="remove_link"
                    phx-value-id={link.id}
                    title="Remove link"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </li>
              </ul>
              <.contributions_bar card={@card} />
              <form
                :if={@can_write}
                phx-target={@target}
                id={"link-form-#{@form_key}"}
                phx-change="link_search"
                phx-submit="link_search"
                class="space-y-1.5"
              >
                <div class="flex gap-1">
                  <select name="kind" class="select select-xs w-36" title="Kind of link">
                    <option
                      :for={{key, label, _} <- CardLink.kinds()}
                      value={key}
                      selected={key == @link_kind}
                    >
                      {label}
                    </option>
                  </select>
                  <input
                    type="search"
                    name="q"
                    value={@link_query}
                    placeholder="Search cards on any board…"
                    class="input input-xs min-w-0 flex-1"
                    autocomplete="off"
                    phx-debounce="250"
                  />
                </div>
                <ul :if={@link_results != []} class="menu menu-sm rounded-xl bg-base-200/70 p-1">
                  <li :for={result <- @link_results}>
                    <button
                      phx-target={@target}
                      type="button"
                      phx-click="add_link"
                      phx-value-id={result.id}
                      class="flex items-center gap-2"
                    >
                      <span class="truncate">{result.title}</span>
                      <span class="ml-auto shrink-0 text-2xs text-base-content/50">{result.board.name}</span>
                    </button>
                  </li>
                </ul>
                <p
                  :if={@link_query != "" and @link_results == []}
                  class="px-1 text-xs text-base-content/50"
                >
                  No cards match.
                </p>
              </form>
            </section>

            <.urls_section
              target={@target}
              item={@card}
              can_write={@can_write}
              form_key={@form_key}
              section_key="w"
            />

            <.comments_section
              target={@target}
              item={@card}
              board={@board}
              current_user={@current_user}
              can_write={@can_write}
              form_key={@form_key}
              uploads={@uploads}
              mention_people={@mention_people}
              section_key="c"
            />
          </div>

          <aside class="min-w-0 space-y-5 rounded-b-2xl bg-base-200/60 p-5 md:rounded-r-2xl md:rounded-bl-none">
            <.form
              phx-target={@target}
              for={@form}
              id="card-meta-form"
              phx-change="card_change"
              class="space-y-4"
            >
              <label class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">List</span>
                <select name="card[column_id]" class="select select-sm w-full">
                  <option
                    :for={{name, id} <- column_options(@board)}
                    value={id}
                    selected={id == @card.column_id}
                  >
                    {name}
                  </option>
                </select>
              </label>
              <div class="space-y-1" id="card-assignees">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Assignees
                </span>
                <ul :if={Card.assignees(@card) != []} class="flex flex-wrap gap-1">
                  <li
                    :for={u <- Card.assignees(@card)}
                    id={"card-assignee-#{u.id}"}
                    class="inline-flex items-center gap-1 rounded-full bg-base-200 py-0.5 pr-1 pl-0.5"
                  >
                    <.assignee_chip user={u} size="xs" with_name />
                    <button
                      phx-target={@target}
                      type="button"
                      phx-click="remove_assignee"
                      phx-value-id={u.id}
                      class="rounded-full p-0.5 text-base-content/50 transition hover:bg-base-300 hover:text-base-content"
                      title={"Unassign #{Slipdock.Accounts.User.display_name(u)}"}
                    >
                      <.icon name="hero-x-mark" class="size-3" />
                    </button>
                  </li>
                </ul>
                <%!-- Keyed on who is already on the card, so the picker comes back
                     empty after each pick instead of re-sending the last one. --%>
                <select
                  name="card[add_assignee_id]"
                  class="select select-sm w-full"
                  id={"card-assignee-add-" <> Enum.map_join(Card.assignees(@card), "-", & &1.id)}
                >
                  <option value="" selected>
                    {if Card.assignees(@card) == [],
                      do: "Unassigned — add someone…",
                      else: "Add someone…"}
                  </option>
                  <option
                    :for={u <- @users}
                    :if={not Card.assigned_to?(@card, u.id)}
                    value={u.id}
                  >
                    {Slipdock.Accounts.User.display_name(u)}
                  </option>
                </select>
              </div>
              <label class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Priority</span>
                <select name="card[priority]" class="select select-sm w-full">
                  <option
                    :for={{label, value} <- priority_options()}
                    value={value}
                    selected={value == @card.priority}
                  >
                    {label}
                  </option>
                </select>
              </label>
              <%!-- A simple board is a to-do list: what follows down to Health,
                    bar the due date and Completed, is project tracking, and
                    stays out of its way (`Board.simple?/1`). --%>
              <label :if={not @board.simple} class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">% complete</span>
                <div class="flex items-center gap-2">
                  <input
                    type="number"
                    name="card[percent_complete]"
                    id="card-percent-complete"
                    value={@card.percent_complete}
                    min="0"
                    max="100"
                    step="5"
                    placeholder="—"
                    phx-debounce="400"
                    class="input input-sm w-20"
                  />
                  <progress
                    :if={@card.percent_complete}
                    class={[
                      "progress h-1.5 flex-1",
                      if(@card.percent_complete == 100,
                        do: "progress-success",
                        else: "progress-primary"
                      )
                    ]}
                    value={@card.percent_complete}
                    max="100"
                  ></progress>
                </div>
                <p :if={@form[:percent_complete].errors != []} class="text-xs text-error">
                  Use a whole number from 0 to 100.
                </p>
              </label>
              <label :if={not @board.simple} class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Start date</span>
                <input
                  type="date"
                  name="card[start_date]"
                  value={@card.start_date}
                  max={@card.due_date}
                  class="input input-sm w-full"
                />
              </label>
              <label class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Due date</span>
                <input
                  type="date"
                  name="card[due_date]"
                  value={@card.due_date}
                  min={@card.start_date}
                  class="input input-sm w-full"
                />
                <.due_badge date={@card.due_date} completed={@card.completed} />
                <p :if={@form[:start_date].errors != []} class="text-xs text-error">
                  Start must be on or before the due date.
                </p>
              </label>
              <label :if={not @board.simple} class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Precision</span>
                <select
                  name="card[date_precision]"
                  class="select select-sm w-full"
                  id="card-precision"
                >
                  <option
                    :for={{key, label} <- Dates.precisions()}
                    value={key}
                    selected={key == (@card.date_precision || "day")}
                  >
                    {label}
                  </option>
                </select>
                <p :if={Card.fuzzy?(@card) and @card.due_date} class="text-xs text-base-content/60">
                  Scheduled for {Dates.range_label(
                    @card.start_date || @card.due_date,
                    @card.due_date,
                    @card.date_precision
                  )}
                </p>
              </label>
              <div
                :if={
                  (not @board.simple and @card.rollup) && @card.rollup.children > 0 &&
                    @card.rollup.derived_due
                }
                class="space-y-1 rounded-lg bg-base-200/60 p-2 text-xs"
                id="card-rollup-dates"
              >
                <p class="flex items-center gap-1 font-semibold uppercase tracking-wide text-base-content/60">
                  <.icon name="hero-arrow-up-on-square-stack" class="size-3.5" /> From subcards
                </p>
                <p class="text-base-content/80">
                  {fmt_date(@card.rollup.derived_start)} → {fmt_date(@card.rollup.derived_due)}
                </p>
                <p
                  :if={@card.rollup.start_slip > 0}
                  class="flex items-center gap-1 text-warning-content dark:text-warning"
                >
                  <.icon name="hero-arrow-trending-up" class="size-3.5" />
                  {past_date_label(:start, @card.rollup.start_slip)}
                  <span class="text-base-content/50">(yours: {fmt_date(@card.start_date)})</span>
                </p>
                <p
                  :if={@card.rollup.due_slip > 0}
                  class="flex items-center gap-1 text-warning-content dark:text-warning"
                >
                  <.icon name="hero-arrow-trending-up" class="size-3.5" />
                  {past_date_label(:due, @card.rollup.due_slip)}
                  <span class="text-base-content/50">(yours: {fmt_date(@card.due_date)})</span>
                </p>
                <p :if={is_nil(@card.due_date)} class="text-base-content/50">
                  No due date of its own, so the subcards set it.
                </p>
              </div>
              <p
                :if={Card.days_past_due(@card) > 0}
                class="flex items-center gap-1 rounded-lg bg-error/10 p-2 text-xs text-error"
                id="card-past-due"
              >
                <.icon name="hero-exclamation-triangle" class="size-3.5" />
                This card is {past_date_label(:due, Card.days_past_due(@card))}
              </p>
              <label class="flex cursor-pointer items-center justify-between">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Completed</span>
                <input type="hidden" name="card[completed]" value="false" />
                <input
                  type="checkbox"
                  name="card[completed]"
                  value="true"
                  class="toggle toggle-success toggle-sm"
                  checked={@card.completed}
                />
              </label>
              <div :if={not @board.simple} class="space-y-1.5" id="card-status">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Health</span>
                <div class="flex flex-wrap items-center gap-1.5">
                  <.health_pill health={Card.health(@card)} />
                  <.stated_pill
                    :if={Card.stated_health(@card)}
                    health={Card.stated_health(@card)}
                    title="Reported by the card's owner"
                  />
                </div>
                <p class="text-xs text-base-content/50">
                  The first pill is computed from dates, blockers and subcards; the second is
                  what was last reported.
                </p>
              </div>
            </.form>
            <.time_section
              :if={not @board.simple}
              target={@target}
              card={@card}
              can_write={@can_write}
              form_key={@form_key}
            />
            <.status_section
              :if={not @board.simple}
              target={@target}
              item={@card}
              can_write={@can_write}
              form_key={@form_key}
              stated={Card.stated_health(@card)}
            />
            <.fields_section target={@target} item={@card} board={@board} can_write={@can_write} />
            <.vote_box
              :if={not @board.simple}
              target={@target}
              item={@card}
              board={@board}
              current_user={@current_user}
              can_write={@can_write}
            />

            <div class="space-y-1.5">
              <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Cover</span>
              <div class="flex flex-wrap gap-1.5">
                <button
                  phx-target={@target}
                  type="button"
                  class={[
                    "flex size-6 items-center justify-center rounded-full ring-1 ring-base-content/20 ring-offset-2 ring-offset-base-100",
                    is_nil(@card.color) && "ring-2 ring-base-content"
                  ]}
                  phx-click="set_cover"
                  phx-value-color=""
                  title="No cover"
                >
                  <.icon name="hero-no-symbol" class="size-3.5 opacity-50" />
                </button>
                <.color_swatch
                  :for={{name, _} <- Palette.all()}
                  phx-target={@target}
                  color={name}
                  selected={@card.color == name}
                  phx-click="set_cover"
                  phx-value-color={name}
                />
              </div>
            </div>

            <div class="space-y-1.5 border-t border-base-content/10 pt-4">
              <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Actions</span>
              <button
                phx-target={@target}
                type="button"
                class="btn btn-sm w-full justify-start"
                phx-click="archive_card"
              >
                <.icon name="hero-archive-box" class="size-4" /> Archive
              </button>
              <button
                phx-target={@target}
                type="button"
                class="btn btn-ghost btn-sm w-full justify-start text-error"
                phx-click="delete_card"
                data-confirm="Delete this card permanently?"
              >
                <.icon name="hero-trash" class="size-4" /> Delete
              </button>
            </div>
          </aside>
        </div>
      </fieldset>
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
end
