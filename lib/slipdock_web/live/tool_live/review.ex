defmodule SlipdockWeb.ToolLive.Review do
  @moduledoc """
  The admin queue for listing Tools (#964): each version an owner has asked
  to list for everyone on the server, to read in full (on its Tool page) and
  approve or decline. Approval is for that version only; a newer one comes
  back here before anybody but its owner and grantees sees it.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Repo, Tools}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Tool listings") |> load()}
  end

  defp load(socket),
    do: assign(socket, queue: Tools.listing_queue(), listed: Tools.list_listed())

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    version = Repo.get!(Tools.Version, id)

    case Tools.approve_listing(socket.assigns.current_user, version) do
      {:ok, v} ->
        {:noreply, socket |> put_flash(:info, "Listed #{v.version}.") |> load()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("decline", %{"version_id" => id} = params, socket) do
    version = Repo.get!(Tools.Version, id)

    case Tools.decline_listing(socket.assigns.current_user, version, params["reason"]) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Declined.") |> load()}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("unlist", %{"id" => id}, socket) do
    tool = Repo.get!(Tools.Tool, id)
    {:ok, _} = Tools.unlist(socket.assigns.current_user, tool)
    {:noreply, socket |> put_flash(:info, "#{tool.name} is no longer listed.") |> load()}
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
    >
      <:nav>
        <span class="font-semibold">Tool listings</span>
      </:nav>
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-4xl space-y-8 px-4 py-6 sm:px-6 sm:py-10">
          <div>
            <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Tool listings</h1>
            <p class="mt-1 max-w-xl text-sm text-base-content/60">
              A listed Tool can be seen and installed by everyone on this server, and its skills
              run in their assistants with their access. Read each version in full — its page shows
              every skill file — before approving it. Approval covers that version only.
            </p>
          </div>

          <section id="listing-queue">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
              Waiting
            </h2>
            <p :if={@queue == []} class="mt-2 text-sm text-base-content/50">Nothing waiting.</p>
            <ul class="mt-2 space-y-3">
              <li
                :for={v <- @queue}
                id={"listing-#{v.id}"}
                class="rounded-2xl bg-base-100 p-4 shadow-sm ring-1 ring-base-content/10"
              >
                <p class="font-semibold">
                  <.link navigate={~p"/tools/#{v.tool.slug}?version=#{v.version}"} class="link">
                    {v.tool.name} {v.version}
                  </.link>
                </p>
                <p class="text-sm text-base-content/70">{v.tool.summary}</p>
                <p class="mt-1 text-xs text-base-content/50">
                  by {v.tool.owner.name || v.tool.owner.email} · sha
                  <code>{String.slice(v.sha, 0, 12)}</code>
                </p>
                <div class="mt-3 flex flex-wrap items-center gap-2">
                  <button class="btn btn-primary btn-sm" phx-click="approve" phx-value-id={v.id}>
                    Approve {v.version}
                  </button>
                  <form id={"decline-#{v.id}"} phx-submit="decline" class="flex gap-2">
                    <input type="hidden" name="version_id" value={v.id} />
                    <input
                      type="text"
                      name="reason"
                      placeholder="Why (the owner sees this)"
                      class="input input-sm w-64"
                    />
                    <button class="btn btn-ghost btn-sm">Decline</button>
                  </form>
                </div>
              </li>
            </ul>
          </section>

          <section id="listing-listed">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
              Listed now
            </h2>
            <p :if={@listed == []} class="mt-2 text-sm text-base-content/50">None.</p>
            <ul class="mt-2 space-y-2 text-sm">
              <li :for={t <- @listed} id={"listed-#{t.id}"} class="flex items-center gap-2">
                <.link navigate={~p"/tools/#{t.slug}"} class="link">{t.name}</.link>
                <span class="text-base-content/50">{Tools.listed_version(t).version}</span>
                <button class="btn btn-ghost btn-xs" phx-click="unlist" phx-value-id={t.id}>Unlist</button>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
