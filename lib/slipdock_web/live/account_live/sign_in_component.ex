defmodule SlipdockWeb.AccountLive.SignInComponent do
  @moduledoc """
  Account › Sign-in & passkeys (#1737): the ways you sign in (passkeys, on
  top of the emailed link) and the way out. They were the middle of the
  Profile section until the account area had a side nav to put them in.
  """
  use SlipdockWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <.live_component
        module={SlipdockWeb.AccountLive.PasskeysComponent}
        id="account-passkeys"
        current_user={@current_user}
      />

      <section
        id="account-session"
        class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
      >
        <h2 class="section-title">Session</h2>
        <p class="text-sm text-base-content/60">
          Signing in, by link or passkey, keeps you signed in for 30 days on this browser.
        </p>
        <.link href={~p"/logout"} method="delete" class="btn btn-sm mt-4">
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Sign out
        </.link>
      </section>
    </div>
    """
  end
end
