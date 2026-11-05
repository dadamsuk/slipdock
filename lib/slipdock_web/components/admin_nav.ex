defmodule SlipdockWeb.AdminNav do
  @moduledoc """
  The Admin area (#1738): every admin page in `SettingsLayout.frame/1`, with
  one nav built here, so the pages can't list different entries.

  Each admin LiveView renders `frame/1` with its own key:

      <AdminNav.frame current={:people}>
        ...the section's content...
      </AdminNav.frame>

  which draws the full-width page, its one `page_header` ("Admin"), the nav
  (grouped Accounts, Configuration and Review), the section's `h2`, and the
  "Running build" strip in the nav's footer. The Configuration forms get the
  narrow content column; tables and dashboards get the wide one.

  Sign-ups is listed while sign-up is by approval (when there can be anybody
  to approve), and on its own page whatever the mode, so the page you are on
  is always in the nav. Sign-ups and Tools carry the count waiting for you,
  as the avatar menu's Admin group does.
  """
  use Phoenix.Component
  use SlipdockWeb, :verified_routes

  import SlipdockWeb.CoreComponents, only: [icon: 1, page: 1, page_header: 1]

  alias Slipdock.{Build, Settings}
  alias SlipdockWeb.SettingsLayout

  # {key, path, icon, label, group, content width}, in the nav's order.
  defp all do
    [
      {:people, ~p"/users", "hero-users", "People", "Accounts", "wide"},
      {:signups, ~p"/users/signups", "hero-user-plus", "Sign-ups", "Accounts", "wide"},
      {:overview, ~p"/overview", "hero-chart-bar", "Overview", "Accounts", "wide"},
      {:server, ~p"/config", "hero-server-stack", "Server", "Configuration", "narrow"},
      {:mail, ~p"/config/mail", "hero-envelope", "Email", "Configuration", "narrow"},
      {:meetings, ~p"/config/meetings", "hero-video-camera", "Meetings", "Configuration",
       "narrow"},
      {:ai, ~p"/config/ai", "hero-sparkles", "AI", "Configuration", "narrow"},
      {:tools, ~p"/admin/tools", "hero-puzzle-piece", "Tools", "Review", "wide"}
    ]
  end

  @doc "Every Admin section's key, in the nav's order."
  def keys, do: Enum.map(all(), &elem(&1, 0))

  @doc "A section's label: its nav entry, its heading and the browser's title."
  def label(key) do
    {_, _, _, label, _, _} = List.keyfind(all(), key, 0)
    label
  end

  @doc """
  The sections the nav lists, as `{key, path, icon, label, group}`. Sign-ups
  only while sign-up is by approval, or while it is the page being shown.
  """
  def sections(current, signup_mode) do
    for {key, path, icon, label, group, _} <- all(),
        key != :signups or signup_mode == :approval or current == :signups,
        do: {key, path, icon, label, group}
  end

  @doc "The content column's width for a section: narrow for forms, wide for tables."
  def content_width(key) do
    {_, _, _, _, _, width} = List.keyfind(all(), key, 0)
    width
  end

  attr :current, :atom, required: true, doc: "the section being shown, one of `keys/0`"
  slot :inner_block, required: true

  def frame(assigns) do
    signup_mode = Settings.signup_mode()

    assigns =
      assign(assigns,
        sections: sections(assigns.current, signup_mode),
        width: content_width(assigns.current),
        badges: %{
          signups:
            if(signup_mode == :approval, do: Slipdock.Accounts.count_pending_signups(), else: 0),
          tools: length(Slipdock.Tools.listing_queue())
        }
      )

    ~H"""
    <.page width="full">
      <.page_header
        title="Admin"
        subtitle="Who uses this server, how it runs, and the Tools listed on it."
      />
      <SettingsLayout.frame id="admin" label="Admin" current={@current} content_width={@width}>
        <:section
          :for={{key, to, icon, label, group} <- @sections}
          key={key}
          to={to}
          icon={icon}
          label={label}
          group={group}
          badge={Map.get(@badges, key, 0)}
        />
        <:footer><.build_strip /></:footer>
        {render_slot(@inner_block)}
      </SettingsLayout.frame>
    </.page>
    """
  end

  # Which build is running, on every admin page: the first question worth
  # asking of a server behaving unexpectedly is whether it is the one you
  # think. Frozen at compile time on purpose (see `Slipdock.Build`). Drawn
  # twice (the nav and the phone's picker), so it has no id.
  defp build_strip(assigns) do
    assigns = assign(assigns, build: Build.info())

    ~H"""
    <dl data-role="build-info" class="space-y-1.5">
      <dt class="flex items-center gap-1.5 font-medium text-base-content/60">
        <.icon name="hero-cube" class="size-4 text-base-content/50" /> Running build
      </dt>
      <dd>
        <span class="text-base-content/60">Built</span>
        <span class="font-mono">{Build.built_at_string()} UTC</span>
      </dd>
      <dd>
        <span class="text-base-content/60">Commit</span>
        <span class="font-mono" title={@build.git_sha}>{@build.git_short_sha}</span>
        <span
          :if={@build.git_dirty}
          class="badge badge-xs badge-warning ml-1"
          title="There were uncommitted changes when this was compiled."
        >
          modified
        </span>
      </dd>
      <dd>
        <span class="text-base-content/60">Version</span>
        <span class="font-mono">{@build.version}</span>
      </dd>
    </dl>
    """
  end
end
