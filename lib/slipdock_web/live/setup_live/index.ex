defmodule SlipdockWeb.SetupLive.Index do
  @moduledoc """
  The first-run setup wizard: three steps, then this page is gone for good.

  1. Who may register here, and whether a free account is capped.
  2. How mail goes out. Optional — but it will not save an untested
     configuration, because a broken one is a permanent lock-out.
  3. The admin's address, which claims the server.

  ## What it is guarding against

  Nobody is signed in while this runs; there is nobody to sign in as. On a
  server only you can reach that is fine, and on a public one it is a race for
  ownership — so the first boot logs a token and this page will not proceed
  without it. See `SlipdockWeb.Plugs.Setup`.

  Completing step 3 stamps `setup_completed_at`, after which the route 404s and
  no sign-in can claim the server.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.Accounts
  alias Slipdock.Mailer
  alias Slipdock.Settings
  alias Slipdock.Settings.Instance

  @doc """
  Halts anybody who reaches the wizard's LiveView after setup has finished. The
  plug covers the first request; this covers a live navigation, and a socket
  that was already connected when somebody else finished setting up.
  """
  def on_mount(:ensure_unclaimed, _params, _session, socket) do
    if Settings.setup_complete?() do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, socket}
    end
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Set up Slipdock",
       step: :mode,
       authorised?: Settings.valid_setup_token?(params["token"]),
       token_form: to_form(%{"token" => ""}, as: :setup),
       # What the wizard has collected so far. Nothing is written until the
       # final step, so an abandoned wizard leaves no half-configured server.
       collected: %{},
       mail_tested?: false,
       mail_error: nil,
       mail_skipped?: false,
       admin_result: nil
     )
     |> assign_mode_form()
     |> assign_mail_form()
     |> assign_admin_form()}
  end

  ## The token

  @impl true
  def handle_event("authorise", %{"setup" => %{"token" => token}}, socket) do
    if Settings.valid_setup_token?(token) do
      {:noreply, assign(socket, authorised?: true)}
    else
      {:noreply,
       put_flash(socket, :error, "That is not the setup token for this server. It is in the log.")}
    end
  end

  ## Step 1 — who may register

  def handle_event("save-mode", %{"settings" => attrs}, socket) do
    # Validated without the mail rule: approval mode needs a mail server, but
    # mail is the *next* step, so complaining here would be complaining about
    # something the person has not been asked yet. Step 2 withholds its Skip
    # button instead, and `complete_setup/1` enforces it at the end.
    changeset = %Instance{} |> Instance.changeset(attrs) |> drop_mail_dependency()

    if changeset.valid? do
      {:noreply,
       socket
       |> collect(attrs)
       |> assign(step: :mail)}
    else
      {:noreply, assign(socket, mode_form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  ## Step 2 — mail

  # One form, two submit buttons. The test send has to be a *submit* rather than
  # a `phx-click`, or it arrives without the values somebody has just typed —
  # which is the whole point of being able to test before saving.
  def handle_event("mail-submit", %{"step_action" => "test", "settings" => attrs}, socket) do
    recipient = String.trim(attrs["test_to"] || "")

    if recipient == "" do
      {:noreply, assign(socket, mail_error: "Type an address to send the test to.")}
    else
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
  end

  def handle_event("mail-submit", %{"settings" => attrs}, socket) do
    if socket.assigns.mail_tested? do
      {:noreply,
       socket
       |> collect(Map.drop(attrs, ["test_to"]))
       |> assign(step: :admin, mail_skipped?: false)}
    else
      {:noreply,
       assign(socket,
         mail_error: "Send a test message that arrives before saving these settings."
       )}
    end
  end

  # Skipping deliberately drops whatever was typed into the mail form: a
  # half-filled, untested configuration is exactly what must not be saved, and
  # keeping it would make "skip" mean two different things.
  def handle_event("skip-mail", _params, socket) do
    {:noreply,
     socket
     |> assign(collected: Map.drop(socket.assigns.collected, mail_keys()))
     |> assign(step: :admin, mail_skipped?: true, mail_error: nil)}
  end

  ## Step 3 — the admin, and the end of the wizard

  def handle_event("finish", %{"settings" => %{"admin_email" => email}}, socket) do
    attrs = Map.put(socket.assigns.collected, "admin_email", email)

    case Settings.complete_setup(attrs) do
      {:ok, _settings} ->
        {:noreply, assign(socket, admin_result: claim(email))}

      {:error, changeset} ->
        {:noreply, assign(socket, admin_form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event("back", %{"to" => step}, socket) do
    {:noreply,
     socket
     |> assign(step: String.to_existing_atom(step))
     |> assign_mode_form()
     |> assign_mail_form()}
  end

  ## Internals

  defp mail_keys do
    ~w(smtp_host smtp_port smtp_username smtp_password smtp_from_email
       smtp_from_name smtp_tls test_to)
  end

  # Makes the admin, and gets them a way in: a code by email if mail works, and
  # otherwise written where the person running the server can read it. Either
  # way the screen says exactly where to look — this is the moment a wizard
  # most often leaves somebody stranded.
  defp claim(email) do
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, user} = Accounts.promote(user)

    case Accounts.deliver_sign_in(user, &url(~p"/login/#{&1}")) do
      {:ok, :emailed} -> %{email: email, delivery: :emailed}
      {:ok, {:written, path}} -> %{email: email, delivery: {:written, path}}
      {:ok, :logged} -> %{email: email, delivery: :logged}
      {:error, reason} -> %{email: email, delivery: {:failed, Mailer.describe_error(reason)}}
    end
  end

  defp collect(socket, attrs) do
    assign(socket, collected: Map.merge(socket.assigns.collected, attrs))
  end

  # All three forms are built from whatever the wizard has collected so far, so
  # that going Back shows the answers somebody already gave rather than an empty
  # form. Nothing here is saved; `collected` is the only state.
  defp assign_mode_form(socket), do: assign(socket, mode_form: collected_form(socket))
  defp assign_mail_form(socket), do: assign(socket, mail_form: collected_form(socket))
  defp assign_admin_form(socket), do: assign(socket, admin_form: collected_form(socket))

  defp drop_mail_dependency(changeset) do
    %{
      changeset
      | errors: Enum.reject(changeset.errors, &match?({:signup_mode, {_, _}}, &1))
    }
    |> Map.update!(:valid?, fn _ ->
      changeset.errors |> Enum.reject(&match?({:signup_mode, _}, &1)) |> Enum.empty?()
    end)
  end

  # Approval mode is the one choice that cannot do without mail, so the mail
  # step stops being optional once it has been chosen.
  defp mail_required?(collected), do: to_string(collected["signup_mode"]) == "approval"

  defp collected_form(socket) do
    to_form(Instance.changeset(%Instance{}, socket.assigns[:collected] || %{}), as: :settings)
  end

  # Which registration mode is selected: what was chosen before, else the safe
  # one. "Closed" is the right default — a server that collects accounts because
  # nobody changed a radio button is the wrong way round.
  defp selected_mode(form) do
    case form[:signup_mode].value do
      nil -> :closed
      "" -> :closed
      value when is_atom(value) -> value
      value when is_binary(value) -> String.to_existing_atom(value)
    end
  end

  defp step_number(:mode), do: 1
  defp step_number(:mail), do: 2
  defp step_number(:admin), do: 3

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex min-h-full items-center justify-center p-6">
        <div class="w-full max-w-xl rounded-2xl bg-base-100 p-8 shadow-sm ring-1 ring-base-content/10">
          <div class="mb-6 flex items-center gap-3">
            <Layouts.brand_mark class="size-12" variant={:detailed} />
            <div>
              <h1 class="text-xl font-bold">Set up Slipdock</h1>
              <p class="text-sm text-base-content/60">
                Nobody has claimed this server yet. Three questions and it is yours.
              </p>
            </div>
          </div>

          <.token_gate :if={!@authorised?} form={@token_form} />

          <div :if={@authorised? && @admin_result}>
            <.finished result={@admin_result} />
          </div>

          <div :if={@authorised? && !@admin_result}>
            <.steps step={@step} />

            <.mode_step :if={@step == :mode} form={@mode_form} />
            <.mail_step
              :if={@step == :mail}
              form={@mail_form}
              tested?={@mail_tested?}
              error={@mail_error}
              required?={mail_required?(@collected)}
            />
            <.admin_step
              :if={@step == :admin}
              form={@admin_form}
              mail_skipped?={@mail_skipped?}
              fallback_path={Accounts.fallback_path()}
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # The token is not a password and is not secret for long — it is there so
  # that reaching the page first is not enough to own the server.
  defp token_gate(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="rounded-xl bg-warning/10 p-4 text-sm">
        <p class="font-medium">The setup token, please</p>
        <p class="mt-1 text-base-content/70">
          Setting this server up has to be possible before anybody has an account, so
          the token is what stops a passer-by claiming it. It was written to the log when
          the server started:
        </p>
        <code class="mt-3 block select-all break-all rounded-lg bg-base-200 px-3 py-2 font-mono text-xs">
          journalctl -u slipdock | grep -A4 "has not been set up"
        </code>
        <p class="mt-2 text-base-content/70">
          Under Docker: <code class="font-mono">docker compose logs slipdock</code>.
        </p>
      </div>

      <.form for={@form} id="setup-token-form" phx-submit="authorise" class="space-y-4">
        <.input field={@form[:token]} type="text" label="Setup token" phx-hook="Focus" required />
        <button type="submit" class="btn btn-primary w-full">Continue</button>
      </.form>
    </div>
    """
  end

  attr :step, :atom, required: true

  defp steps(assigns) do
    ~H"""
    <ul class="steps mb-6 w-full text-xs">
      <li class={["step", step_number(@step) >= 1 && "step-primary"]}>Who can join</li>
      <li class={["step", step_number(@step) >= 2 && "step-primary"]}>Email</li>
      <li class={["step", step_number(@step) >= 3 && "step-primary"]}>You</li>
    </ul>
    """
  end

  defp mode_step(assigns) do
    ~H"""
    <.form for={@form} id="setup-mode-form" phx-submit="save-mode" class="space-y-5">
      <fieldset class="space-y-2">
        <legend class="mb-1 text-sm font-medium">Who can register on this server?</legend>
        <label
          :for={mode <- Instance.signup_modes()}
          class="flex cursor-pointer gap-3 rounded-xl p-3 ring-1 ring-base-content/10 hover:bg-base-200 has-[:checked]:bg-primary/5 has-[:checked]:ring-primary"
        >
          <input
            type="radio"
            name="settings[signup_mode]"
            value={mode}
            checked={selected_mode(@form) == mode}
            class="radio radio-sm mt-0.5 radio-primary"
          />
          <span class="min-w-0">
            <span class="block text-sm font-medium">{elem(Instance.describe(mode), 0)}</span>
            <span class="block text-xs text-base-content/60">{elem(Instance.describe(mode), 1)}</span>
          </span>
        </label>
      </fieldset>

      <.input
        field={@form[:free_card_limit]}
        type="number"
        label="Cards allowed per person, before they need to pay"
        placeholder="No limit"
      />
      <p class="-mt-3 text-xs text-base-content/60">
        Leave this empty unless you are running Slipdock for other people. It counts
        the cards on boards somebody owns, so a guest working on your board costs them
        nothing.
      </p>

      <button type="submit" class="btn btn-primary w-full">Next: email</button>
    </.form>
    """
  end

  defp mail_step(assigns) do
    ~H"""
    <.form for={@form} id="setup-mail-form" phx-submit="mail-submit" class="space-y-4">
      <p :if={!@required?} class="text-sm text-base-content/70">
        Slipdock emails sign-in codes and whatever your automation rules send. Without a
        mail server it still works — codes are written where you can read them — so you
        can skip this and set it up later.
      </p>
      <p :if={@required?} class="rounded-xl bg-warning/10 p-4 text-sm">
        You chose to approve each request, so this step is not optional: without a mail
        server nobody would ever be told that somebody is waiting. Go back and pick
        another way in if you would rather not set mail up now.
      </p>

      <.input
        field={@form[:smtp_host]}
        type="text"
        label="Mail server"
        placeholder="smtp.example.com"
      />
      <div class="grid grid-cols-2 gap-3">
        <.input field={@form[:smtp_port]} type="number" label="Port" placeholder="587" />
        <.input
          field={@form[:smtp_tls]}
          type="select"
          label="TLS"
          options={Enum.map(Instance.tls_modes(), &{humanise_tls(&1), &1})}
        />
      </div>
      <div class="grid grid-cols-2 gap-3">
        <.input field={@form[:smtp_username]} type="text" label="Username" autocomplete="off" />
        <.input field={@form[:smtp_password]} type="password" label="Password" autocomplete="off" />
      </div>
      <p class="-mt-2 text-xs text-base-content/60">
        Leave both empty for a relay that authorises by IP address.
      </p>
      <div class="grid grid-cols-2 gap-3">
        <.input
          field={@form[:smtp_from_email]}
          type="email"
          label="Send from"
          placeholder="slipdock@example.com"
        />
        <.input field={@form[:smtp_from_name]} type="text" label="Sender name" placeholder="Slipdock" />
      </div>

      <div class="rounded-xl bg-base-200 p-4">
        <p class="text-sm font-medium">Send a test message</p>
        <p class="mt-1 text-xs text-base-content/60">
          These settings cannot be saved until one arrives. A mail server that does not
          work is how you lock yourself out of your own server for good.
        </p>
        <div class="mt-3 flex items-end gap-2">
          <div class="flex-1">
            <.input field={@form[:test_to]} type="email" label="To" placeholder="you@example.com" />
          </div>
          <button type="submit" name="step_action" value="test" class="btn btn-outline mb-1">
            Send test
          </button>
        </div>
        <p :if={@error} class="mt-2 text-sm text-error">{@error}</p>
        <p :if={@tested?} class="mt-2 text-sm text-success">
          <.icon name="hero-check-circle" class="size-4" /> A test message went out.
        </p>
      </div>

      <div class="flex gap-2">
        <button type="button" class="btn btn-ghost" phx-click="back" phx-value-to="mode">Back</button>
        <button
          :if={!@required?}
          type="button"
          class="btn btn-ghost flex-1"
          phx-click="skip-mail"
        >
          Skip — no mail server
        </button>
        <button type="submit" name="step_action" value="save" class="btn btn-primary flex-1">
          Next: you
        </button>
      </div>
    </.form>
    """
  end

  defp admin_step(assigns) do
    ~H"""
    <.form for={@form} id="setup-admin-form" phx-submit="finish" class="space-y-4">
      <p class="text-sm text-base-content/70">
        Last one. This address is the admin: it can change who may register, how mail is
        sent, and other people's accounts. <span class="font-medium">Saving it closes this
        page for good.</span>
      </p>

      <.input
        field={@form[:admin_email]}
        type="email"
        label="Your email address"
        placeholder="you@example.com"
        phx-hook="Focus"
        required
      />

      <div :if={@mail_skipped?} class="rounded-xl bg-info/10 p-4 text-sm">
        <p class="font-medium">No mail server, so your sign-in code goes to a file</p>
        <p class="mt-1 text-base-content/70">
          It will be written here, and to the log. Anyone who can read either can sign in
          as anybody, which is why you should set up mail once you are in.
        </p>
        <code class="mt-3 block select-all break-all rounded-lg bg-base-200 px-3 py-2 font-mono text-xs">{@fallback_path}</code>
      </div>

      <div class="flex gap-2">
        <button type="button" class="btn btn-ghost" phx-click="back" phx-value-to="mail">Back</button>
        <button type="submit" class="btn btn-primary flex-1">Finish, and sign me in</button>
      </div>
    </.form>
    """
  end

  defp finished(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="rounded-xl bg-success/10 p-4 text-sm">
        <p class="font-medium">This server is yours</p>
        <p class="mt-1 text-base-content/70">
          {@result.email} is the admin. This page is gone now — everything on it is under
          Admin from here on.
        </p>
      </div>

      <.delivery_note delivery={@result.delivery} email={@result.email} />

      <a href={~p"/login"} class="btn btn-primary w-full">Sign in</a>
    </div>
    """
  end

  defp delivery_note(%{delivery: :emailed} = assigns) do
    ~H"""
    <p class="text-sm text-base-content/70">
      A sign-in link is on its way to {@email}. It works once and expires in 15 minutes.
    </p>
    """
  end

  defp delivery_note(%{delivery: {:written, _}} = assigns) do
    assigns = assign(assigns, path: elem(assigns.delivery, 1))

    ~H"""
    <div class="rounded-xl bg-info/10 p-4 text-sm">
      <p class="font-medium">Your sign-in link is in this file</p>
      <p class="mt-1 text-base-content/70">Read it on the server and open the link inside:</p>
      <code class="mt-3 block select-all break-all rounded-lg bg-base-200 px-3 py-2 font-mono text-xs">cat {@path}</code>
      <p class="mt-2 text-base-content/70">
        It is in the log too: <code class="font-mono">journalctl -u slipdock | tail</code>, or <code class="font-mono">docker compose logs slipdock</code>.
      </p>
    </div>
    """
  end

  defp delivery_note(%{delivery: :logged} = assigns) do
    ~H"""
    <div class="rounded-xl bg-info/10 p-4 text-sm">
      <p class="font-medium">Your sign-in link is in the log</p>
      <p class="mt-1 text-base-content/70">
        The file could not be written, so the log is the only copy:
      </p>
      <code class="mt-3 block select-all break-all rounded-lg bg-base-200 px-3 py-2 font-mono text-xs">journalctl -u slipdock | grep "Sign-in link"</code>
      <p class="mt-2 text-base-content/70">
        Under Docker: <code class="font-mono">docker compose logs slipdock</code>.
      </p>
    </div>
    """
  end

  defp delivery_note(%{delivery: {:failed, _}} = assigns) do
    assigns = assign(assigns, reason: elem(assigns.delivery, 1))

    ~H"""
    <div class="rounded-xl bg-error/10 p-4 text-sm">
      <p class="font-medium">The server is set up, but the sign-in email failed</p>
      <p class="mt-1 text-base-content/70">{@reason}</p>
      <p class="mt-2 text-base-content/70">
        Ask for a link from the sign-in page; it will be written to the log if it cannot
        be emailed.
      </p>
    </div>
    """
  end

  defp humanise_tls(:always), do: "Always"
  defp humanise_tls(:never), do: "Never"
  defp humanise_tls(:if_available), do: "If available"
end
