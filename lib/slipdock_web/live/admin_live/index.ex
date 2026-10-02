defmodule SlipdockWeb.AdminLive.Index do
  @moduledoc """
  Everything the setup wizard asked, editable afterwards, plus the people.

  Deliberately small. Nobody with 250 users is going to run this, so there is no
  org chart, no roles beyond admin and no permission matrix — one page of
  settings, one list of people, one queue.

  The part that matters is what it **refuses**. An admin area that lets you
  brick your own instance is worse than no admin area, so: mail settings will
  not save without a test message that arrived, the last admin cannot be
  demoted, disabled or deleted, and changing the admin address needs the new
  one to confirm before it takes effect.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Accounts, Mailer, Quota, Settings}
  alias Slipdock.Settings.Instance

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Admin", mail_error: nil, mail_tested?: false) |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, tab: tab(socket))}

  defp tab(%{assigns: %{live_action: action}}), do: action

  defp load(socket) do
    settings = Settings.get()

    assign(socket,
      settings: settings,
      form: to_form(Settings.change(), as: :settings),
      mail_form: to_form(Settings.change(), as: :settings),
      allowlist: Settings.list_allowlist(),
      allow_form: to_form(%{"entry" => ""}, as: :allow),
      users: Accounts.list_users(),
      support: Accounts.live_support_sessions(),
      deleting: nil,
      deleting_preview: nil,
      requests: Accounts.list_signup_requests(),
      admin_email_pending: settings.admin_email
    )
  end

  ## Settings

  @impl true
  def handle_event("save-settings", %{"settings" => attrs}, socket) do
    # The admin's own address is changed through its own flow, which verifies
    # the new one first — otherwise a typo sends every approval notice and
    # lock-out warning into the void.
    attrs = Map.drop(attrs, ["admin_email"])

    case Settings.update(attrs) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Saved.") |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event("add-allow", %{"allow" => %{"entry" => entry}}, socket) do
    case Settings.add_allowlist_entry(entry, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Added #{entry}.") |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, allow_form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event("remove-allow", %{"id" => id}, socket) do
    Settings.remove_allowlist_entry(String.to_integer(id))
    {:noreply, load(socket)}
  end

  ## Mail

  def handle_event("mail", %{"step_action" => "test", "settings" => attrs}, socket) do
    recipient = String.trim(attrs["test_to"] || socket.assigns.current_user.email)

    case Mailer.test_delivery(attrs, recipient) do
      :ok ->
        {:noreply,
         socket
         |> assign(mail_tested?: true, mail_error: nil)
         |> put_flash(:info, "Test message sent to #{recipient}. Check that it arrived.")}

      {:error, message} ->
        {:noreply, assign(socket, mail_tested?: false, mail_error: message)}
    end
  end

  def handle_event("mail", %{"settings" => attrs}, socket) do
    attrs = Map.drop(attrs, ["test_to"])
    changing? = changing_mail?(socket.assigns.settings, attrs)

    cond do
      changing? and not socket.assigns.mail_tested? ->
        {:noreply,
         assign(socket,
           mail_error:
             "Send a test message that arrives before saving. A mail server that does " <>
               "not work is how everybody gets locked out for good."
         )}

      true ->
        case Settings.update(attrs) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(mail_tested?: false, mail_error: nil)
             |> put_flash(:info, "Mail settings saved.")
             |> load()}

          {:error, changeset} ->
            {:noreply, assign(socket, mail_form: to_form(Map.put(changeset, :action, :validate)))}
        end
    end
  end

  ## People

  def handle_event("promote", %{"id" => id}, socket),
    do: {:noreply, standing(socket, id, :promote)}

  def handle_event("demote", %{"id" => id}, socket), do: {:noreply, standing(socket, id, :demote)}

  def handle_event("disable", %{"id" => id}, socket),
    do: {:noreply, standing(socket, id, :disable)}

  def handle_event("enable", %{"id" => id}, socket), do: {:noreply, standing(socket, id, :enable)}

  def handle_event("set-limit", %{"user_id" => id, "limit" => limit}, socket) do
    user = Accounts.get_user!(id)
    value = if String.trim(limit) == "", do: nil, else: limit

    case Accounts.update_standing(user, %{"card_limit_override" => value}) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Saved.") |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "That isn't a number of cards.")}
    end
  end

  ## Closing an account

  def handle_event("confirm-delete", %{"user_id" => id}, socket) do
    user = Accounts.get_user!(id)
    {:noreply, assign(socket, deleting: user, deleting_preview: Accounts.deletion_preview(user))}
  end

  def handle_event("cancel-delete", _params, socket),
    do: {:noreply, assign(socket, deleting: nil, deleting_preview: nil)}

  def handle_event("delete", %{"user_id" => id, "email" => typed}, socket) do
    user = Accounts.get_user!(id)

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

  ## Support access

  def handle_event("support", %{"user_id" => id, "reason" => reason}, socket) do
    subject = Accounts.get_user!(id)

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

  def handle_event("end-support", %{"id" => id}, socket) do
    Accounts.get_support_session!(id) |> Accounts.end_support_session()
    {:noreply, socket |> put_flash(:info, "Ended.") |> load()}
  end

  ## Signups

  def handle_event("approve", %{"id" => id}, socket) do
    request = Accounts.get_signup_request!(id)

    case Accounts.approve_signup(request, socket.assigns.current_user, &url(~p"/login/#{&1}")) do
      {:ok, user} ->
        {:noreply, socket |> put_flash(:info, "#{user.email} can sign in now.") |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't approve that.")}
    end
  end

  def handle_event("reject", %{"id" => id}, socket) do
    Accounts.get_signup_request!(id) |> Accounts.reject_signup(socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Turned down.") |> load()}
  end

  ## The admin address

  def handle_event("change-admin-email", %{"settings" => %{"admin_email" => email}}, socket) do
    case Accounts.request_admin_email_change(email, socket.assigns.current_user) do
      {:ok, :sent} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "A code is on its way to #{email}. The address changes when it is confirmed; " <>
             "until then everything still goes to the old one."
         )}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("confirm-admin-email", %{"confirm" => %{"code" => code}}, socket) do
    case Accounts.confirm_admin_email_change(code, socket.assigns.current_user) do
      {:ok, email} ->
        {:noreply, socket |> put_flash(:info, "The admin address is now #{email}.") |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That code is wrong, or it has expired.")}
    end
  end

  ## Internals

  defp standing(socket, id, action) do
    user = Accounts.get_user!(id)

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

  @mail_fields ~w(smtp_host smtp_port smtp_username smtp_password smtp_tls smtp_from_email
                  smtp_from_name)

  defp changing_mail?(settings, attrs) do
    Enum.any?(@mail_fields, fn field ->
      submitted = attrs[field]
      current = Map.get(settings, String.to_existing_atom(field))

      # A blank password means "keep the stored one", so it is never a change.
      cond do
        field == "smtp_password" and to_string(submitted) == "" -> false
        is_nil(submitted) -> false
        true -> to_string(submitted) != to_string(current)
      end
    end)
  end

  defp mode_label(mode), do: elem(Instance.describe(mode), 0)
  defp mode_detail(mode), do: elem(Instance.describe(mode), 1)

  defp humanise_tls(:always), do: "Always"
  defp humanise_tls(:never), do: "Never"
  defp humanise_tls(:if_available), do: "If available"

  defp forced_fallback_off?, do: Application.get_env(:slipdock, :login_fallback) == false

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
      nav_active={:admin}
    >
      <:nav><span class="font-semibold">Admin</span></:nav>

      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl space-y-6 p-6">
          <div role="tablist" class="tabs tabs-box">
            <.link patch={~p"/admin"} role="tab" class={["tab", @tab == :index && "tab-active"]}>
              This server
            </.link>
            <.link patch={~p"/admin/mail"} role="tab" class={["tab", @tab == :mail && "tab-active"]}>
              Email
            </.link>
            <.link
              patch={~p"/admin/people"}
              role="tab"
              class={["tab", @tab == :people && "tab-active"]}
            >
              People
            </.link>
            <.link
              :if={@settings.signup_mode == :approval}
              patch={~p"/admin/signups"}
              role="tab"
              class={["tab", @tab == :signups && "tab-active"]}
            >
              Requests
              <span :if={@requests != []} class="badge badge-sm badge-warning ml-1">
                {length(@requests)}
              </span>
            </.link>
          </div>

          <.server_tab :if={@tab == :index} {assigns} />
          <.mail_tab :if={@tab == :mail} {assigns} />
          <.people_tab :if={@tab == :people} {assigns} />
          <.signups_tab :if={@tab == :signups} {assigns} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp server_tab(assigns) do
    ~H"""
    <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
      <h2 class="text-lg font-semibold">Who can register</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Changing this does not remove anybody. People who already have an account keep it,
        whichever way you set this.
      </p>

      <.form for={@form} id="admin-settings-form" phx-submit="save-settings" class="mt-4 space-y-5">
        <label
          :for={mode <- Instance.signup_modes()}
          class="flex cursor-pointer gap-3 rounded-xl p-3 ring-1 ring-base-content/10 hover:bg-base-200 has-[:checked]:bg-primary/5 has-[:checked]:ring-primary"
        >
          <input
            type="radio"
            name="settings[signup_mode]"
            value={mode}
            checked={@settings.signup_mode == mode}
            class="radio radio-sm mt-0.5 radio-primary"
          />
          <span class="min-w-0">
            <span class="block text-sm font-medium">{mode_label(mode)}</span>
            <span class="block text-xs text-base-content/60">{mode_detail(mode)}</span>
          </span>
        </label>

        <.input
          field={@form[:free_card_limit]}
          type="number"
          label="Cards allowed per person"
          value={@settings.free_card_limit}
          placeholder="No limit"
        />

        <fieldset class="space-y-2">
          <legend class="text-sm font-medium">Who people can see</legend>
          <label class="flex cursor-pointer items-start gap-3 text-sm">
            <input
              type="radio"
              name="settings[user_directory]"
              value="instance"
              checked={@settings.user_directory == :instance}
              class="radio radio-sm mt-0.5"
            />
            <span>
              <span class="block font-medium">Everyone on this server</span>
              <span class="block text-xs text-base-content/60">
                Right for one person or a team who all work together.
              </span>
            </span>
          </label>
          <label class="flex cursor-pointer items-start gap-3 text-sm">
            <input
              type="radio"
              name="settings[user_directory]"
              value="shared_only"
              checked={@settings.user_directory == :shared_only}
              class="radio radio-sm mt-0.5"
            />
            <span>
              <span class="block font-medium">Only people they share something with</span>
              <span class="block text-xs text-base-content/60">
                Right when strangers share this server. Changing to this hides people from
                each other who can see each other today.
              </span>
            </span>
          </label>
        </fieldset>

        <label class="flex cursor-pointer items-start gap-3 text-sm">
          <input type="hidden" name="settings[invites_create_accounts]" value="false" />
          <input
            type="checkbox"
            name="settings[invites_create_accounts]"
            value="true"
            checked={@settings.invites_create_accounts}
            class="checkbox checkbox-sm mt-0.5"
          />
          <span>
            <span class="block font-medium">Sharing with a stranger gives them an account</span>
            <span class="block text-xs text-base-content/60">
              Off, you can only share with people who already have one. On, anybody you share
              a card with can use this server — subject to the card limit above.
            </span>
          </span>
        </label>

        <button type="submit" class="btn btn-primary">Save</button>
      </.form>

      <div class="mt-6 border-t border-base-content/10 pt-6">
        <h3 class="font-medium">Terms and privacy</h3>
        <p class="mt-1 text-xs text-base-content/60">
          For a server other people use. Fill in a link and a version and everybody is asked to
          agree before they can carry on; change the version and they are asked again. Leave
          them empty — as a server only you use should — and none of this appears anywhere.
        </p>

        <.form for={@form} id="terms-form" phx-submit="save-settings" class="mt-3 space-y-3">
          <input type="hidden" name="settings[signup_mode]" value={@settings.signup_mode} />
          <.input
            field={@form[:terms_url]}
            type="url"
            label="Terms of service"
            value={@settings.terms_url}
            placeholder="https://example.com/terms"
          />
          <.input
            field={@form[:privacy_url]}
            type="url"
            label="Privacy notice"
            value={@settings.privacy_url}
            placeholder="https://example.com/privacy"
          />
          <.input
            field={@form[:terms_version]}
            type="text"
            label="Version"
            value={@settings.terms_version}
            placeholder="2026-10-02"
          />
          <p class="text-xs text-base-content/60">
            Writing the terms themselves is your job, not Slipdock's. One thing they should
            say: card and page text is sent to OpenRouter when anybody uses the AI features.
          </p>
          <button type="submit" class="btn btn-outline btn-sm">Save</button>
        </.form>
      </div>

      <div :if={@settings.signup_mode == :allowlist} class="mt-6 border-t border-base-content/10 pt-6">
        <h3 class="font-medium">Who is allowed</h3>
        <p class="mt-1 text-xs text-base-content/60">
          An address, or a bare domain to let in everybody there.
        </p>

        <ul class="mt-3 divide-y divide-base-content/5">
          <li :for={entry <- @allowlist} class="flex items-center justify-between py-2 text-sm">
            <span class="font-mono">{entry.entry}</span>
            <span class="flex items-center gap-3">
              <span class="text-xs text-base-content/50">
                {if entry.last_used_at, do: "used", else: "never used"}
              </span>
              <button
                type="button"
                phx-click="remove-allow"
                phx-value-id={entry.id}
                class="btn btn-ghost btn-xs"
              >
                Remove
              </button>
            </span>
          </li>
          <li :if={@allowlist == []} class="py-2 text-sm text-base-content/50">
            Nobody yet — so nobody new can register.
          </li>
        </ul>

        <.form for={@allow_form} id="allow-form" phx-submit="add-allow" class="mt-3 flex gap-2">
          <div class="flex-1">
            <.input
              field={@allow_form[:entry]}
              type="text"
              placeholder="you@example.com or example.com"
            />
          </div>
          <button type="submit" class="btn btn-outline">Add</button>
        </.form>
      </div>
    </section>
    """
  end

  defp mail_tab(assigns) do
    ~H"""
    <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
      <h2 class="text-lg font-semibold">Email</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Sign-in codes, invitations and whatever your automation rules send.
      </p>

      <.form for={@mail_form} id="admin-mail-form" phx-submit="mail" class="mt-4 space-y-4">
        <.input
          field={@mail_form[:smtp_host]}
          type="text"
          label="Mail server"
          value={@settings.smtp_host}
          placeholder="smtp.example.com"
        />
        <div class="grid grid-cols-2 gap-3">
          <.input
            field={@mail_form[:smtp_port]}
            type="number"
            label="Port"
            value={@settings.smtp_port}
            placeholder="587"
          />
          <.input
            field={@mail_form[:smtp_tls]}
            type="select"
            label="TLS"
            value={@settings.smtp_tls}
            options={Enum.map(Instance.tls_modes(), &{humanise_tls(&1), &1})}
          />
        </div>
        <div class="grid grid-cols-2 gap-3">
          <.input
            field={@mail_form[:smtp_username]}
            type="text"
            label="Username"
            value={@settings.smtp_username}
            autocomplete="off"
          />
          <.input
            field={@mail_form[:smtp_password]}
            type="password"
            label="Password"
            placeholder={if Settings.smtp_password_set?(), do: "unchanged", else: ""}
            autocomplete="off"
          />
        </div>
        <p class="-mt-2 text-xs text-base-content/60">
          Leave the password empty to keep the one already stored — it is never sent to your
          browser, so it cannot be sent back.
        </p>
        <div class="grid grid-cols-2 gap-3">
          <.input
            field={@mail_form[:smtp_from_email]}
            type="email"
            label="Send from"
            value={@settings.smtp_from_email}
          />
          <.input
            field={@mail_form[:smtp_from_name]}
            type="text"
            label="Sender name"
            value={@settings.smtp_from_name}
          />
        </div>

        <div class="rounded-xl bg-base-200 p-4">
          <p class="text-sm font-medium">Send a test message</p>
          <p class="mt-1 text-xs text-base-content/60">
            Changes cannot be saved until one arrives. A mail server that does not work is how
            everybody gets locked out of this server for good.
          </p>
          <div class="mt-3 flex items-end gap-2">
            <div class="flex-1">
              <.input
                field={@mail_form[:test_to]}
                type="email"
                label="To"
                value={@current_user.email}
              />
            </div>
            <button type="submit" name="step_action" value="test" class="btn btn-outline mb-1">
              Send test
            </button>
          </div>
          <p :if={@mail_error} class="mt-2 text-sm text-error">{@mail_error}</p>
          <p :if={@mail_tested?} class="mt-2 text-sm text-success">
            <.icon name="hero-check-circle" class="size-4" /> A test message went out.
          </p>
          <p :if={@settings.smtp_verified_at} class="mt-2 text-xs text-base-content/50">
            Last confirmed working: {@settings.smtp_verified_at}
          </p>
        </div>

        <button type="submit" name="step_action" value="save" class="btn btn-primary">Save</button>
      </.form>

      <div class="mt-6 border-t border-base-content/10 pt-6">
        <h3 class="font-medium">When mail is not working</h3>
        <p class="mt-1 text-sm text-base-content/70">
          Sign-in codes are written to a file on the server and to its log, so that an
          instance with no mail can still be used.
          <span class="font-medium">Anyone who can read either can sign in as anybody</span>
          — fine on a machine only you can reach, a hole on one you share.
        </p>
        <p class="mt-2 text-sm">
          Right now:
          <span class="font-medium">
            {if Settings.login_fallback_enabled?(), do: Accounts.fallback_path(), else: "off"}
          </span>
        </p>
        <p :if={forced_fallback_off?()} class="mt-2 rounded-xl bg-base-200 p-3 text-xs">
          Forced off by <code class="font-mono">SLIPDOCK_LOGIN_FALLBACK=false</code>
          in this server's environment, which nothing here can undo. That is the right
          setting for a host other people can reach.
        </p>
      </div>

      <div class="mt-6 border-t border-base-content/10 pt-6">
        <h3 class="font-medium">Admin address</h3>
        <p class="mt-1 text-sm text-base-content/60">
          Where requests and warnings go. Currently <span class="font-medium">{@settings.admin_email || "nowhere"}</span>.
          A new address has to confirm a code before it takes effect — an admin address
          nobody reads is a silent lock-out.
        </p>

        <.form
          for={@form}
          id="admin-email-form"
          phx-submit="change-admin-email"
          class="mt-3 flex gap-2"
        >
          <div class="flex-1">
            <.input field={@form[:admin_email]} type="email" placeholder="new@example.com" />
          </div>
          <button type="submit" class="btn btn-outline">Send a code</button>
        </.form>

        <.form
          for={to_form(%{}, as: :confirm)}
          id="admin-email-confirm"
          phx-submit="confirm-admin-email"
          class="mt-2 flex gap-2"
        >
          <div class="flex-1">
            <.input
              field={to_form(%{}, as: :confirm)[:code]}
              type="text"
              placeholder="Code from the new address"
            />
          </div>
          <button type="submit" class="btn btn-ghost">Confirm</button>
        </.form>
      </div>
    </section>
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
              <th>Cards</th>
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
                  <span class="text-base-content/60">{Quota.used(user)} /</span>
                  <input
                    type="number"
                    name="limit"
                    value={user.card_limit_override}
                    placeholder={Settings.free_card_limit() || "∞"}
                    class="input input-xs w-16"
                  />
                </form>
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
