defmodule SlipdockWeb.BoardLive.CardComponent.LinkEvents do
  @moduledoc """
  The card panel's events on what a card is tied to: its wiki pages, the
  cards it waits on or blocks, its links to other cards, an incident's
  cause, and its subcards and their board.

  `BoardLive.CardComponent.handle_event/3` hands these over once it has
  decided the reader may do them. The clauses run in the component's own
  process, with its socket, as they did when they were its own.
  """
  use SlipdockWeb.WikiLive.Events

  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Access, Boards, Wiki}
  alias Slipdock.Boards.{Board, Card, CardLink}
  alias SlipdockWeb.BoardLive.CardComponent.State
  alias SlipdockWeb.PageLinkHook

  # "Write it up": a page for this card, pinned to it, from a template when
  # the board has one. It opens in the editor rather than being left to find.
  def handle_event("write_up", _params, socket) do
    card = socket.assigns.card

    case Wiki.create_page_from_card(card, user: socket.assigns.current_user, via: "web") do
      {:ok, page} ->
        {:noreply,
         socket
         |> put_flash(:info, "Started #{page.code} for “#{card.title}”.")
         |> push_navigate(to: ~p"/boards/#{page.board_id}/wiki/#{page.slug}/edit")}

      _ ->
        {:noreply, notice(socket, :error, "That page couldn't be started.")}
    end
  end

  # Attaching a page that already exists. "Write it up" is for the document
  # that does not exist yet; most of the time the writing is already there
  # and what is missing is the link to it.
  def handle_event("doc_search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(doc_query: q) |> assign_doc_results()}
  end

  # Into the empty box: the pages changed most lately, before anything is
  # typed (#1302).
  def handle_event("doc_focus", _params, socket) do
    {:noreply, assign_doc_results(socket)}
  end

  def handle_event("attach_doc", %{"page" => page_id}, socket) do
    card = socket.assigns.card

    with {:ok, page} <- readable_page(socket, page_id),
         {:ok, _} <- Wiki.pin(page, {:card, card}) do
      {:noreply,
       socket
       |> notice(:info, "Attached #{page.code} to this card.")
       |> assign(doc_query: "", doc_results: [], doc_pool: nil)
       |> State.assign_pages()}
    else
      _ -> {:noreply, notice(socket, :error, "That page couldn't be attached.")}
    end
  end

  def handle_event("detach_doc", %{"page" => page_id}, socket) do
    card = socket.assigns.card

    with {:ok, page} <- Wiki.find_page(page_id),
         {:ok, _} <- Wiki.unlink(page, {:card, card}) do
      {:noreply, State.assign_pages(socket)}
    else
      _ -> {:noreply, notice(socket, :error, "That page couldn't be detached.")}
    end
  end

  def handle_event("toggle_pin_doc", %{"page" => page_id}, socket) do
    card = socket.assigns.card

    with {:ok, page} <- readable_page(socket, page_id),
         link <- Enum.find(socket.assigns.card_pages, &(&1.page.id == page.id)),
         {:ok, _} <- Wiki.pin(page, {:card, card}, not (link && link.pinned)) do
      {:noreply, State.assign_pages(socket)}
    else
      _ -> {:noreply, notice(socket, :error, "That page couldn't be pinned.")}
    end
  end

  def handle_event("dep_direction", %{"direction" => dir}, socket)
      when dir in ~w(blocked_by blocks) do
    {:noreply, socket |> assign(dep_direction: dir) |> assign_dep_results()}
  end

  def handle_event("dep_search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(dep_query: q) |> assign_dep_results()}
  end

  # The other card may be on another board: the blocked card needs write
  # access, the blocker read.
  def handle_event("add_dependency", %{"id" => id}, socket) do
    %{card: card, dep_direction: direction, current_user: user} = socket.assigns
    other = Boards.Cards.get_card!(id)

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
          Boards.Dependencies.add_dependency(blocked, blocker)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket |> assign(dep_query: "", dep_results: []) |> update(:form_key, &(&1 + 1))}

      {:error, message} ->
        {:noreply, notice(socket, :error, message)}
    end
  end

  # An incident's cause and the check that missed it (#1946): both from the
  # Incident line's form, blank clearing either.
  def handle_event("save_incident", params, socket) do
    incident = params["incident"] || %{}

    attrs = %{
      "caused_by" => incident["caused_by"] || "",
      "missed_by" => incident["missed_by"] || ""
    }

    save_incident(socket, attrs)
  end

  def handle_event("clear_incident", _params, socket),
    do: save_incident(socket, %{"caused_by" => "", "missed_by" => ""})

  def handle_event("link_search", params, socket) do
    kind =
      if Enum.member?(CardLink.kind_keys(), params["kind"]),
        do: params["kind"],
        else: socket.assigns.link_kind

    {:noreply,
     socket |> assign(link_kind: kind, link_query: params["q"] || "") |> assign_link_results()}
  end

  def handle_event("add_link", %{"id" => id}, socket) do
    %{card: card, link_kind: kind, current_user: user} = socket.assigns
    other = Boards.Cards.get_card!(id)

    with true <-
           Access.can_read?(Access.card_permission(user, other)) ||
             {:error, "You can't see that card."},
         {:ok, _} <- Boards.Links.add_link(card, other, kind) do
      {:noreply,
       socket
       |> assign(link_query: "", link_results: [], card: State.fresh(socket, card.id))
       |> update(:form_key, &(&1 + 1))}
    else
      {:error, message} -> {:noreply, notice(socket, :error, message)}
    end
  end

  def handle_event("remove_link", %{"id" => id}, socket) do
    card = socket.assigns.card
    link = Boards.Links.get_link!(id)

    if link.from_id == card.id or link.to_id == card.id do
      {:ok, _} = Boards.Links.remove_link(link)
      {:noreply, assign(socket, card: State.fresh(socket, card.id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_dependency", %{"id" => id}, socket) do
    {:ok, _} =
      Boards.Dependencies.remove_dependency(socket.assigns.card, Boards.Cards.get_card!(id))

    {:noreply, socket}
  end

  def handle_event("pick_template", _, socket) do
    {:noreply, update(socket, :picking_template, &(!&1))}
  end

  # Only a template the reader can see: the built-ins and their own.
  def handle_event("create_sub_board", %{"template" => id}, socket) do
    with {:ok, template} <- Boards.Templates.find_template(socket.assigns.current_user, id),
         {:ok, _} <- Boards.create_sub_board(socket.assigns.card, template) do
      {:noreply, assign(socket, picking_template: false)}
    else
      {:error, :not_found} -> {:noreply, notice(socket, :error, "That template has gone.")}
      {:error, message} -> {:noreply, notice(socket, :error, message)}
    end
  end

  def handle_event("delete_sub_board", _, socket) do
    case Boards.delete_sub_board(socket.assigns.card) do
      {:ok, _} -> {:noreply, socket}
      {:error, message} -> {:noreply, notice(socket, :error, message)}
    end
  end

  # Only into a list on the open card's own subcards board.
  def handle_event("quick_add_subcard", %{"column_id" => column_id, "title" => title}, socket) do
    column =
      case socket.assigns.card do
        %Card{sub_board: %Board{id: sub_id}} ->
          Boards.Columns.get_board_column(sub_id, column_id)

        _ ->
          nil
      end

    if column && String.trim(title) != "" do
      {:ok, _} = Boards.Cards.create_card(column, %{"title" => String.trim(title)})
    end

    {:noreply, update(socket, :form_key, &(&1 + 1))}
  end

  def handle_event("toggle_subcard", %{"id" => id}, socket) do
    card = Boards.Cards.get_card!(id)

    if socket.assigns.card && card.board_id == socket.assigns.card.sub_board.id do
      Boards.Cards.toggle_completed(card)
    end

    {:noreply, socket}
  end

  defp save_incident(socket, attrs) do
    with {:ok, card} <- State.writable(socket),
         {:ok, card} <- Boards.Cards.update_card(card, attrs, by: socket.assigns.current_user) do
      {:noreply,
       socket
       |> assign(card: State.fresh(socket, card.id))
       |> assign(card_incident: State.incident_view(card, socket.assigns.current_user))
       |> assign(incident_error: nil)}
    else
      :error ->
        {:noreply, assign(socket, incident_error: "You have read-only access to that card.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, incident_error: incident_error(cs))}
    end
  end

  defp incident_error(cs) do
    Enum.map_join(cs.errors, " ", fn
      {:missed_by, {message, _}} -> "Missed by " <> message <> "."
      {_field, {message, _}} -> message
    end)
  end

  # Pages not already on the card, found the way the `[[` picker and the
  # quick switcher find them (#1302): by title, alias, folder or code, the
  # most recently changed first while nothing is typed, this vault's before
  # the user's other vaults' (#1303). Names only: finding
  # the page you mean is a different job from searching its prose, which
  # `/search` does by meaning. The pages are gathered once, when the box is
  # first used, and each keystroke scores them in memory.
  defp assign_doc_results(socket) do
    %{board: board, current_user: user, doc_query: query} = socket.assigns
    pool = socket.assigns.doc_pool || Wiki.Switcher.linkable_pool(user, board)
    attached = MapSet.new(socket.assigns.card_pages, & &1.page.id)

    results =
      pool
      |> Enum.reject(&MapSet.member?(attached, &1.id))
      |> Wiki.Switcher.search(query || "", 8)
      |> Enum.map(&PageLinkHook.row(&1, board, pool))

    assign(socket, doc_pool: pool, doc_results: results)
  end

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
      |> Boards.Links.search_cards_across(q, [card.id | linked])
      |> Enum.sort_by(&(&1.board_id != card.board_id))

    assign(socket, dep_results: results)
  end

  defp assign_dep_results(socket), do: assign(socket, dep_results: [])

  # Cards on any board the user can open, minus this card and those already linked.
  defp assign_link_results(%{assigns: %{card: %Card{} = card, link_query: q}} = socket)
       when q != "" do
    linked = Enum.map(card.links_out, & &1.to_id) ++ Enum.map(card.links_in, & &1.from_id)

    assign(socket,
      link_results:
        Boards.Links.search_cards_across(searchable_root_ids(socket), q, [card.id | linked])
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
end
