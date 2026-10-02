defmodule SlipdockWeb.TermsLive.Index do
  @moduledoc """
  Agreeing to the server's terms, for a server that has any.

  Shown **after** signing in rather than as a tick-box on the sign-in form,
  which is deliberate: the sign-in form must not reveal whether an address has
  an account here, and anything extra on it is another thing that could. It
  also means a version bump asks everybody again rather than only new arrivals.

  A self-hosted instance has no terms, so nobody ever sees this.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Accounts, Settings}

  def on_mount(:ensure_terms_accepted, _params, _session, socket) do
    if Accounts.terms_outstanding?(socket.assigns[:current_user]) do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/terms")}
    else
      {:cont, socket}
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.terms_outstanding?(socket.assigns.current_user) do
      {:ok, assign(socket, page_title: "Terms", settings: Settings.get())}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("accept", _params, socket) do
    {:ok, _} = Accounts.accept_terms(socket.assigns.current_user)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex h-full items-center justify-center p-6">
        <div class="w-full max-w-md rounded-2xl bg-base-100 p-8 shadow-sm ring-1 ring-base-content/10">
          <h1 class="text-xl font-bold">Before you carry on</h1>
          <p class="mt-2 text-sm text-base-content/70">
            {if @current_user.terms_accepted_at,
              do: "The terms for this server have changed since you last agreed to them.",
              else: "This server has terms and a privacy notice. Please read them."}
          </p>

          <ul class="mt-4 space-y-2 text-sm">
            <li>
              <a href={@settings.terms_url} target="_blank" rel="noopener" class="link link-primary">
                <.icon name="hero-document-text" class="size-4" /> Terms of service
              </a>
            </li>
            <li :if={@settings.privacy_url}>
              <a href={@settings.privacy_url} target="_blank" rel="noopener" class="link link-primary">
                <.icon name="hero-shield-check" class="size-4" /> Privacy notice
              </a>
            </li>
          </ul>

          <button phx-click="accept" class="btn btn-primary mt-6 w-full">
            I agree
          </button>

          <p class="mt-3 text-center text-xs text-base-content/50">
            Not willing to? <.link href={~p"/logout"} method="delete" class="link">Sign out</.link>
            — nothing of yours is touched.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
