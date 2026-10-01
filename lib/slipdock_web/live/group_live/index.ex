defmodule SlipdockWeb.GroupLive.Index do
  use SlipdockWeb, :live_view

  alias Slipdock.Accounts
  alias Slipdock.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Groups", form_key: 0) |> load()}
  end

  defp load(socket), do: assign(socket, groups: Accounts.list_groups(socket.assigns.current_user))

  @impl true
  def handle_event("create", %{"name" => name}, socket) do
    case Accounts.create_group(socket.assigns.current_user, %{"name" => name}) do
      {:ok, _} ->
        {:noreply, socket |> update(:form_key, &(&1 + 1)) |> load()}

      {:error, cs} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Group name #{elem(cs.errors[:name] || {"is invalid", []}, 0)}."
         )}
    end
  end

  def handle_event("rename", %{"group_id" => id, "name" => name}, socket) do
    with {:ok, group} <- owned_group(socket, id),
         {:ok, _} <- Accounts.update_group(group, %{"name" => name}) do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't rename that group.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, group} <- owned_group(socket, id) do
      {:ok, _} = Accounts.delete_group(group)
    end

    {:noreply, load(socket)}
  end

  def handle_event("add_member", %{"group_id" => id, "email" => email}, socket) do
    with {:ok, group} <- owned_group(socket, id),
         {:ok, _} <- Accounts.add_group_member(group, email) do
      {:noreply, socket |> update(:form_key, &(&1 + 1)) |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Enter a valid email address.")}
    end
  end

  def handle_event("remove_member", %{"id" => id, "user_id" => user_id}, socket) do
    with {:ok, group} <- owned_group(socket, id) do
      {:ok, _} = Accounts.remove_group_member(group, Accounts.get_user!(user_id))
    end

    {:noreply, load(socket)}
  end

  defp owned_group(socket, id) do
    group = Accounts.get_group!(id)
    if group.owner_id == socket.assigns.current_user.id, do: {:ok, group}, else: :error
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
      nav_active={:groups}
    >
      <:nav><span class="font-semibold">Groups</span></:nav>
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl space-y-6 px-4 py-6 sm:py-10 sm:px-6">
          <div>
            <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Groups</h1>
            <p class="mt-1 text-sm text-base-content/60">
              Share boards, cards and views with a group instead of one person at a time. People you add by email get an account when they first sign in.
            </p>
          </div>

          <form id={"new-group-#{@form_key}"} phx-submit="create" class="flex gap-2">
            <input
              type="text"
              name="name"
              placeholder="New group name"
              class="input flex-1"
              autocomplete="off"
              required
            />
            <button type="submit" class="btn btn-primary"><.icon name="hero-plus" class="size-4" />
            Create group</button>
          </form>

          <p :if={@groups == []} class="text-sm text-base-content/50">
            You're not in any groups yet.
          </p>

          <div
            :for={group <- @groups}
            id={"group-#{group.id}"}
            class="rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <% mine = group.owner_id == @current_user.id %>
            <div class="flex items-center gap-3">
              <span class="flex size-9 items-center justify-center rounded-full bg-primary/10 text-primary"><.icon
                name="hero-user-group"
                class="size-5"
              /></span>
              <form :if={mine} phx-submit="rename" class="flex flex-1 gap-2">
                <input type="hidden" name="group_id" value={group.id} />
                <input
                  type="text"
                  name="name"
                  value={group.name}
                  class="input input-sm flex-1 font-semibold"
                  aria-label="Group name"
                />
                <button type="submit" class="btn btn-sm">Rename</button>
              </form>
              <div :if={!mine} class="flex-1">
                <p class="font-semibold">{group.name}</p>
                <p class="text-xs text-base-content/50">owned by {User.display_name(group.owner)}</p>
              </div>
              <button
                :if={mine}
                type="button"
                class="btn btn-ghost btn-sm text-error"
                phx-click="delete"
                phx-value-id={group.id}
                data-confirm={"Delete group “#{group.name}”? Anything shared with it will no longer be shared."}
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
            <ul class="mt-3 space-y-1">
              <li
                :for={member <- group.members}
                id={"member-#{group.id}-#{member.id}"}
                class="flex items-center gap-2 rounded-lg px-2 py-1 text-sm hover:bg-base-200/60"
              >
                <span class="flex size-6 items-center justify-center rounded-full bg-base-200 text-2xs font-bold">{User.initials(
                  member
                )}</span>
                <span class="flex-1">{User.display_name(member)}
                <span :if={member.name} class="text-base-content/50">· {member.email}</span></span>
                <button
                  :if={mine}
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="remove_member"
                  phx-value-id={group.id}
                  phx-value-user_id={member.id}
                  title="Remove"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </li>
            </ul>
            <p :if={group.members == []} class="mt-2 px-2 text-xs text-base-content/50">
              No members yet.
            </p>
            <form
              :if={mine}
              id={"add-member-#{group.id}-#{@form_key}"}
              phx-submit="add_member"
              class="mt-3 flex gap-2"
            >
              <input type="hidden" name="group_id" value={group.id} />
              <input
                type="email"
                name="email"
                placeholder="Add member by email"
                class="input input-sm flex-1"
                autocomplete="off"
                required
              />
              <button type="submit" class="btn btn-sm">Add</button>
            </form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
