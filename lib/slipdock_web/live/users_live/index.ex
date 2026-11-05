defmodule SlipdockWeb.UsersLive.Index do
  @moduledoc """
  The people who use this server, and whoever is waiting to be let in. The
  settings they live under are on their own page, at `/config`.

  The people table is read-only (#1739). A row, or its Manage link, opens
  that person's panel (`person_panel/1`, a `<.modal>`) at `/users?user=<id>`,
  and every control lives there: their address, permissions (Admin,
  Unlimited, Meetings), their own item limit and paid-up date, support
  access, and a danger zone where Disable and Close each ask first
  (`data-confirm`), Close then showing what it takes and asking for the
  address typed out. Your own panel has no Support or danger zone.

  The part that matters is what it **refuses**: the last admin cannot be
  demoted, disabled or deleted, nobody can disable or close their own
  account, closing an account says exactly what it will take with it first,
  and support access always tells the person being looked at, with the
  reason the admin gave.
  """
  use SlipdockWeb, :live_view
  alias SlipdockWeb.Dates

  alias Slipdock.{Accounts, Quota, Settings}
  alias SlipdockWeb.Params

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Users") |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = socket.assigns.live_action
    wanted = if tab == :index, do: params["user"]
    selected = wanted && Params.id(wanted)

    socket =
      assign(socket,
        tab: tab,
        selected: selected,
        notice: nil,
        deleting: nil,
        deleting_preview: nil,
        editing_email: nil
      )

    # A link to somebody since closed, or not an id at all: say so, and drop
    # it from the address rather than leave a panel that never opens.
    if wanted && !Enum.any?(socket.assigns.users, &(&1.id == selected)) do
      {:noreply,
       socket
       |> assign(selected: nil)
       |> put_flash(:error, "That isn't there any more.")
       |> push_patch(to: ~p"/users")}
    else
      {:noreply, socket}
    end
  end

  defp load(socket) do
    users = Accounts.list_users()

    assign(socket,
      settings: Settings.get(),
      users: users,
      usage: Quota.usage(Enum.map(users, & &1.id)),
      support: Accounts.live_support_sessions(),
      # The boards behind the sessions this admin holds, by session id: the
      # way in to what Support grants.
      support_boards:
        Map.new(Slipdock.Access.supported_boards(socket.assigns.current_user), fn entry ->
          {entry.session.id, entry.boards}
        end),
      deleting: nil,
      deleting_preview: nil,
      editing_email: nil,
      selected: socket.assigns[:selected],
      notice: nil,
      requests: Accounts.list_signup_requests()
    )
  end

  ## People

  @impl true
  def handle_event("promote", %{"id" => id}, socket),
    do: {:noreply, standing(socket, id, :promote)}

  def handle_event("demote", %{"id" => id}, socket), do: {:noreply, standing(socket, id, :demote)}

  def handle_event("disable", %{"id" => id}, socket) do
    if yourself?(socket, id),
      do: {:noreply, say(socket, :error, "You can't disable your own account.")},
      else: {:noreply, standing(socket, id, :disable)}
  end

  def handle_event("enable", %{"id" => id}, socket), do: {:noreply, standing(socket, id, :enable)}

  def handle_event("set-limit", %{"user_id" => id, "limit" => limit}, socket) do
    with_user(socket, id, fn user ->
      value = if String.trim(limit) == "", do: nil, else: limit

      case Accounts.update_standing(user, %{"card_limit_override" => value}) do
        {:ok, _} -> {:noreply, socket |> load() |> say(:info, "Saved.")}
        {:error, _} -> {:noreply, say(socket, :error, "That isn't a number of cards.")}
      end
    end)
  end

  # Paid up to a date, which is what takes somebody off the free tier and off
  # the trial clock. Blank puts them back on it.
  def handle_event("set-paid-until", %{"user_id" => id, "paid_until" => until}, socket) do
    with_user(socket, id, fn user ->
      value = if String.trim(until) == "", do: nil, else: until

      case Accounts.update_standing(user, %{"paid_until" => value}) do
        {:ok, _} -> {:noreply, socket |> load() |> say(:info, "Saved.")}
        {:error, _} -> {:noreply, say(socket, :error, "That isn't a date.")}
      end
    end)
  end

  # Off the free tier with no date: a named person the allowance and the
  # trial should never reach. The guardrails still do.
  def handle_event("toggle-unlimited", %{"id" => id}, socket) do
    with_user(socket, id, fn user ->
      {:ok, _} = Accounts.update_standing(user, %{"unlimited" => !user.unlimited})
      {:noreply, socket |> load() |> say(:info, "Saved.")}
    end)
  end

  # Meetings, recording transcription and voiceprints, for this one person
  # (#1206). Admins always have them, so there is nothing to switch for one.
  def handle_event("toggle-meetings", %{"id" => id}, socket) do
    with_user(socket, id, fn user ->
      {:ok, _} = Accounts.update_standing(user, %{"meetings_access" => !user.meetings_access})
      {:noreply, socket |> load() |> say(:info, "Saved.")}
    end)
  end

  ## Adding somebody, and their address

  def handle_event("add-user", %{"email" => email}, socket) do
    case Accounts.add_user(email, socket.assigns.current_user) do
      {:ok, user, delivery} ->
        {:noreply, socket |> put_flash(:info, added_message(user, delivery)) |> load()}

      {:error, :exists} ->
        {:noreply, put_flash(socket, :error, "Somebody here already uses that address.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like an email address.")}
    end
  end

  def handle_event("edit-email", %{"user_id" => id}, socket) do
    with_user(socket, id, fn user -> {:noreply, assign(socket, editing_email: user.id)} end)
  end

  def handle_event("cancel-email", _params, socket),
    do: {:noreply, assign(socket, editing_email: nil)}

  def handle_event("set-email", %{"user_id" => id, "email" => email}, socket) do
    with_user(socket, id, fn user ->
      case Accounts.change_email(user, email, socket.assigns.current_user) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> load()
           |> say(:info, "#{updated.email} signs in with that address now.")}

        {:error, changeset} ->
          {:noreply, say(socket, :error, email_error(changeset))}
      end
    end)
  end

  ## Closing an account

  def handle_event("confirm-delete", %{"user_id" => id}, socket) do
    if yourself?(socket, id),
      do: {:noreply, say(socket, :error, "You can't close your own account.")},
      else: preview_delete(socket, id)
  end

  def handle_event("cancel-delete", _params, socket),
    do: {:noreply, assign(socket, deleting: nil, deleting_preview: nil)}

  def handle_event("delete", %{"user_id" => id, "email" => typed}, socket) do
    if yourself?(socket, id),
      do: {:noreply, say(socket, :error, "You can't close your own account.")},
      else: with_user(socket, id, &delete_user(socket, &1, typed))
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

  # The page's own admin. The panel offers them no Disable or Close, and
  # these refuse whatever the page sends: an admin who locks themself out by
  # accident needs somebody else to let them back in.
  defp yourself?(socket, id), do: Params.id(id) == socket.assigns.current_user.id

  defp preview_delete(socket, id) do
    with_user(socket, id, fn user ->
      {:noreply,
       assign(socket, deleting: user, deleting_preview: Accounts.deletion_preview(user))}
    end)
  end

  # The id comes from the page, which may be stale or hand-made: somebody
  # already deleted, or not an id at all, is a flash rather than a crash.
  defp with_user(socket, id, fun) do
    case Accounts.get_user(Params.id(id)) do
      nil -> gone(socket)
      user -> fun.(user)
    end
  end

  # Saying how they will hear about it matters: an account made in silence,
  # with no mail to tell them, is somebody who never finds out.
  defp added_message(user, {:ok, :emailed}),
    do: "Added #{user.email}. They have been emailed an invitation."

  defp added_message(user, {:ok, {:written, path}}),
    do: "Added #{user.email}. There is no mail server: their sign-in link is in #{path}."

  defp added_message(user, _),
    do:
      "Added #{user.email}. There is no mail server to tell them, so let them know " <>
        "they can sign in with that address."

  defp email_error(changeset) do
    if match?({_, [constraint: :unique] ++ _}, changeset.errors[:email]),
      do: "Somebody here already uses that address.",
      else: "That doesn't look like an email address."
  end

  # What an action in the person panel says goes at the top of the panel, not
  # in a toast: the info toast dismisses itself with a click, which the
  # modal takes as a click outside it and closes (#1739). With no panel open
  # (or the person in it gone) it is a flash as before.
  defp say(socket, kind, message) do
    selected = socket.assigns[:selected]

    if selected && Enum.any?(socket.assigns.users, &(&1.id == selected)),
      do: assign(socket, notice: {kind, message}),
      else: put_flash(socket, kind, message)
  end

  defp gone(socket),
    do: {:noreply, socket |> load() |> say(:error, "That isn't there any more.")}

  defp delete_user(socket, user, typed) do
    cond do
      String.trim(typed) != user.email ->
        {:noreply,
         say(socket, :error, "Type the address exactly to confirm — this cannot be undone.")}

      true ->
        case Accounts.delete_user(user) do
          {:ok, %{email: email, handed_over: handed}} ->
            {:noreply,
             socket
             |> assign(deleting: nil, deleting_preview: nil, selected: nil)
             |> put_flash(
               :info,
               "#{email} is gone." <>
                 if(handed == [],
                   do: "",
                   else: " #{length(handed)} shared board(s) were handed on."
                 )
             )
             |> load()
             |> push_patch(to: ~p"/users")}

          {:error, :last_admin} ->
            {:noreply, say(socket, :error, "That is the only admin.")}
        end
    end
  end

  defp open_support(socket, subject, reason) do
    case Accounts.open_support_session(socket.assigns.current_user, subject, reason) do
      {:ok, session} ->
        {:noreply,
         socket
         |> load()
         |> say(
           :info,
           "You can read #{subject.email}'s boards for the next " <>
             "#{SlipdockWeb.SlipdockComponents.support_time_left(session.expires_at)}: they " <>
             "are listed under Support access in force, and on your Boards page. They have " <>
             "been told, with the reason you gave."
         )}

      {:error, :self} ->
        {:noreply, say(socket, :error, "You can already see your own boards.")}

      {:error, _} ->
        {:noreply, say(socket, :error, "Say what the access is for, in a few words.")}
    end
  end

  defp standing(socket, id, action) do
    case Accounts.get_user(Params.id(id)) do
      nil -> socket |> load() |> say(:error, "That isn't there any more.")
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
        say(socket, :error, Slipdock.Accounts.last_admin_message(user))

      {:error, _} ->
        say(socket, :error, "Couldn't do that.")
    end
  end

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
      nav_active={:users}
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <.page width="full" class="space-y-6">
          <.page_header
            title="Users"
            subtitle="Everyone with an account here: add people, and disable or close an account."
          />
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
        </.page>
      </div>
    </Layouts.app>
    """
  end

  defp people_tab(assigns) do
    assigns =
      assign(assigns,
        panel_user: assigns.selected && Enum.find(assigns.users, &(&1.id == assigns.selected))
      )

    ~H"""
    <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
      <p class="text-sm text-base-content/60">
        {length(@users)} {if length(@users) == 1, do: "account", else: "accounts"}.
        Open somebody to change their plan or permissions, give them support, or disable or close
        their account.
      </p>

      <form id="add-user" phx-submit="add-user" class="mt-4 field-row gap-2">
        <div class="max-w-sm flex-1">
          <.input
            name="email"
            value=""
            type="email"
            label="Add somebody"
            placeholder="their@address"
            autocomplete="off"
          />
        </div>
        <button type="submit" class="btn btn-primary btn-sm">Add</button>
      </form>

      <div :if={@support != []} class="mt-4 rounded-xl bg-warning/10 p-4">
        <h3 class="text-sm font-medium">Support access in force</h3>
        <ul class="mt-2 space-y-1 text-sm">
          <li :for={session <- @support} id={"support-#{session.id}"} class="space-y-1.5">
            <div class="flex items-center justify-between gap-3">
              <span>
                {Accounts.User.display_name(session.admin)} can read {Accounts.User.display_name(
                  session.subject
                )}&#39;s boards for another {SlipdockWeb.SlipdockComponents.support_time_left(
                  session.expires_at
                )} — “{session.reason}”
              </span>
              <button phx-click="end-support" phx-value-id={session.id} class="btn btn-ghost btn-xs">
                End now
              </button>
            </div>
            <%!-- Yours: their boards, since no board list shows them. --%>
            <SlipdockWeb.SlipdockComponents.support_board_links
              :if={Map.has_key?(@support_boards, session.id)}
              id={"support-boards-#{session.id}"}
              boards={@support_boards[session.id]}
            />
          </li>
        </ul>
      </div>

      <div class="mt-4 overflow-x-auto">
        <table id="people" class="table table-sm">
          <thead>
            <tr>
              <th>Who</th>
              <th>Came from</th>
              <th>Last seen</th>
              <th>Usage</th>
              <th>Plan</th>
              <th>Role</th>
              <th><span class="sr-only">Manage</span></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={user <- @users}
              id={"person-#{user.id}"}
              phx-click={JS.patch(~p"/users?user=#{user.id}")}
              class={[
                "cursor-pointer hover:bg-base-200/60",
                user.disabled_at && "opacity-50",
                @selected == user.id && "bg-base-200/60"
              ]}
            >
              <td>
                <div class="font-medium">{Accounts.User.display_name(user)}</div>
                <div class="text-xs text-base-content/60">{user.email}</div>
              </td>
              <td class="text-xs text-base-content/60">
                {if user.invited_at, do: "invited", else: "signed up"}
              </td>
              <td class="text-xs text-base-content/60">
                <SlipdockWeb.SlipdockComponents.timestamp
                  :if={user.last_signed_in_at}
                  id={"last-seen-#{user.id}"}
                  at={user.last_signed_in_at}
                />
                <span :if={!user.last_signed_in_at}>never</span>
              </td>
              <td class="text-xs tabular-nums" data-role="usage">
                <div>{@usage[user.id].items} / {Quota.limit(user) || "∞"} items</div>
                <div class="text-base-content/60">
                  {@usage[user.id].boards} boards · {Quota.humanise_bytes(@usage[user.id].storage)}
                </div>
              </td>
              <td class="text-xs" data-role="plan">{plan_label(user)}</td>
              <td>
                <div class="flex flex-wrap gap-1" data-role="roles">
                  <span :if={user.admin} class="badge badge-xs badge-primary">admin</span>
                  <span :if={user.disabled_at} class="badge badge-xs">disabled</span>
                  <span :if={user.unlimited} class="badge badge-xs badge-success">unlimited</span>
                  <span
                    :if={user.meetings_access and !user.admin}
                    class="badge badge-xs badge-info"
                    title="May use meetings, transcription and voiceprints"
                  >
                    meetings
                  </span>
                </div>
              </td>
              <td class="text-right">
                <.link
                  id={"manage-#{user.id}"}
                  patch={~p"/users?user=#{user.id}"}
                  class="btn btn-ghost btn-xs"
                  aria-label={"Manage #{user.email}"}
                >
                  Manage
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.person_panel
        :if={@panel_user}
        user={@panel_user}
        usage={@usage[@panel_user.id]}
        current_user={@current_user}
        editing_email={@editing_email}
        deleting={@deleting}
        deleting_preview={@deleting_preview}
        notice={@notice}
        on_close={JS.patch(~p"/users")}
      />
    </section>
    """
  end

  ## The person panel (#1739)

  attr :user, :map, required: true
  attr :usage, :map, required: true
  attr :current_user, :map, required: true
  attr :editing_email, :any, default: nil
  attr :deleting, :any, default: nil
  attr :deleting_preview, :any, default: nil
  attr :notice, :any, default: nil, doc: "`{kind, message}`: what the last action here said"
  attr :on_close, JS, required: true

  defp person_panel(assigns) do
    assigns = assign(assigns, self?: assigns.user.id == assigns.current_user.id)

    ~H"""
    <SlipdockWeb.SlipdockComponents.modal id="person-panel" size="md" on_close={@on_close}>
      <div class="space-y-6 p-6" data-user-id={@user.id}>
        <.who {assigns} />
        <.callout
          :if={@notice}
          id="panel-notice"
          kind={elem(@notice, 0)}
        >
          {elem(@notice, 1)}
        </.callout>
        <.permissions user={@user} />
        <.plan user={@user} usage={@usage} />
        <.support :if={!@self?} user={@user} />
        <.danger_zone {assigns} />
      </div>
    </SlipdockWeb.SlipdockComponents.modal>
    """
  end

  defp who(assigns) do
    ~H"""
    <header class="pr-10">
      <h2 id="person-panel-title" class="section-title">{Accounts.User.display_name(@user)}</h2>
      <form
        :if={@editing_email == @user.id}
        id={"email-#{@user.id}"}
        phx-submit="set-email"
        class="mt-2 field-row gap-2"
      >
        <input type="hidden" name="user_id" value={@user.id} />
        <div class="flex-1">
          <.input
            id={"email-input-#{@user.id}"}
            name="email"
            value={@user.email}
            type="email"
            label="Signs in with"
            autocomplete="off"
            phx-mounted={JS.focus()}
          />
        </div>
        <button type="submit" class="btn btn-primary btn-sm">Save</button>
        <button type="button" phx-click="cancel-email" class="btn btn-ghost btn-sm">Cancel</button>
      </form>
      <div :if={@editing_email != @user.id} class="flex items-center gap-1">
        <span class="text-sm text-base-content/60">{@user.email}</span>
        <button
          id={"edit-email-#{@user.id}"}
          phx-click="edit-email"
          phx-value-user_id={@user.id}
          class="btn btn-ghost btn-xs px-1"
          title="Change the address they sign in with"
          aria-label={"Change #{@user.email}"}
        >
          <.icon name="hero-pencil-square" class="size-3.5" />
        </button>
      </div>
      <p class="mt-1 text-xs text-base-content/60">
        {if @user.invited_at, do: "Invited", else: "Signed up"} · last seen
        <SlipdockWeb.SlipdockComponents.timestamp
          :if={@user.last_signed_in_at}
          id={"panel-last-seen-#{@user.id}"}
          at={@user.last_signed_in_at}
        />
        <span :if={!@user.last_signed_in_at}>never</span>
      </p>
    </header>
    """
  end

  defp permissions(assigns) do
    ~H"""
    <section id="panel-permissions" aria-labelledby="panel-permissions-title">
      <h3 id="panel-permissions-title" class="text-sm font-medium">Permissions</h3>
      <div class="mt-2 flex flex-col gap-2 text-sm">
        <label class="flex cursor-pointer items-center gap-2">
          <input
            type="checkbox"
            id={"admin-#{@user.id}"}
            class="checkbox"
            checked={@user.admin}
            phx-click={if @user.admin, do: "demote", else: "promote"}
            phx-value-id={@user.id}
          /> Admin
        </label>
        <.exempt_box
          :if={@user.admin}
          label="Unlimited"
          why="Admins are exempt from the free tier's allowance and trial already."
        />
        <label
          :if={!@user.admin}
          class="flex cursor-pointer items-center gap-2"
          title={
            if @user.unlimited,
              do: "Put them back on the free tier's allowance and trial.",
              else:
                "Take them off the free tier's allowance and trial. The server-wide limits still apply."
          }
        >
          <input
            type="checkbox"
            id={"unlimited-#{@user.id}"}
            class="checkbox"
            checked={@user.unlimited}
            phx-click="toggle-unlimited"
            phx-value-id={@user.id}
          /> Unlimited
        </label>
        <.exempt_box
          :if={@user.admin}
          label="Meetings"
          why="Admins always have meetings, recording transcription and voiceprints."
        />
        <label
          :if={!@user.admin}
          class="flex cursor-pointer items-center gap-2"
          title={
            if @user.meetings_access,
              do: "Take away meetings, recording transcription and voiceprints.",
              else:
                "Let them use meetings, recording transcription and voiceprints, where the server has them on."
          }
        >
          <input
            type="checkbox"
            id={"meetings-#{@user.id}"}
            class="checkbox"
            checked={@user.meetings_access}
            phx-click="toggle-meetings"
            phx-value-id={@user.id}
          /> Meetings
        </label>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :why, :string, required: true

  defp exempt_box(assigns) do
    ~H"""
    <label class="flex items-center gap-2 text-base-content/50" title={@why}>
      <input type="checkbox" class="checkbox" checked disabled /> {@label}
    </label>
    """
  end

  defp plan(assigns) do
    trial = Quota.trial(assigns.user)
    assigns = assign(assigns, trial: trial, limit: Quota.limit(assigns.user))

    ~H"""
    <section id="panel-plan" aria-labelledby="panel-plan-title">
      <h3 id="panel-plan-title" class="text-sm font-medium">Plan and usage</h3>
      <p class="mt-1 text-sm text-base-content/70">
        {@usage.items} of {@limit || "∞"} items · {@usage.boards} boards · {Quota.humanise_bytes(
          @usage.storage
        )}
        <span :if={@trial.applies?}>
          · {if @trial.expired?, do: "trial over", else: "trial: #{@trial.days_left}d left"}
        </span>
      </p>
      <form
        id={"limit-#{@user.id}"}
        phx-submit="set-limit"
        class="mt-3 field-row gap-2"
      >
        <input type="hidden" name="user_id" value={@user.id} />
        <div class="max-w-48 flex-1">
          <.input
            id={"limit-input-#{@user.id}"}
            name="limit"
            type="number"
            min="1"
            value={@user.card_limit_override}
            label="Their own item limit"
            placeholder={if @user.unlimited, do: "∞", else: Settings.free_card_limit() || "∞"}
          />
        </div>
        <button type="submit" class="btn btn-sm">Save</button>
      </form>
      <form
        id={"paid-until-#{@user.id}"}
        phx-change="set-paid-until"
        phx-submit="set-paid-until"
        class="mt-2 max-w-48"
      >
        <input type="hidden" name="user_id" value={@user.id} />
        <.date_field
          id={"paid-until-date-#{@user.id}"}
          name="paid_until"
          value={@user.paid_until && DateTime.to_date(@user.paid_until)}
          label="Paid up to"
          placeholder="Not paid"
        />
      </form>
    </section>
    """
  end

  defp support(assigns) do
    ~H"""
    <section id="panel-support" aria-labelledby="panel-support-title">
      <h3 id="panel-support-title" class="text-sm font-medium">Support</h3>
      <p class="mt-1 text-sm text-base-content/70">
        Read their boards for a few hours. They are told, with the reason you give.
      </p>
      <form id={"support-form-#{@user.id}"} phx-submit="support" class="mt-2 field-row gap-2">
        <input type="hidden" name="user_id" value={@user.id} />
        <div class="flex-1">
          <.input
            id={"support-reason-#{@user.id}"}
            name="reason"
            value=""
            label="What it is for"
            placeholder="Help them with…"
            autocomplete="off"
          />
        </div>
        <button type="submit" class="btn btn-sm">Support</button>
      </form>
    </section>
    """
  end

  defp danger_zone(assigns) do
    ~H"""
    <section
      id="danger-zone"
      aria-labelledby="danger-zone-title"
      class="rounded-xl p-4 ring-1 ring-error/30"
    >
      <h3 id="danger-zone-title" class="text-sm font-medium text-error">Danger zone</h3>
      <p :if={@self?} class="mt-1 text-sm text-base-content/70">
        You can't disable or close your own account. Another admin can.
      </p>
      <div :if={!@self?}>
        <p class="mt-1 text-sm text-base-content/70">
          <span class="font-medium">Disable</span>
          signs someone out everywhere and stops them signing in; Enable undoes it.
          <span class="font-medium">Close</span>
          deletes the account and everything they own, after showing you what will go.
        </p>
        <div class="mt-3 flex flex-wrap gap-2">
          <button
            :if={!@user.disabled_at}
            id={"disable-#{@user.id}"}
            phx-click="disable"
            phx-value-id={@user.id}
            class="btn btn-ghost btn-error btn-sm"
            data-confirm={"Disable #{@user.email}? They can't sign in until you enable them again."}
          >
            Disable
          </button>
          <button
            :if={@user.disabled_at}
            id={"enable-#{@user.id}"}
            phx-click="enable"
            phx-value-id={@user.id}
            class="btn btn-sm"
          >
            Enable
          </button>
          <button
            :if={!@deleting}
            id={"close-#{@user.id}"}
            phx-click="confirm-delete"
            phx-value-user_id={@user.id}
            class="btn btn-ghost btn-error btn-sm"
            data-confirm={"Close #{@user.email}'s account? Next you'll see what it takes with it."}
            data-confirm-label="Continue"
          >
            Close account
          </button>
        </div>
        <.closing :if={@deleting} deleting={@deleting} preview={@deleting_preview} />
      </div>
    </section>
    """
  end

  defp closing(assigns) do
    ~H"""
    <div id="closing" class="mt-4 rounded-lg bg-error/10 p-4">
      <h4 class="text-sm font-medium">Close {@deleting.email}&#39;s account?</h4>
      <p class="mt-1 text-sm text-base-content/70">
        This cannot be undone. Use <span class="font-medium">Disable</span>
        instead unless they have actually asked to be removed — a disabled account keeps
        everything and can be turned back on.
      </p>

      <ul class="mt-3 space-y-1 text-sm">
        <li>
          <span class="font-medium">{@preview.cards_deleted}</span> cards on boards only
          they can see will be deleted.
        </li>
        <li :if={@preview.boards_deleted != []}>
          Deleted with them: {Enum.join(@preview.boards_deleted, ", ")}
        </li>
        <li :if={@preview.boards_handed_over != []}>
          Handed to whoever else works on them: {Enum.map_join(
            @preview.boards_handed_over,
            ", ",
            &"#{&1.name} → #{&1.to}"
          )}
        </li>
        <li class="text-base-content/60">
          Status updates and page history they wrote on other people's boards stay, with no
          author.
        </li>
      </ul>

      <form id="close-account" phx-submit="delete" class="mt-3 field-row gap-2">
        <input type="hidden" name="user_id" value={@deleting.id} />
        <div class="flex-1">
          <.input
            id="close-account-email"
            name="email"
            value=""
            type="text"
            label={"Type #{@deleting.email} to confirm"}
            autocomplete="off"
          />
        </div>
        <button type="submit" class="btn btn-error btn-sm">Close the account</button>
        <button type="button" phx-click="cancel-delete" class="btn btn-ghost btn-sm">Cancel</button>
      </form>
    </div>
    """
  end

  @doc """
  What somebody is on, in a few words for the table: exempt as an admin,
  unlimited, paid up to a date (or lapsed since it), or free with what is
  left of their trial.
  """
  @spec plan_label(Accounts.User.t()) :: String.t()
  def plan_label(%{admin: true}), do: "Admin, no allowance"
  def plan_label(%{unlimited: true}), do: "Unlimited"

  def plan_label(%{paid_until: %DateTime{} = until} = user) do
    date = Dates.long(DateTime.to_date(until))

    if Quota.free?(user),
      do: "Free, lapsed #{date}#{trial_note(user)}",
      else: "Paid up to #{date}"
  end

  def plan_label(user), do: "Free#{trial_note(user)}"

  defp trial_note(user) do
    case Quota.trial(user) do
      %{applies?: true, expired?: true} -> " · trial over"
      %{applies?: true, days_left: days} -> " · trial: #{days}d left"
      _ -> ""
    end
  end

  defp signups_tab(assigns) do
    ~H"""
    <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
      <h2 class="section-title">Waiting for you</h2>
      <.empty_state
        :if={@requests == []}
        id="signups-empty"
        icon="hero-user-plus"
        title="Nobody is waiting"
        class="mt-3"
        compact
      >
        Someone who asks to join shows here for you to approve or turn down.
      </.empty_state>

      <ul class="mt-4 divide-y divide-base-content/5">
        <li :for={request <- @requests} class="flex items-start justify-between gap-4 py-3">
          <div class="min-w-0">
            <div class="font-medium">{request.email}</div>
            <div :if={request.note && request.note != ""} class="text-sm text-base-content/70">
              “{request.note}”
            </div>
            <div class="text-xs text-base-content/50">
              asked <SlipdockWeb.SlipdockComponents.timestamp at={request.inserted_at} />
            </div>
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

  # When they last signed in, as a person reads it (#1698, #1719): "5 min
  # ago" for the past week, then the date, with the year once it is not this one.
  @doc false
  def last_seen(%DateTime{} = at, now \\ DateTime.utc_now()), do: Dates.relative(at, now: now)
end
