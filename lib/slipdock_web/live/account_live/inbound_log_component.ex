defmodule SlipdockWeb.AccountLive.InboundLogComponent do
  @moduledoc """
  The account's Email Log tab (#1242, its own tab since #1290): your last 50 messages to
  Slipdock's inbound addresses, and what came of each. When someone says "I
  emailed it and nothing happened", this is where the answer is: refused and
  why, ignored as automatic, or what it made. Only there while inbound mail
  is on (`Slipdock.Inbound.enabled?/0`: the tab is hidden and its URL a 404
  otherwise); the same list is
  `GET /api/inbound/log` and `slipdock inbound log`.
  """
  use SlipdockWeb, :live_component

  alias Slipdock.Inbound

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if Map.has_key?(socket.assigns, :emails),
      do: {:ok, socket},
      else: {:ok, assign(socket, emails: Inbound.recent(socket.assigns.current_user))}
  end

  @impl true
  def handle_event("refresh", _params, socket),
    do: {:noreply, assign(socket, emails: Inbound.recent(socket.assigns.current_user))}

  defp relative_time(dt), do: SlipdockWeb.SlipdockComponents.relative_time(dt)

  defp kind_label("card"), do: "Card"
  defp kind_label("page"), do: "Page"
  defp kind_label("add"), do: "Quick add"
  defp kind_label("reply"), do: "Reply"
  defp kind_label(_), do: "Unknown"

  defp outcome_class("accepted"), do: "badge-success"
  defp outcome_class("rejected"), do: "badge-error"
  defp outcome_class(_), do: "badge-ghost"

  defp outcome_label("accepted"), do: "Accepted"
  defp outcome_label("rejected"), do: "Bounced"
  defp outcome_label("dropped"), do: "Ignored"
  defp outcome_label(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id="inbound-log"
      class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <h2 class="text-lg font-semibold">Inbound email</h2>
          <p class="text-sm text-base-content/60">
            Your last 50 messages to Slipdock's addresses at {Inbound.domain()}, and what came of each.
          </p>
        </div>
        <button
          type="button"
          id="inbound-log-refresh"
          phx-click="refresh"
          phx-target={@myself}
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Refresh
        </button>
      </div>

      <p :if={@emails == []} id="inbound-log-empty" class="mt-4 text-sm text-base-content/60">
        Nothing yet. Mail you send to a Slipdock address shows here, including any that bounced.
      </p>

      <ul :if={@emails != []} id="inbound-log-list" class="mt-4 divide-y divide-base-content/10">
        <li :for={email <- @emails} id={"inbound-#{email.id}"} class="py-3 text-sm">
          <div class="flex items-center gap-2">
            <span class={["badge badge-sm", outcome_class(email.outcome)]}>
              {outcome_label(email.outcome)}
            </span>
            <span class="text-xs text-base-content/60">{kind_label(email.kind)}</span>
            <span class="ml-auto text-xs text-base-content/50" title={email.inserted_at}>
              {relative_time(email.inserted_at)}
            </span>
          </div>
          <p class="mt-1 truncate font-medium">{email.subject || "(no subject)"}</p>
          <p class="truncate text-xs text-base-content/50">to {email.recipient}</p>
          <p :if={email.reason} class="mt-1 text-xs text-base-content/70">{email.reason}</p>
          <.link
            :if={Inbound.created_path(email)}
            navigate={Inbound.created_path(email)}
            class="link mt-1 inline-block text-xs"
          >
            Open what it made
          </.link>
        </li>
      </ul>
    </section>
    """
  end
end
