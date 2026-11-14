defmodule SlipdockWeb.AccountLive.Index do
  @moduledoc """
  The account area: a side nav (a picker on a phone) and whichever section
  the URL names, in `SlipdockWeb.SettingsLayout` (#1737). Each section is its
  own component in `SlipdockWeb.AccountLive` — this page only picks one, and
  keeps what they share: the user, and the flash.
  """
  use SlipdockWeb, :live_view

  alias SlipdockWeb.{AccountLive, SettingsLayout}

  @impl true
  def mount(_params, _session, socket) do
    # Not there at all while this server takes no mail.
    inbound? = Slipdock.Inbound.enabled?()

    if socket.assigns.live_action == :email_log and not inbound?,
      do: raise(SlipdockWeb.InboundOff)

    # Each section is its own mount (the nav navigates rather than patches),
    # so a section pays only for its own queries — the one-page version ran
    # all of them to show you a fifth of the result. The component does its
    # own loading when it first renders.
    if socket.assigns.live_action == :machines and connected?(socket),
      do: follow_machines(socket.assigns.current_user)

    {:ok,
     assign(socket,
       page_title: page_title(socket.assigns.live_action),
       sections: sections(inbound?),
       inbound?: inbound?
     )}
  end

  # What the sections send up. A flash (`SlipdockWeb.ComponentFlash.flash/3`,
  # the shape every component's has) is drawn by the layout, which is ours,
  # and a saved user has to reach the header (the name, and where quick add
  # puts things) as well as the section that saved it.
  @impl true
  def handle_info({:put_flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info({:current_user, user}, socket),
    do: {:noreply, assign(socket, current_user: user)}

  # A machine listed on Machines changed elsewhere: renamed over the API or
  # the CLI, say (#2764). The list reads itself again; the daemon's own
  # reports, which come often and change nothing it shows, are let by.
  def handle_info({:config_changed, _machine_id}, socket) do
    send_update(AccountLive.MachinesComponent, id: "account-machines", reload: true)
    {:noreply, socket}
  end

  def handle_info({event, _machine_id}, socket)
      when event in [:config_reported, :probe_changed],
      do: {:noreply, socket}

  # The machines the Machines section lists, yours and those serving a
  # board you're on, followed on each one's topic. One enrolled after the
  # page opened shows on the next visit.
  defp follow_machines(user) do
    for machine <-
          Slipdock.Machines.list_machines(user) ++
            Slipdock.Machines.list_shared_machines(user),
        do: Slipdock.Runners.MachineRunners.subscribe(machine)
  end

  # Every section, in the nav's order: {live action, path, icon, label}. The
  # label is the nav entry, the section's heading and the browser title, so
  # the three cannot drift apart. Email log is there only while the server
  # takes mail.
  defp all_sections do
    [
      {:index, ~p"/account", "hero-user-circle", "Profile"},
      {:settings, ~p"/account/settings", "hero-adjustments-horizontal", "Preferences"},
      {:sign_in, ~p"/account/sign-in", "hero-finger-print", "Sign-in & passkeys"},
      {:tokens, ~p"/account/tokens", "hero-key", "API tokens"},
      {:agent, ~p"/account/agent", "hero-cpu-chip", "Set up an agent"},
      {:machines, ~p"/account/machines", "hero-computer-desktop", "Machines"},
      {:data, ~p"/account/data", "hero-arrows-right-left", "Import & export"},
      {:email_log, ~p"/account/email-log", "hero-inbox-arrow-down", "Email log"}
    ]
  end

  @doc "The account's sections, in order, as the nav lists them."
  def sections(inbound?) do
    for {key, _, _, _} = section <- all_sections(),
        key != :email_log or inbound?,
        do: section
  end

  # The landing section's title is the area's; the rest are named for
  # themselves ("API tokens", not "Account").
  defp page_title(:index), do: "Account"

  defp page_title(action) do
    {_, _, _, label} = List.keyfind(all_sections(), action, 0)
    label
  end

  defp section_component(:settings), do: AccountLive.SettingsComponent
  defp section_component(:sign_in), do: AccountLive.SignInComponent
  defp section_component(:tokens), do: AccountLive.TokensComponent
  defp section_component(:data), do: AccountLive.DataComponent
  defp section_component(:agent), do: AccountLive.AgentComponent
  defp section_component(:machines), do: AccountLive.MachinesComponent
  defp section_component(:email_log), do: AccountLive.InboundLogComponent
  defp section_component(:index), do: AccountLive.ProfileComponent

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
      nav_active={if @live_action == :agent, do: :agent, else: :account}
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <.page width="standard">
          <%!-- One title for every section: the nav says which part you're
               in, and the frame heads the content with the same words. --%>
          <.page_header
            title="Account"
            subtitle="Your profile, preferences, sign-in, tokens and data."
          />
          <SettingsLayout.frame id="account" label="Account" current={@live_action}>
            <:section
              :for={{key, to, icon, label} <- @sections}
              key={key}
              to={to}
              icon={icon}
              label={label}
            />
            <.live_component
              module={section_component(@live_action)}
              id={"account-#{@live_action}"}
              current_user={@current_user}
            />
          </SettingsLayout.frame>
        </.page>
      </div>
    </Layouts.app>
    """
  end
end
