defmodule SlipdockWeb.LoginLive.Index do
  use SlipdockWeb, :live_view

  alias Slipdock.{Accounts, RateLimit}

  # Per address, and per source address: enough for somebody who keeps
  # mistyping their email, nowhere near enough to use this server as a mailer.
  @per_email 5
  @per_ip 20
  @window :timer.hours(1)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Sign in",
       # Captured at mount: the peer is in the connect info, which a later
       # event no longer has.
       peer: peer_ip(socket),
       form: to_form(%{"email" => ""}, as: :login),
       sent_to: nil,
       stance: Accounts.signup_stance(),
       fallback?: Slipdock.Settings.login_fallback_enabled?(),
       requested: false,
       # Its own name, or its inputs collide with the sign-in form's: two
       # `login[email]` fields means two `#login_email` ids on one page.
       request_form: to_form(%{"email" => "", "note" => ""}, as: :request),
       code_form: to_form(%{"code" => ""}, as: :login),
       code_error: nil,
       agentic_file: nil,
       agentic: Accounts.agentic_login_enabled?(),
       # Nil on a server with no terms, and then the page says nothing about them.
       terms: if(Slipdock.Settings.terms?(), do: Slipdock.Settings.get()),
       dev_mailbox: Application.get_env(:slipdock, :dev_routes, false)
     )}
  end

  # The "Agentic Login" submit button adds login[mode]=agentic to the params.
  @impl true
  def handle_event("send", %{"login" => %{"email" => email, "mode" => "agentic"}}, socket) do
    with :ok <- allowed_to_try(socket, email),
         {:ok, path} <- Accounts.write_agentic_login(email, &url(~p"/login/#{&1}")) do
      {:noreply, assign(socket, agentic_file: path)}
    else
      {:error, :disabled} ->
        {:noreply, put_flash(socket, :error, "Agentic login is not enabled on this server.")}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "That address can't sign in on this server.")}

      {:error, {:too_many, seconds}} ->
        {:noreply, put_flash(socket, :error, too_many_message(seconds))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like an email address.")}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The sign-in link file couldn't be written (#{inspect(reason)})."
         )}
    end
  end

  def handle_event("send", %{"login" => %{"email" => email}}, socket) do
    case allowed_to_try(socket, email) do
      :ok ->
        {:noreply, send_link(socket, email)}

      {:error, {:too_many, seconds}} ->
        {:noreply, put_flash(socket, :error, too_many_message(seconds))}
    end
  end

  # Asking for an account where an admin has to say yes. Unlike a sign-in
  # request this *is* told the truth, because silence here looks like a bug:
  # somebody who has asked needs to know they are waiting on a person.
  def handle_event("request", %{"request" => %{"email" => email, "note" => note}}, socket) do
    case allowed_to_try(socket, email) do
      {:error, {:too_many, seconds}} ->
        {:noreply, put_flash(socket, :error, too_many_message(seconds))}

      :ok ->
        case Accounts.request_signup(email, note: note, ip: socket.assigns.peer) do
          {:ok, _} ->
            {:noreply, assign(socket, requested: true)}

          {:error, :rejected} ->
            # Saying "you were turned down" would be kinder but would also
            # confirm the address to anybody who typed it.
            {:noreply, assign(socket, requested: true)}

          {:error, :already_a_user} ->
            {:noreply, assign(socket, requested: true)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "That doesn't look like an email address.")}
        end
    end
  end

  def handle_event("again", _, socket),
    do: {:noreply, assign(socket, sent_to: nil, agentic_file: nil, code_error: nil)}

  @doc false
  # Typing the code instead of clicking the link. A LiveView cannot put anything
  # in the session, so a correct code mints a fresh one-time link and sends the
  # browser through the ordinary sign-in route — the same door, reached from a
  # keyboard.
  def handle_event("code", %{"login" => %{"code" => code}}, socket) do
    email = socket.assigns.sent_to

    case allowed_to_try(socket, email) do
      {:error, {:too_many, seconds}} ->
        {:noreply, assign(socket, code_error: too_many_message(seconds))}

      :ok ->
        case Accounts.verify_sign_in_code(email, code) do
          {:ok, user} ->
            {:noreply, redirect(socket, to: ~p"/login/#{Accounts.create_sign_in_token(user)}")}

          {:error, :too_many} ->
            {:noreply,
             assign(socket,
               code_error: "Too many wrong codes. Ask for a new one.",
               sent_to: nil
             )}

          {:error, :invalid} ->
            {:noreply, assign(socket, code_error: "That code is wrong, or it has expired.")}
        end
    end
  end

  # An address this server will not sign in gets the same screen as one it
  # will: anything else answers "does this person have an account here?" for
  # whoever asks.
  defp send_link(socket, email) do
    case Accounts.deliver_magic_link(email, &url(~p"/login/#{&1}")) do
      {:ok, _} ->
        assign(socket, sent_to: String.downcase(String.trim(email)))

      {:error, :not_allowed} ->
        assign(socket, sent_to: String.downcase(String.trim(email)))

      {:error, %Ecto.Changeset{}} ->
        put_flash(socket, :error, "That doesn't look like an email address.")

      {:error, _} ->
        put_flash(socket, :error, "The sign-in email couldn't be sent. Check the mail settings.")
    end
  end

  # Two counters: one for the address being asked for, one for whoever is
  # asking. Both are recorded before anything is sent, so a refused attempt
  # still costs the asker.
  defp allowed_to_try(socket, email) do
    address = email |> to_string() |> String.trim() |> String.downcase()

    with :ok <- hit("login:email:" <> address, @per_email),
         :ok <- hit("login:ip:" <> socket.assigns.peer, @per_ip) do
      :ok
    else
      {:error, seconds} -> {:error, {:too_many, seconds}}
    end
  end

  defp hit(key, limit), do: RateLimit.hit(key, limit, @window)

  defp too_many_message(seconds) when seconds < 120,
    do: "Too many sign-in attempts. Try again in #{seconds} seconds."

  defp too_many_message(seconds),
    do: "Too many sign-in attempts. Try again in #{div(seconds, 60)} minutes."

  defp peer_ip(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} -> address |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  # What the page says under the nose of the form. It must never say whether a
  # particular address has an account — that answers "who is here" for anybody
  # who asks — but it can say what kind of server this is, which is public
  # anyway and saves people guessing.
  defp strapline(:unclaimed, _fallback?),
    do: "Nobody has set this server up yet. Sign in to claim it."

  defp strapline(:open, true),
    do: "No password. We'll send you a code — or write it where you can read it."

  defp strapline(:open, false), do: "No password. We'll email you a link and a code."

  defp strapline(:approval, _fallback?),
    do: "No password. If you have an account we'll email you a way in."

  defp strapline(_closed_or_allowlist, true),
    do: "No password. Codes are written to the server when there is no mail."

  defp strapline(_closed_or_allowlist, false),
    do: "No password. We'll email you a link and a code."

  # On a server where an admin approves each account, somebody with no account
  # has to be told what to do rather than left typing an address into a form
  # that says nothing.
  defp request_panel(assigns) do
    ~H"""
    <div class="mt-6 border-t border-base-content/10 pt-6">
      <div :if={@requested} class="rounded-xl bg-info/10 p-4 text-sm">
        <p class="font-medium">Your request is with the admin</p>
        <p class="mt-1 text-base-content/70">
          Somebody has to say yes before you can sign in here. You will get an email when
          they do.
        </p>
      </div>

      <.form
        :if={!@requested}
        for={@form}
        id="signup-request-form"
        phx-submit="request"
        class="space-y-3"
      >
        <p class="text-sm text-base-content/70">
          No account yet? On this server an admin approves each one.
        </p>
        <.input
          field={@form[:email]}
          type="email"
          label="Your email"
          placeholder="you@example.com"
          required
        />
        <.input
          field={@form[:note]}
          type="text"
          label="Who are you? (optional)"
          placeholder="Design, starting Monday"
        />
        <button type="submit" class="btn btn-outline w-full">Ask for an account</button>
      </.form>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex h-full items-center justify-center p-6">
        <div class="w-full max-w-sm rounded-2xl bg-base-100 p-8 shadow-sm ring-1 ring-base-content/10">
          <div class="mb-6 flex items-center gap-3">
            <Layouts.brand_mark class="size-12" variant={:detailed} />
            <div>
              <h1 class="text-xl font-bold">Sign in</h1>
              <p class="text-sm text-base-content/60">{strapline(@stance, @fallback?)}</p>
            </div>
          </div>

          <div :if={@sent_to} class="space-y-4">
            <div class="rounded-xl bg-success/10 p-4 text-sm">
              <p class="font-medium">Check your email</p>
              <p class="mt-1 text-base-content/70">
                If <span class="font-medium">{@sent_to}</span>
                can sign in here, a link and a code are on their way. They work once and
                expire in 15 minutes.
              </p>
              <p :if={@fallback?} class="mt-2 text-base-content/70">
                This server has no mail set up, so the code is written to its log instead —
                ask whoever runs it.
              </p>
            </div>
            <.form for={@code_form} id="login-code-form" phx-submit="code" class="space-y-2">
              <.input
                field={@code_form[:code]}
                type="text"
                label="Or type the code from the email"
                inputmode="numeric"
                autocomplete="one-time-code"
                placeholder="123456"
                maxlength={Slipdock.Accounts.UserToken.code_length()}
                pattern="[0-9]*"
              />
              <p :if={@code_error} class="text-sm text-error">{@code_error}</p>
              <button type="submit" class="btn btn-primary w-full">Sign in with the code</button>
            </.form>

            <a :if={@dev_mailbox} href="/dev/mailbox" class="btn btn-outline btn-sm w-full">
              <.icon name="hero-envelope-open" class="size-4" /> Open the local mailbox
            </a>
            <button type="button" class="btn btn-ghost btn-sm w-full" phx-click="again">Use a different email</button>
          </div>

          <div :if={@agentic_file} id="agentic-login-result" class="space-y-4">
            <div class="rounded-xl bg-info/10 p-4 text-sm">
              <p class="font-medium">Agentic sign-in link written</p>
              <p class="mt-1 text-base-content/70">
                A one-time sign-in link has been written to this file on the server.
                Read the file and open the link it contains. It works once and expires in 15 minutes.
              </p>
              <code
                id="agentic-login-file"
                class="mt-3 block select-all break-all rounded-lg bg-base-200 px-3 py-2 font-mono text-xs"
              >{@agentic_file}</code>
            </div>
            <button type="button" class="btn btn-ghost btn-sm w-full" phx-click="again">Start over</button>
          </div>

          <.form
            :if={!@sent_to && !@agentic_file}
            for={@form}
            id="login-form"
            phx-submit="send"
            class="space-y-4"
          >
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              placeholder="you@example.com"
              autocomplete="email"
              phx-hook="Focus"
              required
            />
            <button type="submit" class="btn btn-primary w-full">
              <.icon name="hero-paper-airplane" class="size-4" /> Email me a sign-in link
            </button>
            <button
              :if={@agentic}
              type="submit"
              name="login[mode]"
              value="agentic"
              id="agentic-login"
              class="btn btn-outline btn-sm w-full"
              title="Write the sign-in link to a file on the server instead of emailing it"
            >
              <.icon name="hero-cpu-chip" class="size-4" /> Agentic Login
            </button>
          </.form>

          <p :if={@terms} id="login-terms" class="mt-4 text-center text-xs text-base-content/60">
            By signing in you agree to these
            <a href={@terms.terms_url} target="_blank" rel="noopener" class="link">terms</a>
            <%= if @terms.privacy_url not in [nil, ""] do %>
              and this
              <a href={@terms.privacy_url} target="_blank" rel="noopener" class="link">privacy notice</a>
            <% end %>
          </p>

          <.request_panel
            :if={@stance == :approval && !@sent_to && !@agentic_file}
            form={@request_form}
            requested={@requested}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
