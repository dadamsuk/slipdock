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
    voiceprints? = Slipdock.Meetings.Voiceprints.enabled_for?(socket.assigns.current_user)

    # Not there at all while voiceprints are off, like every meeting page.
    if socket.assigns.live_action == :voiceprint and not voiceprints?,
      do: raise(SlipdockWeb.MeetingsOff)

    # The same for the email log while this server takes no mail.
    inbound? = Slipdock.Inbound.enabled?()

    if socket.assigns.live_action == :email_log and not inbound?,
      do: raise(SlipdockWeb.InboundOff)

    # Each section is its own mount (the nav navigates rather than patches),
    # so a section pays only for its own queries — the one-page version ran
    # all of them to show you a fifth of the result. The component does its
    # own loading when it first renders.
    {:ok,
     assign(socket,
       page_title: page_title(socket.assigns.live_action),
       sections: sections(voiceprints?, inbound?),
       voiceprints?: voiceprints?,
       inbound?: inbound?
     )}
  end

  # What the sections send up. A flash is drawn by the layout, which is ours,
  # and a saved user has to reach the header (the name, and where quick add
  # puts things) as well as the section that saved it.
  @impl true
  def handle_info({:flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info({:current_user, user}, socket),
    do: {:noreply, assign(socket, current_user: user)}

  # Every section, in the nav's order: {live action, path, icon, label}. The
  # label is the nav entry, the section's heading and the browser title, so
  # the three cannot drift apart. Voiceprint and Email log are there only
  # while the server has them on.
  defp all_sections do
    [
      {:index, ~p"/account", "hero-user-circle", "Profile"},
      {:settings, ~p"/account/settings", "hero-adjustments-horizontal", "Preferences"},
      {:sign_in, ~p"/account/sign-in", "hero-finger-print", "Sign-in & passkeys"},
      {:tokens, ~p"/account/tokens", "hero-key", "API tokens"},
      {:agent, ~p"/account/agent", "hero-cpu-chip", "Set up an agent"},
      {:data, ~p"/account/data", "hero-arrows-right-left", "Import & export"},
      {:voiceprint, ~p"/account/voiceprint", "hero-microphone", "Voiceprint"},
      {:email_log, ~p"/account/email-log", "hero-inbox-arrow-down", "Email log"}
    ]
  end

  @doc "The account's sections, in order, as the nav lists them."
  def sections(voiceprints?, inbound?) do
    for {key, _, _, _} = section <- all_sections(),
        key != :voiceprint or voiceprints?,
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
  defp section_component(:voiceprint), do: AccountLive.VoiceprintComponent
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
