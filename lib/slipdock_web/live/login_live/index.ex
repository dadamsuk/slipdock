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
       code_form: to_form(%{"code" => ""}, as: :login),
       code_error: nil,
       agentic_file: nil,
       agentic: Accounts.agentic_login_enabled?(),
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
              <p class="text-sm text-base-content/60">No password. We'll email you a link.</p>
            </div>
          </div>

          <div :if={@sent_to} class="space-y-4">
            <div class="rounded-xl bg-success/10 p-4 text-sm">
              <p class="font-medium">Check your email</p>
              <p class="mt-1 text-base-content/70">
                If <span class="font-medium">{@sent_to}</span>
                can sign in here, a link is on its way. It works once and expires in
                15 minutes.
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
        </div>
      </div>
    </Layouts.app>
    """
  end
end
