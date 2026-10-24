defmodule SlipdockWeb.InboundAddressesComponent do
  @moduledoc """
  Your inbound addresses (#1245, `Slipdock.Inbound.Tokens`), each with a copy
  button and a rotate button that asks first.

    * With a `board`: the board's card and page addresses (the kinds
      `Slipdock.Inbound.Dispatcher.live?/1` says are acted on), in a dialog the
      board menu's *Email to this board* opens (the `open` event). The
      addresses are only made when it is opened, so looking at a board never
      makes a token.
    * With `board` nil: the personal Quick Add address, as a section of the
      Account tab.

  Only rendered while inbound mail is on, and for a board only for somebody
  who can write to it; the same addresses are `GET /api/boards/:board/inbound`
  and `slipdock inbound`.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents, only: [modal: 1]

  alias Slipdock.Inbound.Tokens

  @impl true
  def mount(socket), do: {:ok, assign(socket, open: false, addresses: nil, rotated: false)}

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:board, fn -> nil end)
      |> assign_new(:ack, fn -> assigns.current_user.inbound_ack end)

    if is_nil(socket.assigns.board) and is_nil(socket.assigns.addresses),
      do: {:ok, load(socket)},
      else: {:ok, socket}
  end

  @impl true
  def handle_event("open", _params, socket),
    do: {:noreply, socket |> assign(open: true, rotated: false) |> load()}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open: false)}

  def handle_event("ack", params, socket) do
    case Slipdock.Accounts.update_inbound(socket.assigns.current_user, %{
           "inbound_ack" => params["ack"] == "true"
         }) do
      {:ok, user} -> {:noreply, assign(socket, current_user: user, ack: user.inbound_ack)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("rotate", _params, socket) do
    %{current_user: user, board: board} = socket.assigns

    case Tokens.rotate(user, board) do
      {:ok, addresses} -> {:noreply, assign(socket, addresses: addresses, rotated: true)}
      {:error, _} -> {:noreply, assign(socket, addresses: :unavailable)}
    end
  end

  defp load(socket) do
    case Tokens.addresses(socket.assigns.current_user, socket.assigns.board) do
      {:ok, addresses} -> assign(socket, addresses: addresses)
      {:error, _} -> assign(socket, addresses: :unavailable)
    end
  end

  @impl true
  def render(%{board: nil} = assigns) do
    ~H"""
    <section
      id={@id}
      class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
    >
      <h2 class="text-lg font-semibold">Email a card in</h2>
      <p class="text-sm text-base-content/60">
        Mail from your own address to this one becomes a card. Quick Add reads the subject,
        so it can name the board, list, priority and due date (<code>Fix the gate #high due: friday</code>);
        with no board named the card goes to your Quick Add default.
      </p>
      <.addresses id={@id} addresses={@addresses} rotated={@rotated} myself={@myself} />
      <form id={@id <> "-ack-form"} phx-change="ack" phx-target={@myself} class="mt-4">
        <input type="hidden" name="ack" value="false" />
        <label class="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            id={@id <> "-ack"}
            name="ack"
            value="true"
            checked={@ack}
            class="checkbox checkbox-sm"
          /> Email me back a link to each card my mail makes
        </label>
      </form>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.modal
        :if={@open}
        id={@id <> "-modal"}
        size="md"
        on_close={JS.push("close", target: @myself)}
      >
        <div class="p-6">
          <h2 class="text-lg font-semibold">Email to {@board.name}</h2>
          <p class="mt-1 text-sm text-base-content/60">
            These addresses are yours alone: they only take mail from your own address.
            The subject becomes the title, the body the description or the page, and attachments come too.
            On the page address, <code>[Folder] Title</code>
            files the page in a folder (it goes in <code>Inbox</code>
            otherwise), and <code>+ Title</code>
            adds a dated section to that page.
          </p>
          <.addresses id={@id} addresses={@addresses} rotated={@rotated} myself={@myself} />
        </div>
      </.modal>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :addresses, :any, required: true
  attr :rotated, :boolean, required: true
  attr :myself, :any, required: true

  defp addresses(%{addresses: :unavailable} = assigns) do
    ~H"""
    <p id={@id <> "-unavailable"} class="mt-4 text-sm text-base-content/60">
      Email isn't available for this right now.
    </p>
    """
  end

  defp addresses(assigns) do
    ~H"""
    <dl :if={is_map(@addresses)} class="mt-4 space-y-3">
      <div :for={{kind, address} <- ordered(@addresses)}>
        <dt class="text-xs font-medium text-base-content/60">{label(kind)}</dt>
        <dd class="mt-1 flex items-center gap-2">
          <code
            id={"#{@id}-#{kind}"}
            class="min-w-0 flex-1 truncate rounded-lg bg-base-200 px-2 py-1 text-xs"
          >{address}</code>
          <button
            type="button"
            id={"#{@id}-#{kind}-copy"}
            phx-hook="CopyText"
            data-target={"#{@id}-#{kind}"}
            class="btn btn-ghost btn-xs"
          >
            <span data-label>Copy</span>
          </button>
        </dd>
      </div>
    </dl>
    <div class="mt-4 flex items-center gap-3">
      <button
        type="button"
        id={@id <> "-rotate"}
        phx-click="rotate"
        phx-target={@myself}
        data-confirm="Make a new address? Mail to the old one will bounce from now on."
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-arrow-path" class="size-4" /> New address
      </button>
      <span :if={@rotated} id={@id <> "-rotated"} class="text-xs text-success">
        New address made. The old one no longer works.
      </span>
    </div>
    """
  end

  # Only the kinds mail is acted on yet.
  defp ordered(addresses), do: Tokens.offered(addresses)

  defp label(:card), do: "New card"
  defp label(:page), do: "New wiki page"
  defp label(:add), do: "Quick Add, to any board"
end
