defmodule SlipdockWeb.WikiLive.PageEvents do
  @moduledoc """
  `WikiLive.Index`'s events on the page open in the middle: editing and
  saving it, its history, publishing, the cards it is about, and the card
  contents a meeting page carries (checklist, comments, fields, votes).
  """
  use SlipdockWeb.WikiLive.Events

  import SlipdockWeb.WikiLive.Format
  import SlipdockWeb.WikiLive.State
  import SlipdockWeb.WikiLive.Drafts
  alias Slipdock.{Boards, Fields, Votes, Wiki}
  alias Slipdock.Wiki.{Autosaves, LineChanges, Page}
  alias SlipdockWeb.BoardLive.Helpers
  alias SlipdockWeb.Params

  ## Events -------------------------------------------------------------------

  # The tree's Email this folder… (#1277): the addresses dialog, for that
  # folder; it checks the reader may write there before showing anything.
  def handle_event("email_folder", %{"id" => id}, socket) do
    if socket.assigns.inbound do
      send_update(SlipdockWeb.InboundAddressesComponent,
        id: "board-inbound",
        open_folder: id
      )
    end

    {:noreply, socket}
  end

  def handle_event("validate", %{"page" => params}, socket) do
    # An image the upload refuses (too big, not an image) would otherwise sit
    # in the form with its error, and LiveView refuses to submit a form with
    # an upload error in it: the page could not be saved at all.
    socket = Helpers.drop_invalid_uploads(socket, :page_image)
    params = Map.update(params, "body", nil, &Helpers.strip_upload_placeholder/1)
    changeset = Wiki.change_page(socket.assigns.editing, params)

    {:noreply,
     socket
     |> assign(form: to_form(Map.put(changeset, :action, :validate)))
     |> assign(preview: render_body(socket, socket.assigns.page, params["body"] || ""))
     |> queue_autosave(params)}
  end

  # Cancel means it: what was typed goes, auto-save and all.
  def handle_event("cancel_edit", _params, socket) do
    %{board: board, page: page} = socket.assigns

    {:noreply,
     socket
     |> clear_autosave()
     |> push_navigate(to: if(page, do: page_path(board, page), else: wiki_path(board)))}
  end

  # From the banner over a restored editor: start again from the page.
  def handle_event("discard_autosave", %{"id" => id}, socket) do
    %{board: board, current_user: user} = socket.assigns
    Autosaves.discard(Autosaves.get(user, board, id))
    {:noreply, assign_unsaved(socket)}
  end

  def handle_event("discard_autosave", _params, socket) do
    %{board: board, page: page} = socket.assigns

    to =
      if page,
        do: ~p"/boards/#{board}/wiki/#{page.slug}/edit",
        else: ~p"/boards/#{board}/wiki/new"

    {:noreply, socket |> clear_autosave() |> push_navigate(to: to)}
  end

  def handle_event("save", %{"page" => params} = all, socket) do
    params = Map.update(params, "body", nil, &Helpers.strip_upload_placeholder/1)

    if socket.assigns.can_write do
      {:noreply,
       save(socket, socket.assigns.page, params, all["message"], all["purge_revisions"])}
    else
      {:noreply, put_flash(socket, :error, "You can't write on this board.")}
    end
  end

  # The editor has just encrypted a passage that was already on the page,
  # and wants to know which revisions still hold it. It gets the bodies and
  # looks for itself, so the passage is never sent here (W-103 R6.2).
  def handle_event("meld_history", _params, socket) do
    case socket.assigns do
      %{page: %Page{} = page, can_write: true} ->
        {:reply, %{revisions: Wiki.revision_bodies(page), owner: socket.assigns.can_manage},
         socket}

      _ ->
        {:reply, %{revisions: [], owner: false}, socket}
    end
  end

  def handle_event("archive", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, _} <- Wiki.archive_page(page) do
      {:noreply,
       socket
       |> put_flash(:info, "Archived “#{page.title}”.")
       |> push_patch(to: ~p"/boards/#{socket.assigns.board}/wiki")}
    else
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be archived.")}
    end
  end

  def handle_event("restore", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, page} <- Wiki.unarchive_page(page) do
      {:noreply, socket |> put_flash(:info, "Restored “#{page.title}”.") |> reload(page)}
    else
      {:error, %Ecto.Changeset{} = refused} ->
        {:noreply, put_flash(socket, :error, Slipdock.Quota.refusal_message(refused))}

      _ ->
        {:noreply, put_flash(socket, :error, "That page couldn't be restored.")}
    end
  end

  # The purge, as opposed to archiving: the owner's only, and the one thing on
  # this view that cannot be undone. Children are left behind at the top of
  # the tree rather than going silently with it, which is why the warning says
  # how many there are (see `Slipdock.Wiki.delete_page/1`).
  def handle_event("delete_page", _params, socket) do
    with true <- socket.assigns.can_manage,
         %Page{} = page <- socket.assigns.page,
         {:ok, _} <- Wiki.delete_page(page) do
      {:noreply,
       socket
       |> put_flash(:info, "Deleted “#{page.title}” for good.")
       |> push_patch(to: ~p"/boards/#{socket.assigns.board}/wiki")}
    else
      false -> {:noreply, put_flash(socket, :error, "Only the board's owner can delete a page.")}
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be deleted.")}
    end
  end

  # A history row opened to show the lines that version changed (#1745), or
  # closed again. Worked out on demand from that version and the one before
  # it, so the list itself stays one query. Only the listed versions open.
  def handle_event("history_preview", %{"id" => id}, socket) do
    previews = socket.assigns.history_previews

    case Enum.find(socket.assigns.revisions, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      %{id: rid} when is_map_key(previews, rid) ->
        {:noreply, assign(socket, history_previews: Map.delete(previews, rid))}

      revision ->
        prev = Wiki.previous_revision(revision)
        preview = LineChanges.preview(prev && prev.body, revision.body)
        {:noreply, assign(socket, history_previews: Map.put(previews, revision.id, preview))}
    end
  end

  # Either way round the picker is filled in, the older version goes on the
  # left: the history lists newest first, so the later position is older.
  def handle_event("compare", %{"from" => from, "to" => to}, socket) when from != to do
    ids = Enum.map(socket.assigns.revisions, &to_string(&1.id))

    case {Enum.find_index(ids, &(&1 == from)), Enum.find_index(ids, &(&1 == to))} do
      {i, j} when is_integer(i) and is_integer(j) ->
        {newer, older} = if i < j, do: {from, to}, else: {to, from}
        board = socket.assigns.board
        slug = socket.assigns.page.slug

        {:noreply,
         push_patch(socket,
           to: ~p"/boards/#{board}/wiki/#{slug}/history/#{newer}?against=#{older}"
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Pick two versions from the list to compare.")}
    end
  end

  def handle_event("compare", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Pick two different versions to compare.")}

  def handle_event("revert", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         revision when not is_nil(revision) <- socket.assigns.revision,
         {:ok, page} <-
           Wiki.revert_page(page, revision, user: socket.assigns.current_user, via: "web") do
      {:noreply,
       socket
       |> put_flash(:info, "Put “#{page.title}” back to that version.")
       |> push_patch(to: ~p"/boards/#{socket.assigns.board}/wiki/#{page.slug}")}
    else
      _ -> {:noreply, put_flash(socket, :error, "That version couldn't be restored.")}
    end
  end

  # Publishing answers the page's live queries now and keeps the answers: an
  # anonymous reader has no permissions for a query to run with.
  def handle_event("publish", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, published} <- Wiki.publish(page, user: socket.assigns.current_user) do
      {:noreply,
       socket
       |> put_flash(:info, "Published. Anyone with the link can read it.")
       |> reload(published)}
    else
      {:error, _, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      _ ->
        {:noreply, put_flash(socket, :error, "That page couldn't be published.")}
    end
  end

  def handle_event("unpublish", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, withdrawn} <- Wiki.unpublish(page) do
      {:noreply, socket |> put_flash(:info, "Link withdrawn.") |> reload(withdrawn)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That link couldn't be withdrawn.")}
    end
  end

  ## Events: the cards a page is about ---------------------------------------
  #
  # A page and a card find each other through a pinned link, not through the
  # prose: the stub "Write it up" leaves behind is meant to be replaced, and
  # replacing it must not detach the page (see `Slipdock.Wiki.Links.reconcile/1`).

  def handle_event("card_search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(card_query: q) |> assign_card_results()}
  end

  def handle_event("attach_card", %{"id" => id}, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         %{} = card <- Boards.get_card(Params.id(id)),
         {:ok, _} <- Wiki.pin(page, {:card, card}) do
      {:noreply,
       socket
       |> put_flash(:info, "This page is now the doc for “#{card.title}”.")
       |> assign(card_query: "", card_results: [])
       |> reload(page)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That card couldn't be attached.")}
    end
  end

  # Favouriting the open page (#1165). Personal, so reading it is enough, and
  # `Favourites.toggle/3` re-checks that; the page itself is not touched.
  def handle_event("toggle_favourite", %{"kind" => kind, "id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, kind} <- Slipdock.Favourites.kind(kind),
         id when is_integer(id) <- Params.id(id),
         {:ok, _} <- Slipdock.Favourites.toggle(user, kind, id) do
      {:noreply, assign(socket, marks: Slipdock.Favourites.marks(user))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_pin_card", %{"id" => id}, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         %{} = card <- Boards.get_card(Params.id(id)),
         link <- Enum.find(socket.assigns.cards, &(&1.target_card_id == card.id)),
         {:ok, _} <- Wiki.pin(page, {:card, card}, not (link && link.pinned)) do
      {:noreply, reload(socket, page)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That pin couldn't be changed.")}
    end
  end

  # Detaching only ever removes a link the prose does not make. A card the
  # body names stays listed, because the page really does talk about it.
  def handle_event("detach_card", %{"id" => id}, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         %{} = card <- Boards.get_card(Params.id(id)),
         {:ok, _} <- Wiki.unlink(page, {:card, card}) do
      {:noreply, reload(socket, page)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That card couldn't be detached.")}
    end
  end

  def handle_event("add_check", %{"text" => text}, socket) do
    if String.trim(text) == "",
      do: {:noreply, socket},
      else: contents_event(socket, &Boards.add_checklist_item(&1, String.trim(text)))
  end

  def handle_event("toggle_check", %{"id" => id}, socket),
    do:
      contents_event(socket, fn page ->
        if item = Boards.get_checklist_item(page, id), do: Boards.toggle_checklist_item(item)
      end)

  def handle_event("delete_check", %{"id" => id}, socket),
    do:
      contents_event(socket, fn page ->
        if item = Boards.get_checklist_item(page, id), do: Boards.delete_checklist_item(item)
      end)

  def handle_event("move_check", %{"id" => id} = params, socket),
    do:
      contents_event(socket, fn page ->
        if item = Boards.get_checklist_item(page, id),
          do: Boards.move_checklist_item(item, params["before"])
      end)

  def handle_event("add_comment", %{"body" => body}, socket) do
    if String.trim(body) == "",
      do: {:noreply, socket},
      else:
        discussion_event(
          socket,
          &Boards.add_comment(&1, String.trim(body), by: socket.assigns.current_user)
        )
  end

  # The page's own view has no paste-an-image upload on the comment box, so
  # the change event the shared form sends has nothing to do here.
  def handle_event("comment_change", _params, socket), do: {:noreply, socket}

  # A writer takes back any comment; a commenter only their own (#863).
  def handle_event("delete_comment", %{"id" => id}, socket) do
    %{can_write: can_write, current_user: user} = socket.assigns

    discussion_event(socket, fn page ->
      if Enum.any?(
           page.comments,
           &(to_string(&1.id) == id and (can_write or &1.user_id == user.id))
         ),
         do: Boards.delete_comment(Params.id(id))
    end)
  end

  def handle_event("add_status_update", %{"health" => health} = params, socket) do
    user = socket.assigns.current_user

    discussion_event(socket, fn page ->
      Boards.add_status_update(page, user, %{"health" => health, "body" => params["body"]})
    end)
  end

  def handle_event("delete_status_update", %{"id" => id}, socket) do
    contents_event(socket, fn page ->
      if Enum.any?(page.status_updates, &(to_string(&1.id) == id)),
        do: Boards.delete_status_update(Params.id(id))
    end)
  end

  def handle_event("add_card_url", params, socket) do
    case socket.assigns do
      %{can_write: true, page: %Page{} = page} ->
        case Boards.add_card_url(page, Map.take(params, ["url", "title"])) do
          {:ok, _} -> {:noreply, socket |> update(:form_key, &(&1 + 1)) |> reload_page()}
          {:error, _} -> {:noreply, put_flash(socket, :error, "That isn't an address I can use.")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_card_url", %{"id" => id}, socket) do
    contents_event(socket, fn page ->
      url = Boards.get_card_url!(id)
      if url.page_id == page.id, do: Boards.delete_card_url(url)
    end)
  end

  def handle_event("set_field", %{"field_id" => id, "value" => value}, socket) do
    board = socket.assigns.fields_board

    case board && Enum.find(board.fields, &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:noreply, socket}

      field ->
        {:noreply, set_field_value(socket, field, value)}
    end
  end

  def handle_event("vote", %{"count" => count}, socket) do
    case socket.assigns do
      %{page: %Page{} = page, current_user: user} when not is_nil(user) ->
        with count when is_integer(count) <- Params.int(count),
             {:ok, _} <- Votes.set(page, user, count) do
          {:noreply, reload_page(socket)}
        else
          nil -> {:noreply, socket}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Putting a page on the board is a second, optional axis: it stays exactly
  # where it is in the wiki tree either way.
  def handle_event("place", %{"column" => column_id}, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         column_id when is_integer(column_id) <- Params.id(column_id),
         {:ok, placed} <- Wiki.place(page, column_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Put “#{placed.title}” on the board.")
       |> reload(placed)}
    else
      {:error, _, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      _ ->
        {:noreply, put_flash(socket, :error, "That page couldn't be put on the board.")}
    end
  end

  def handle_event("unplace", _params, socket) do
    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         {:ok, unplaced} <- Wiki.unplace(page) do
      {:noreply,
       socket
       |> put_flash(:info, "Took it off the board. It is still here.")
       |> reload(unplaced)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be taken off the board.")}
    end
  end

  def handle_event("dismiss_conflict", _params, socket),
    do: {:noreply, assign(socket, conflict: nil)}

  # The AI tools beside the page: open or shut, and they stay so from page to
  # page, each with its own clean panel.
  def handle_event("toggle_page_tools", _params, socket),
    do: {:noreply, assign(socket, page_tools: not socket.assigns.page_tools)}

  # A passage of a page becomes a card: its first line is the title, the rest
  # the description, and the link is written into both ends so neither side
  # has to remember the other.
  def handle_event("card_from_selection", %{"text" => text}, socket) do
    board = Boards.get_board!(socket.assigns.board.id)

    with true <- socket.assigns.can_write,
         %Page{} = page <- socket.assigns.page,
         [column | _] <- board.columns,
         {:ok, card} <-
           Wiki.create_card_from_selection(page, column, text,
             user: socket.assigns.current_user,
             via: "web"
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Made ##{card.id} “#{card.title}” in #{column.name}.")
       |> reload(page)}
    else
      [] -> {:noreply, put_flash(socket, :error, "That board has no lists to put a card in.")}
      _ -> {:noreply, put_flash(socket, :error, "That card couldn't be made.")}
    end
  end

  ## The card contents a page carries --------------------------------------
  #
  # A page holds comments, status updates, a checklist, web links, custom
  # field values and votes in the same tables a card does (see
  # `Slipdock.Boards.Owned`), so these are the card panel's events with the
  # page as the subject. Every one is refused without write access, the way
  # everything else on this view is.

  defp contents_event(socket, fun) do
    if socket.assigns.can_write and socket.assigns.page do
      fun.(socket.assigns.page)
      {:noreply, socket |> update(:form_key, &(&1 + 1)) |> reload_page()}
    else
      {:noreply, socket}
    end
  end

  # The discussion under a page — comments and status updates — wants only
  # comment access (#863); everything else on it, `contents_event/2`'s write.
  defp discussion_event(socket, fun) do
    if socket.assigns.can_comment and socket.assigns.page do
      fun.(socket.assigns.page)
      {:noreply, socket |> update(:form_key, &(&1 + 1)) |> reload_page()}
    else
      {:noreply, socket}
    end
  end

  defp reload_page(socket) do
    case socket.assigns.page do
      %Page{id: id} ->
        assign_page(socket, Wiki.get_page!(id))

      _ ->
        socket
    end
  end

  defp set_field_value(
         %{assigns: %{can_write: true, page: %Page{} = page}} = socket,
         field,
         value
       ) do
    case Fields.set_value(page, field, value) do
      {:ok, _} -> reload_page(socket)
      {:error, message} -> put_flash(socket, :error, message)
    end
  end

  defp set_field_value(socket, _field, _value), do: socket
end
