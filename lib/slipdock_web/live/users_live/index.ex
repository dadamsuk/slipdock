defmodule SlipdockWeb.UsersLive.Index do
  @moduledoc """
  The people who use this server, and whoever is waiting to be let in. The
  settings they live under are on their own page, at `/config`.

  The part that matters is what it **refuses**: the last admin cannot be
  demoted, disabled or deleted, closing an account says exactly what it will
  take with it first, and support access always tells the person being looked
  at, with the reason the admin gave.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Accounts, Quota, Settings}
  alias SlipdockWeb.Params

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Users") |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, tab: tab(socket))}

  defp tab(%{assigns: %{live_action: action}}), do: action

  defp load(socket) do
    users = Accounts.list_users()

    assign(socket,
      settings: Settings.get(),
      users: users,
      usage: Quota.usage(Enum.map(users, & &1.id)),
      support: Accounts.live_support_sessions(),
      deleting: nil,
      deleting_preview: nil,
      requests: Accounts.list_signup_requests()
    )
  end

  ## People

  @impl true
  def handle_event("promote", %{"id" => id}, socket),
    do: {:noreply, standing(socket, id, :promote)}

  def handle_event("demote", %{"id" => id}, socket), do: {:noreply, standing(socket, id, :demote)}

  def handle_event("disable", %{"id" => id}, socket),
    do: {:noreply, standing(socket, id, :disable)}

  def handle_event("enable", %{"id" => id}, socket), do: {:noreply, standing(socket, id, :enable)}

  def handle_event("set-limit", %{"user_id" => id, "limit" => limit}, socket) do
    with_user(socket, id, fn user ->
      value = if String.trim(limit) == "", do: nil, else: limit

      case Accounts.update_standing(user, %{"card_limit_override" => value}) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Saved.") |> load()}
        {:error, _} -> {:noreply, put_flash(socket, :error, "That isn't a number of cards.")}
      end
    end)
  end

  # Paid up to a date, which is what takes somebody off the free tier and off
  # the trial clock. Blank puts them back on it.
  def handle_event("set-paid-until", %{"user_id" => id, "paid_until" => until}, socket) do
    with_user(socket, id, fn user ->
      value = if String.trim(until) == "", do: nil, else: until

      case Accounts.update_standing(user, %{"paid_until" => value}) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Saved.") |> load()}
        {:error, _} -> {:noreply, put_flash(socket, :error, "That isn't a date.")}
      end
    end)
  end

  ## Closing an account

  def handle_event("confirm-delete", %{"user_id" => id}, socket) do
    with_user(socket, id, fn user ->
      {:noreply,
       assign(socket, deleting: user, deleting_preview: Accounts.deletion_preview(user))}
    end)
  end

  def handle_event("cancel-delete", _params, socket),
    do: {:noreply, assign(socket, deleting: nil, deleting_preview: nil)}

  def handle_event("delete", %{"user_id" => id, "email" => typed}, socket) do
    with_user(socket, id, &delete_user(socket, &1, typed))
  end

  ## Support access

  def handle_event("support", %{"user_id" => id, "reason" => reason}, socket) do
    with_user(socket, id, &open_support(socket, &1, reason))
  end

  def handle_event("end-support", %{"id" => id}, socket) do
    case Accounts.get_support_session(Params.id(id)) do
      nil ->
        gone(socket)

      session ->
        Accounts.end_support_session(session)
        {:noreply, socket |> put_flash(:info, "Ended.") |> load()}
    end
  end

  ## Signups

  def handle_event("approve", %{"id" => id}, socket) do
    with %{} = request <- Accounts.get_signup_request(Params.id(id)),
         {:ok, user} <-
           Accounts.approve_signup(request, socket.assigns.current_user, &url(~p"/login/#{&1}")) do
      {:noreply, socket |> put_flash(:info, "#{user.email} can sign in now.") |> load()}
    else
      nil -> gone(socket)
      {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't approve that.")}
    end
  end

  def handle_event("reject", %{"id" => id}, socket) do
    case Accounts.get_signup_request(Params.id(id)) do
      nil ->
        gone(socket)

      request ->
        Accounts.reject_signup(request, socket.assigns.current_user)
        {:noreply, socket |> put_flash(:info, "Turned down.") |> load()}
    end
  end

  ## Internals

  # The id comes from the page, which may be stale or hand-made: somebody
  # already deleted, or not an id at all, is a flash rather than a crash.
  defp with_user(socket, id, fun) do
    case Accounts.get_user(Params.id(id)) do
      nil -> gone(socket)
      user -> fun.(user)
    end
  end

  defp gone(socket),
    do: {:noreply, socket |> put_flash(:error, "That isn't there any more.") |> load()}

  defp delete_user(socket, user, typed) do
    cond do
      String.trim(typed) != user.email ->
        {:noreply,
         put_flash(socket, :error, "Type the address exactly to confirm — this cannot be undone.")}

      true ->
        case Accounts.delete_user(user) do
          {:ok, %{email: email, handed_over: handed}} ->
            {:noreply,
             socket
             |> assign(deleting: nil, deleting_preview: nil)
             |> put_flash(
               :info,
               "#{email} is gone." <>
                 if(handed == [],
                   do: "",
                   else: " #{length(handed)} shared board(s) were handed on."
                 )
             )
             |> load()}

          {:error, :last_admin} ->
            {:noreply, put_flash(socket, :error, "That is the only admin.")}
        end
    end
  end

  defp open_support(socket, subject, reason) do
    case Accounts.open_support_session(socket.assigns.current_user, subject, reason) do
      {:ok, session} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "You can read #{subject.email}'s boards until #{session.expires_at}. They have " <>
             "been told, with the reason you gave."
         )
         |> load()}

      {:error, :self} ->
        {:noreply, put_flash(socket, :error, "You can already see your own boards.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Say what the access is for, in a few words.")}
    end
  end

  defp standing(socket, id, action) do
    case Accounts.get_user(Params.id(id)) do
      nil -> put_flash(socket, :error, "That isn't there any more.") |> load()
      user -> standing_change(socket, user, action)
    end
  end

  defp standing_change(socket, user, action) do
    result =
      case action do
        :promote -> Accounts.promote(user)
        :demote -> Accounts.demote(user)
        :disable -> Accounts.disable(user)
        :enable -> Accounts.enable(user)
      end

    case result do
      {:ok, _} ->
        load(socket)

      {:error, :last_admin} ->
        put_flash(
          socket,
          :error,
          "#{user.email} is the only admin. Make somebody else an admin first, or " <>
            "there would be nobody left who can change any of this."
        )

      {:error, _} ->
        put_flash(socket, :error, "Couldn't do that.")
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
      nav_active={:users}
    >
      <:nav><span class="font-semibold">Users</span></:nav>

      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl space-y-6 p-6">
          <div :if={@settings.signup_mode == :approval} role="tablist" class="tabs tabs-box">
            <.link patch={~p"/users"} role="tab" class={["tab", @tab == :index && "tab-active"]}>
              People
            </.link>
            <.link
              patch={~p"/users/signups"}
              role="tab"
              class={["tab", @tab == :signups && "tab-active"]}
            >
              Requests
              <span :if={@requests != []} class="badge badge-sm badge-warning ml-1">
                {length(@requests)}
              </span>
            </.link>
          </div>

          <.people_tab :if={@tab == :index} {assigns} />
          <.signups_tab :if={@tab == :signups} {assigns} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp people_tab(assigns) do
    ~H"""
    <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
      <h2 class="text-lg font-semibold">People</h2>
      <p class="mt-1 text-sm text-base-content/60">
        {length(@users)} {if length(@users) == 1, do: "account", else: "accounts"}.
        Disabling is reversible and ends their sessions and tokens at once — reach for it
        first. Closing an account removes them and their work for good, and is there because
        somebody paying for a service is entitled to ask for it; it says exactly what it will
        take with it before it does anything.
      </p>

      <div :if={@support != []} class="mt-4 rounded-xl bg-warning/10 p-4">
        <h3 class="text-sm font-medium">Support access in force</h3>
        <ul class="mt-2 space-y-1 text-sm">
          <li :for={session <- @support} class="flex items-center justify-between gap-3">
            <span>
              {Accounts.User.display_name(session.admin)} can read {Accounts.User.display_name(
                session.subject
              )}&#39;s boards until {session.expires_at} — “{session.reason}”
            </span>
            <button phx-click="end-support" phx-value-id={session.id} class="btn btn-ghost btn-xs">
              End now
            </button>
          </li>
        </ul>
      </div>

      <div :if={@deleting} class="mt-4 rounded-xl bg-error/10 p-4">
        <h3 class="text-sm font-medium">Close {@deleting.email}&#39;s account?</h3>
        <p class="mt-1 text-sm text-base-content/70">
          This cannot be undone. Use <span class="font-medium">Disable</span>
          instead unless they have actually asked to be removed — a disabled account keeps
          everything and can be turned back on.
        </p>

        <ul class="mt-3 space-y-1 text-sm">
          <li>
            <span class="font-medium">{@deleting_preview.cards_deleted}</span> cards on boards only
            they can see will be deleted.
          </li>
          <li :if={@deleting_preview.boards_deleted != []}>
            Deleted with them: {Enum.join(@deleting_preview.boards_deleted, ", ")}
          </li>
          <li :if={@deleting_preview.boards_handed_over != []}>
            Handed to whoever else works on them: {Enum.map_join(
              @deleting_preview.boards_handed_over,
              ", ",
              &"#{&1.name} → #{&1.to}"
            )}
          </li>
          <li class="text-base-content/60">
            Status updates and page history they wrote on other people's boards stay, with no
            author.
          </li>
        </ul>

        <form phx-submit="delete" class="mt-3 flex items-end gap-2">
          <input type="hidden" name="user_id" value={@deleting.id} />
          <div class="flex-1">
            <.input
              name="email"
              value=""
              type="text"
              label={"Type #{@deleting.email} to confirm"}
              autocomplete="off"
            />
          </div>
          <button type="submit" class="btn btn-error mb-1">Close the account</button>
          <button type="button" phx-click="cancel-delete" class="btn btn-ghost mb-1">Cancel</button>
        </form>
      </div>

      <div class="mt-4 overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Who</th>
              <th>Came from</th>
              <th>Last seen</th>
              <th>Using</th>
              <th>Paid up to</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={user <- @users} class={user.disabled_at && "opacity-50"}>
              <td>
                <div class="font-medium">{Accounts.User.display_name(user)}</div>
                <div class="text-xs text-base-content/50">{user.email}</div>
                <div class="mt-1 flex gap-1">
                  <span :if={user.admin} class="badge badge-xs badge-primary">admin</span>
                  <span :if={user.disabled_at} class="badge badge-xs">disabled</span>
                </div>
              </td>
              <td class="text-xs text-base-content/60">
                {if user.invited_at, do: "invited", else: "signed up"}
              </td>
              <td class="text-xs text-base-content/60">
                {user.last_signed_in_at || "never"}
              </td>
              <td class="text-xs">
                <form phx-submit="set-limit" class="flex items-center gap-1">
                  <input type="hidden" name="user_id" value={user.id} />
                  <span class="text-base-content/60">{@usage[user.id].items} /</span>
                  <input
                    type="number"
                    name="limit"
                    value={user.card_limit_override}
                    placeholder={Settings.free_card_limit() || "∞"}
                    class="input input-xs w-16"
                  />
                </form>
                <div class="mt-1 text-base-content/50">
                  {@usage[user.id].boards} boards · {Quota.humanise_bytes(@usage[user.id].storage)}
                </div>
              </td>
              <td class="text-xs">
                <form
                  id={"paid-until-#{user.id}"}
                  phx-submit="set-paid-until"
                  class="flex items-center gap-1"
                >
                  <input type="hidden" name="user_id" value={user.id} />
                  <input
                    type="date"
                    name="paid_until"
                    value={user.paid_until && Date.to_iso8601(DateTime.to_date(user.paid_until))}
                    class="input input-xs w-32"
                  />
                </form>
                <div :if={Quota.trial(user).applies?} class="mt-1 text-base-content/50">
                  {if Quota.trial_expired?(user),
                    do: "trial over",
                    else: "trial: #{Quota.trial(user).days_left}d left"}
                </div>
              </td>
              <td class="text-right">
                <button
                  :if={!user.admin}
                  phx-click="promote"
                  phx-value-id={user.id}
                  class="btn btn-ghost btn-xs"
                >
                  Make admin
                </button>
                <button
                  :if={user.admin}
                  phx-click="demote"
                  phx-value-id={user.id}
                  class="btn btn-ghost btn-xs"
                >
                  Remove admin
                </button>
                <button
                  :if={!user.disabled_at}
                  phx-click="disable"
                  phx-value-id={user.id}
                  class="btn btn-ghost btn-xs text-error"
                >
                  Disable
                </button>
                <button
                  :if={user.disabled_at}
                  phx-click="enable"
                  phx-value-id={user.id}
                  class="btn btn-ghost btn-xs"
                >
                  Enable
                </button>
                <button
                  :if={user.id != @current_user.id}
                  phx-click="confirm-delete"
                  phx-value-user_id={user.id}
                  class="btn btn-ghost btn-xs text-error"
                  title="Remove them and their data. Prefer Disable."
                >
                  Close
                </button>
                <form :if={user.id != @current_user.id} phx-submit="support" class="mt-1 flex gap-1">
                  <input type="hidden" name="user_id" value={user.id} />
                  <input
                    type="text"
                    name="reason"
                    placeholder="Help them with…"
                    class="input input-xs w-36"
                    title="Read their boards for a few hours. They are told, with this reason."
                  />
                  <button type="submit" class="btn btn-ghost btn-xs">Support</button>
                </form>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp signups_tab(assigns) do
    ~H"""
    <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
      <h2 class="text-lg font-semibold">Waiting for you</h2>
      <p :if={@requests == []} class="mt-2 text-sm text-base-content/60">
        Nobody is waiting.
      </p>

      <ul class="mt-4 divide-y divide-base-content/5">
        <li :for={request <- @requests} class="flex items-start justify-between gap-4 py-3">
          <div class="min-w-0">
            <div class="font-medium">{request.email}</div>
            <div :if={request.note && request.note != ""} class="text-sm text-base-content/70">
              “{request.note}”
            </div>
            <div class="text-xs text-base-content/50">asked {request.inserted_at}</div>
          </div>
          <div class="flex shrink-0 gap-2">
            <button phx-click="approve" phx-value-id={request.id} class="btn btn-primary btn-sm">
              Approve
            </button>
            <button phx-click="reject" phx-value-id={request.id} class="btn btn-ghost btn-sm">
              Turn down
            </button>
          </div>
        </li>
      </ul>
    </section>
    """
  end
end
