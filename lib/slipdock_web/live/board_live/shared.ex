defmodule SlipdockWeb.BoardLive.Shared do
  @moduledoc """
  The other end of sharing: what somebody is told about a board that is not
  theirs, and the way out of it.

  The owner's side of a share lives on the board's settings panel, where they
  hand access out and take it back. The person on the receiving end had no
  say and no exit — a board somebody shares with you simply appears on your
  list and stays there. This page is that exit: who shared it, when, on what
  terms, and a Discard button that gives the access back.

  Discarding takes away this person's own grants and nothing else (see
  `Slipdock.Access.discard_board/2`): access held by a group they belong to
  is the group's to give up, so the page says so rather than pretending.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents, only: [relative_time: 1]

  alias Slipdock.{Access, Boards}
  alias Slipdock.Access.Grant
  alias Slipdock.Accounts.User

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    board = Boards.get_board!(id)
    user = socket.assigns.current_user
    perm = Access.board_permission(user, board)

    cond do
      perm == :none ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that board.")
         |> push_navigate(to: ~p"/")}

      perm == :owner ->
        # Yours: sharing it out is the settings panel's job, not this page's.
        {:ok, push_navigate(socket, to: ~p"/boards/#{board}/settings")}

      true ->
        if connected?(socket), do: Boards.subscribe(board.id)
        {:ok, socket |> assign(page_title: "Shared") |> load(board)}
    end
  end

  defp load(socket, board) do
    user = socket.assigns.current_user
    grants = Access.incoming_grants(user, board)

    assign(socket,
      board: board,
      perm: Access.board_permission(user, board),
      grants: grants,
      mine?: Enum.any?(grants, &(&1.user_id == user.id))
    )
  end

  @impl true
  def handle_info({:board_changed, _id}, socket) do
    user = socket.assigns.current_user
    board = Boards.get_board!(socket.assigns.board.id)

    if Access.board_permission(user, board) == :none do
      {:noreply,
       socket
       |> put_flash(:info, "“#{board.name}” is no longer shared with you.")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply, load(socket, board)}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("discard", _params, socket) do
    board = socket.assigns.board

    case Access.discard_board(socket.assigns.current_user, board) do
      {:ok, :none} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "“#{board.name}” is off your boards. Whoever owns it can share it again."
         )
         |> push_navigate(to: ~p"/")}

      {:ok, _left} ->
        # Something that is not theirs to give up still reaches them — a
        # group's grant, or an open support session.
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Gave up your own access. “#{board.name}” still reaches you another way, below."
         )
         |> load(Boards.get_board!(board.id))}

      {:error, :owner} ->
        {:noreply, push_navigate(socket, to: ~p"/boards/#{board}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:boards}
    >
      <:subnav>
        <.link navigate={~p"/boards/#{@board}"} class="font-semibold hover:underline">
          {@board.name}
        </.link>
        <span class="text-base-content/40">›</span>
        <span>Shared</span>
      </:subnav>
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-2xl space-y-6 px-4 py-6 sm:px-6 sm:py-10">
          <div>
            <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Shared with you</h1>
            <p class="mt-1 text-sm text-base-content/60">
              <span class="font-medium">{@board.name}</span>
              belongs to {User.display_name(@board.owner)}. It is on your boards because it was shared with you.
            </p>
          </div>

          <div class="divide-y divide-base-content/10 rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10">
            <div :for={g <- @grants} id={"incoming-#{g.id}"} class="flex items-start gap-3 p-4">
              <span class="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-full bg-base-200">
                <.icon name={grant_icon(g)} class="size-4" />
              </span>
              <div class="min-w-0 flex-1 text-sm">
                <p>{what(g)}</p>
                <p class="mt-0.5 text-xs text-base-content/50">
                  {shared_by(g)}{if g.inserted_at, do: ", #{relative_time(g.inserted_at)}"}
                </p>
              </div>
              <span class={[
                "badge badge-sm shrink-0",
                if(g.level == "write", do: "badge-primary", else: "badge-ghost")
              ]}>
                {if g.level == "write", do: "can edit", else: "read only"}
              </span>
            </div>
            <p :if={@grants == []} class="p-4 text-sm text-base-content/60">
              Nothing names you directly. You can see this board through a support session or a
              board above it; there is nothing here for you to discard.
            </p>
          </div>

          <div class="rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10">
            <h2 class="font-semibold">Discard this board</h2>
            <p class="mt-1 text-sm text-base-content/60">
              It comes off your boards, your switcher and your search, and you stop seeing it
              altogether. Nothing on the board itself changes, and nothing is deleted — {User.display_name(
                @board.owner
              )} can share it with you again.
            </p>
            <p :if={@grants != [] and not @mine?} class="mt-2 text-sm text-warning">
              This board reaches you through a group, not by name. Leaving the group, or the owner
              taking the group's access away, is what stops it — there is nothing here that is
              yours to give up.
            </p>
            <button
              type="button"
              class="btn btn-error btn-sm mt-4"
              phx-click="discard"
              disabled={not @mine?}
              data-confirm={"Discard “#{@board.name}”? You will stop seeing it. The board itself is untouched."}
            >
              <.icon name="hero-x-circle" class="size-4" /> Discard
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp grant_icon(%Grant{} = g) do
    cond do
      Grant.resource_type(g) == :view -> "hero-bookmark"
      Grant.subject_type(g) == :group -> "hero-user-group"
      true -> "hero-user"
    end
  end

  # What this one grant actually hands over, in a sentence.
  defp what(%Grant{} = g) do
    assigns = %{g: g}

    case Grant.resource_type(g) do
      :view ->
        ~H"""
        The saved view <span class="font-medium">{@g.saved_view.name}</span> on this board
        """

      _ ->
        ~H"""
        <span :if={Grant.subject_type(@g) == :group}>
          The whole board, through the group <span class="font-medium">{@g.group.name}</span>
        </span>
        <span :if={Grant.subject_type(@g) == :user}>The whole board</span>
        """
    end
  end

  defp shared_by(%Grant{granted_by: %User{} = by}), do: "shared by #{User.display_name(by)}"
  defp shared_by(_), do: "shared with you"
end
