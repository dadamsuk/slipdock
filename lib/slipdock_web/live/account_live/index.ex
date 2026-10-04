defmodule SlipdockWeb.AccountLive.Index do
  @moduledoc """
  The account area: the tab bar, and whichever tab the URL names. Each tab is
  its own component in `SlipdockWeb.AccountLive` — this page only picks one,
  and keeps what they share: the user, and the flash.
  """
  use SlipdockWeb, :live_view

  alias SlipdockWeb.AccountLive

  @impl true
  def mount(_params, _session, socket) do
    # Each tab is its own mount (the tab bar navigates rather than patches),
    # so a tab pays only for its own queries — the one-page version ran all
    # of them to show you a fifth of the result. The component does its own
    # loading when it first renders.
    {:ok, assign(socket, page_title: tab_title(socket.assigns.live_action))}
  end

  # What the tabs send up. A flash is drawn by the layout, which is ours, and
  # a saved user has to reach the header (the name, and where quick add puts
  # things) as well as the tab that saved it.
  @impl true
  def handle_info({:flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info({:current_user, user}, socket),
    do: {:noreply, assign(socket, current_user: user)}

  # One label per tab, used for the title, the breadcrumb and the tab itself,
  # so the three cannot drift apart.
  defp tab_title(:settings), do: "Settings"
  defp tab_title(:tokens), do: "API tokens"
  defp tab_title(:data), do: "Import & export"
  defp tab_title(:agent), do: "Set up an agent"
  defp tab_title(_), do: "Account"

  defp tab_component(:settings), do: AccountLive.SettingsComponent
  defp tab_component(:tokens), do: AccountLive.TokensComponent
  defp tab_component(:data), do: AccountLive.DataComponent
  defp tab_component(:agent), do: AccountLive.AgentComponent
  defp tab_component(_), do: AccountLive.ProfileComponent

  attr :to, :string, required: true
  attr :active, :boolean, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp account_tab(assigns) do
    ~H"""
    <.link
      navigate={@to}
      aria-current={@active && "page"}
      class={[
        "flex flex-1 items-center justify-center gap-1.5 whitespace-nowrap rounded-xl px-3 py-2 font-medium",
        (@active && "bg-primary/10 text-primary") ||
          "text-base-content/60 hover:bg-base-200/70 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
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
      nav_active={:account}
    >
      <:nav><span class="font-semibold">{tab_title(@live_action)}</span></:nav>
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-2xl space-y-8 px-4 py-6 sm:py-10 sm:px-6">
          <nav
            id="account-tabs"
            aria-label="Account"
            class="flex gap-1 overflow-x-auto rounded-2xl bg-base-100 p-1 text-sm shadow-sm ring-1 ring-base-content/10"
          >
            <.account_tab
              to={~p"/account"}
              active={@live_action == :index}
              icon="hero-user-circle"
              label="Account"
            />
            <.account_tab
              to={~p"/account/settings"}
              active={@live_action == :settings}
              icon="hero-adjustments-horizontal"
              label="Settings"
            />
            <.account_tab
              to={~p"/account/tokens"}
              active={@live_action == :tokens}
              icon="hero-key"
              label="API tokens"
            />
            <.account_tab
              to={~p"/account/data"}
              active={@live_action == :data}
              icon="hero-arrows-right-left"
              label="Import & export"
            />
            <.account_tab
              to={~p"/account/agent"}
              active={@live_action == :agent}
              icon="hero-cpu-chip"
              label="Set up an agent"
            />
          </nav>

          <.live_component
            module={tab_component(@live_action)}
            id={"account-#{@live_action}"}
            current_user={@current_user}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
