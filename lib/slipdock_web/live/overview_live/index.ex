defmodule SlipdockWeb.OverviewLive.Index do
  @moduledoc """
  What this server is being used for, at a glance: how many people, how many
  of them are active, and what each of them has made and is storing. Admins
  only, and read-only — changing anybody's standing is on the Users page.

  The counting is `Slipdock.Overview`'s; this page only lays it out and lets
  the table be sorted by any of its columns (`?sort=`).
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Overview, Quota}
  alias Slipdock.Accounts.User

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Overview")}

  @impl true
  def handle_params(params, _uri, socket) do
    sort = sort(params["sort"])
    {:noreply, socket |> assign(sort: sort) |> assign(Overview.overview(sort: sort))}
  end

  defp sort(value), do: Enum.find(Overview.sorts(), :storage, &(Atom.to_string(&1) == value))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      waiting_count={@waiting_count}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:overview}
    >
      <:nav><span class="font-semibold">Overview</span></:nav>

      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-5xl space-y-6 p-6">
          <section id="overview-totals" class="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <.tile label="Accounts" value={@totals.users}>
              {@totals.admins} admin · {@totals.disabled} disabled
            </.tile>
            <.tile label="Active, 7 days" value={@totals.active_7d}>
              {@totals.active_30d} in 30 days · {@totals.never_seen} never
            </.tile>
            <.tile label="Joined, 7 days" value={@totals.joined_7d}>
              {@totals.joined_30d} in 30 days
            </.tile>
            <.tile label="Storage" value={Quota.humanise_bytes(@totals.storage)}>
              {@totals.files} files
            </.tile>
            <.tile label="Boards" value={@totals.boards} />
            <.tile label="Lists" value={@totals.lists} />
            <.tile label="Cards" value={@totals.cards} />
            <.tile label="Wiki pages" value={@totals.pages} />
          </section>

          <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
            <h2 class="text-lg font-semibold">People</h2>
            <p class="mt-1 text-sm text-base-content/60">
              What each person owns, sub-boards included, counted the way their limits count it.
              Last active is the later of their last sign-in and the last use of one of their API
              tokens. To change anybody's standing, go to <.link navigate={~p"/users"} class="link">Users</.link>.
            </p>

            <div class="mt-4 overflow-x-auto">
              <table id="overview-people" class="table table-sm">
                <thead>
                  <tr>
                    <.sort_th sort={@sort} key={:email}>Who</.sort_th>
                    <.sort_th sort={@sort} key={:signed_up}>Signed up</.sort_th>
                    <.sort_th sort={@sort} key={:last_active}>Last active</.sort_th>
                    <.sort_th sort={@sort} key={:boards} numeric>Boards</.sort_th>
                    <.sort_th sort={@sort} key={:lists} numeric>Lists</.sort_th>
                    <.sort_th sort={@sort} key={:cards} numeric>Cards</.sort_th>
                    <.sort_th sort={@sort} key={:pages} numeric>Pages</.sort_th>
                    <.sort_th sort={@sort} key={:files} numeric>Files</.sort_th>
                    <.sort_th sort={@sort} key={:storage} numeric>Storage</.sort_th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={person <- @people}
                    id={"overview-user-#{person.user.id}"}
                    class={person.user.disabled_at && "opacity-50"}
                  >
                    <td>
                      <div class="font-medium">{User.display_name(person.user)}</div>
                      <div class="text-xs text-base-content/50">{person.user.email}</div>
                      <div class="mt-1 flex gap-1">
                        <span :if={person.user.admin} class="badge badge-xs badge-primary">admin</span>
                        <span :if={person.user.disabled_at} class="badge badge-xs">disabled</span>
                      </div>
                    </td>
                    <td class="text-xs text-base-content/60">{date(person.signed_up_at)}</td>
                    <td class="text-xs text-base-content/60">
                      <div>{date(person.last_active_at) || "never"}</div>
                      <div :if={person.last_api_at} class="text-base-content/40">
                        API {date(person.last_api_at)}
                      </div>
                    </td>
                    <td class="text-right tabular-nums">{person.boards}</td>
                    <td class="text-right tabular-nums">{person.lists}</td>
                    <td class="text-right tabular-nums">{person.cards}</td>
                    <td class="text-right tabular-nums">{person.pages}</td>
                    <td class="text-right tabular-nums">{person.files}</td>
                    <td class="text-right tabular-nums">{Quota.humanise_bytes(person.storage)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  slot :inner_block

  defp tile(assigns) do
    ~H"""
    <div class="rounded-2xl bg-base-100 p-4 shadow-sm ring-1 ring-base-content/10">
      <div class="text-xs text-base-content/60">{@label}</div>
      <div class="mt-1 text-2xl font-semibold tabular-nums">{@value}</div>
      <div :if={@inner_block != []} class="mt-1 text-xs text-base-content/50">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :sort, :atom, required: true
  attr :key, :atom, required: true
  attr :numeric, :boolean, default: false
  slot :inner_block, required: true

  defp sort_th(assigns) do
    ~H"""
    <th
      class={@numeric && "text-right"}
      aria-sort={@sort == @key && if(@key == :email, do: "ascending", else: "descending")}
    >
      <.link
        patch={~p"/overview?sort=#{@key}"}
        class={["hover:underline", @sort == @key && "text-primary"]}
      >
        {render_slot(@inner_block)}
      </.link>
    </th>
    """
  end

  defp date(nil), do: nil
  defp date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")
end
