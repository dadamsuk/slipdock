defmodule SlipdockWeb.BoardLive.CardComponent.State do
  @moduledoc """
  What the card panel holds about its card: taking the card the board hands
  over and working out what the reader may do with it, the pages, jobs and
  figures shown beside it, and a fresh copy of it after a change.

  Every function takes the component's socket, and those that change it
  return it.
  """
  import Phoenix.Component, only: [assign: 2, to_form: 1]
  import Phoenix.LiveView, only: [cancel_upload: 3]
  import SlipdockWeb.BoardLive.Items, only: [card_access: 5, with_state: 2]

  alias Slipdock.{Access, Boards, Runners, Wiki}
  alias Slipdock.Boards.Card

  @uploads [:attachment, :desc_image, :comment_image]

  # The board loaded the card afresh (it opened, or something changed). A
  # different card starts the panel over; the same one keeps what is being
  # typed into its pickers.
  @doc false
  def take(socket, given) do
    %{card: current, current_user: user} = socket.assigns

    same = match?(%Card{id: id} when id == given.id, current)
    {readable, level, perm} = access(socket, given)
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
            doc_pool: nil,
            picking_template: false,
            reveal_sections: false,
            editing_description: false,
            editing_handoff: false,
            handoff_form: nil,
            handoff_draft: nil,
            wait_answers: %{},
            wait_suggest: %{},
            asking: nil,
            repeat: nil,
            # A notice meant for the card the panel moves to (Duplicate's
            # "Duplicated as #N") is kept; any other is the last card's.
            panel_notice:
              if(socket.assigns.notice_for == given.id, do: socket.assigns.panel_notice),
            notice_for: nil
          )

    if readable do
      socket
      |> assign(
        given: given,
        card: Access.hide_unreadable_dependencies(user, given),
        card_form: to_form(Boards.Cards.change_card(given)),
        can_write: writable,
        # Adding a card to the board (a duplicate) needs write on the board
        # itself, not only on this card.
        can_add: Access.can_write?(perm),
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
        can_add: false,
        can_comment: false,
        can_share: false
      )
    end
  end

  # Whether the reader may see `given` now, at what level, and their level
  # on the board.
  defp access(socket, given) do
    %{board: board, current_user: user, swim: config, swim_view: view} = socket.assigns
    perm = Access.board_permission(user, board)

    {readable, level} =
      if given.board_id == board.id,
        do: card_access(given, user, perm == :view, config, view),
        else: {false, :none}

    {readable, level, perm}
  end

  # What the reader may do with the open card now, and nothing at all once
  # they may not see it. `update/2` takes a card only when the board hands
  # the panel a changed one; a told lowering of the grant asks this through
  # `access_changed` (#2997), and a lowering the board is never told of
  # hands over nothing, so every event (and every finished upload) asks
  # again before it is let through (#2771).
  @doc false
  def assign_access(%{assigns: %{given: %Card{} = given, card: %Card{}}} = socket) do
    case access(socket, given) do
      {true, level, perm} ->
        writable = Access.can_write?(level)

        assign(socket,
          can_write: writable,
          can_add: Access.can_write?(perm),
          can_comment: Access.can_comment?(level),
          can_share: perm == :owner or writable
        )

      {false, _level, _perm} ->
        assign(socket,
          card: nil,
          card_form: nil,
          can_write: false,
          can_add: false,
          can_comment: false,
          can_share: false
        )
    end
  end

  def assign_access(socket), do: socket

  # The wiki pages that talk about this card, pinned first (see
  # `Slipdock.Wiki.Links`), and who it is shared with.
  @doc false
  def assign_pages(%{assigns: %{card: %Card{} = card}} = socket) do
    assign(socket,
      card_pages: Wiki.pages_for_card(card, socket.assigns.current_user),
      card_grants: if(socket.assigns.can_share, do: Access.list_grants(card), else: []),
      handoff_history: Boards.Handoffs.handoff_history(card),
      # Where it has shipped (#1134); empty unless delivery metrics are on.
      card_shipped: Slipdock.Deployments.shipped(card),
      # Where its latest deploy attempt failed (#2820), until one succeeds.
      card_deploy_failed: Slipdock.Deployments.deploy_failed(card),
      # Merged, awaiting release, or released (#2834); nil unless batched.
      card_release: Slipdock.Releases.state(card),
      # Merged, and no deploy names it after the board's minutes (#2819).
      card_not_shipped: Slipdock.Deployments.NotShipped.for_card(card),
      # How many questions the card has asked, shown on its open wait (#1114).
      wait_count: if(Card.open_wait(card), do: Boards.Waits.wait_count(card), else: 0),
      # The questions asked before, with their answers (#1220).
      wait_history:
        card |> Boards.Waits.list_waits() |> Enum.reject(&Slipdock.Boards.Wait.open?/1),
      # Both ends of an incident (#1946): its cause, and what this card caused.
      card_incident: incident_view(card, socket.assigns.current_user),
      # A refusal from the Incident line, shown in it rather than as a toast (UX-29).
      incident_error: nil
    )
    |> assign_jobs()
  end

  def assign_pages(socket), do: socket

  # The cause it names, `hidden` when the reader can't read it, and the
  # incidents naming this card that the reader can read.
  @doc false
  def incident_view(card, user) do
    cause =
      case Slipdock.Incidents.cause(card) do
        nil ->
          nil

        cause ->
          if Slipdock.Incidents.readable?(cause, user),
            do: cause,
            else: %{id: cause.id, hidden: true}
      end

    %{cause: cause, caused: Slipdock.Incidents.caused_readable(card, user)}
  end

  # The jobs rules have sent this card to runners, newest first.
  @doc false
  def assign_jobs(%{assigns: %{card: %Card{} = card}} = socket) do
    jobs = Runners.list_card_jobs(card.id, 5)

    assign(socket,
      card_jobs: jobs,
      # The runner loop on it, its own job's or an epic's working it (#2899).
      card_loop: Slipdock.CardState.loop_of(card, jobs),
      # Who created it and who changed it last (#2028), refreshed with the
      # card, since every change re-renders it.
      card_authors: Slipdock.CardAuthors.for_card(card),
      # Its lead time and what its jobs spent (#1954), on a card a runner
      # has worked or an epic.
      card_lead_time: Slipdock.LeadTime.worked_brief(card),
      # How many open findings it has (W-2310 §Findings, #1940).
      card_findings: Slipdock.Findings.open_count(card),
      # The lists, waits and jobs it has been through, on one axis (#1131).
      card_timeline: Slipdock.CardTimeline.for_card(card)
    )
  end

  def assign_jobs(socket), do: socket

  # An in-flight upload belongs to the card that was open when it started.
  defp cancel_all_uploads(socket) do
    Enum.reduce(@uploads, socket, fn name, socket ->
      Enum.reduce(socket.assigns.uploads[name].entries, socket, &cancel_upload(&2, name, &1.ref))
    end)
  end

  # The open card, fresh, when the reader may change it.
  @doc false
  def writable(%{assigns: %{can_write: true, card: %Card{id: id}}}),
    do: {:ok, Boards.Cards.get_card!(id)}

  def writable(_socket), do: :error

  # Put a fresh copy of the card in front of the reader.
  # The person at the page, as a change's `Slipdock.Actor`.
  @doc false
  def me(socket), do: Slipdock.Actor.web(socket.assigns.current_user)
  @doc false
  def by_me(socket), do: [by: socket.assigns.current_user, actor: me(socket)]

  @doc false
  def reload(socket), do: assign(socket, card: fresh(socket, socket.assigns.card.id))

  # The card as this reader may see it: dependencies on boards they can't
  # read are hidden (see `Access.hide_unreadable_dependencies/3`).
  @doc false
  def fresh(socket, id) do
    %{current_user: user, board: board} = socket.assigns
    Access.hide_unreadable_dependencies(user, with_state(Boards.Cards.get_card!(id), board))
  end

  # The item the shared sections (`BoardLive.ItemEvents`) act on is the card.
  @doc false
  def with_item(socket), do: assign(socket, item: socket.assigns.card)
end
