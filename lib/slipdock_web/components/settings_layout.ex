defmodule SlipdockWeb.SettingsLayout do
  @moduledoc """
  One layout for the settings areas, Account and Admin (#1736): a side nav
  listing every section from `md` up, and a section picker at the top on a
  phone, beside a content column sized to what it holds.

  Every section is a link of its own (`navigate`), so each keeps its own
  mount and URL; the current one is marked `aria-current="page"` in both the
  nav and the picker. The picker is a `<details>` disclosure, so it needs no
  script and every section is one tap away. Neither scrolls sideways: the
  nav is a column, however many sections it has.

  The content column opens with the current section's title (an `h2`), so
  the nav, the picker and the heading say the same thing. Put the layout
  inside `<.page>`, under the page's one `page_header`.

  ## Examples

      <.page width="standard">
        <.page_header title="Account" subtitle="..." />
        <SettingsLayout.frame id="account" label="Account" current={@live_action}>
          <:section key={:index} to={~p"/account"} icon="hero-user-circle" label="Profile" />
          <:section key={:tokens} to={~p"/account/tokens"} icon="hero-key" label="API tokens" />
          ...the section's content...
        </SettingsLayout.frame>
      </.page>
  """
  use Phoenix.Component

  import SlipdockWeb.CoreComponents, only: [icon: 1]

  attr :id, :string,
    required: true,
    doc: "names the parts: `<id>-nav`, `<id>-picker` and `<id>-content`"

  attr :label, :string, required: true, doc: "the area's name, the nav's accessible name"
  attr :current, :any, required: true, doc: "the `key` of the section being shown"

  attr :content_width, :string,
    values: ~w(narrow wide),
    default: "narrow",
    doc: "narrow (42rem) for forms; wide for tables and dashboards"

  attr :title, :boolean,
    default: true,
    doc: "false when the section draws its own heading for the section's name"

  slot :section, required: true, doc: "one per section, in order; `:if` drops one" do
    attr :key, :any, required: true
    attr :to, :string, required: true
    attr :icon, :string, required: true
    attr :label, :string, required: true
    attr :group, :string, doc: "a heading drawn above the first section of each group"
  end

  slot :footer, doc: "drawn under the nav from md up, and under the picker's list on a phone"
  slot :inner_block, required: true

  def frame(assigns) do
    assigns = assign(assigns, :active, Enum.find(assigns.section, &(&1.key == assigns.current)))

    ~H"""
    <div
      id={@id}
      data-settings-layout
      class="md:grid md:grid-cols-[12rem_minmax(0,1fr)] md:items-start md:gap-8 lg:grid-cols-[13rem_minmax(0,1fr)] lg:gap-10"
    >
      <details
        id={"#{@id}-picker"}
        data-role="settings-picker"
        class="group mb-6 rounded-xl bg-base-100 shadow-sm ring-1 ring-base-content/10 md:hidden"
      >
        <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-2.5 text-sm font-medium [&::-webkit-details-marker]:hidden">
          <span class="text-base-content/60">{@label}</span>
          <.icon name="hero-chevron-right-mini" class="size-4 text-base-content/40" />
          <.icon :if={@active} name={@active.icon} class="size-4 text-primary" />
          <span :if={@active} class="truncate">{@active.label}</span>
          <.icon
            name="hero-chevron-down"
            class="ml-auto size-4 shrink-0 text-base-content/60 transition group-open:rotate-180"
          />
        </summary>
        <nav aria-label={"#{@label} sections"} class="border-t border-base-content/10 p-1">
          <.section_list sections={@section} current={@current} />
        </nav>
        <div :if={@footer != []} class="border-t border-base-content/10 p-3 text-xs">
          {render_slot(@footer)}
        </div>
      </details>

      <nav
        id={"#{@id}-nav"}
        aria-label={@label}
        data-role="settings-nav"
        class="hidden md:sticky md:top-6 md:block"
      >
        <.section_list sections={@section} current={@current} />
        <div
          :if={@footer != []}
          data-role="settings-nav-footer"
          class="mt-6 border-t border-base-content/10 pt-4 text-xs"
        >
          {render_slot(@footer)}
        </div>
      </nav>

      <div
        id={"#{@id}-content"}
        data-role="settings-content"
        data-content-width={@content_width}
        class={["min-w-0", @content_width == "narrow" && "max-w-2xl"]}
      >
        <h2
          :if={@title && @active}
          data-role="settings-section-title"
          class="mb-6 text-lg font-semibold"
        >
          {@active.label}
        </h2>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :sections, :list, required: true
  attr :current, :any, required: true

  defp section_list(assigns) do
    ~H"""
    <ul class="space-y-0.5 text-sm">
      <%= for {section, i} <- Enum.with_index(@sections) do %>
        <li
          :if={new_group?(@sections, i)}
          data-role="settings-group"
          class={[
            "px-3 pb-1 text-xs font-medium uppercase tracking-wide text-base-content/50",
            i > 0 && "pt-4"
          ]}
        >
          {section.group}
        </li>
        <li>
          <.link
            navigate={section.to}
            aria-current={section.key == @current && "page"}
            data-section={section.key}
            class={[
              "flex items-center gap-2 rounded-lg px-3 py-2 font-medium",
              (section.key == @current && "bg-primary/10 text-primary") ||
                "text-base-content/70 hover:bg-base-200/70 hover:text-base-content"
            ]}
          >
            <.icon name={section.icon} class="size-4 shrink-0" />
            <span class="min-w-0">{section.label}</span>
          </.link>
        </li>
      <% end %>
    </ul>
    """
  end

  # A group heading goes above a section whose group differs from the one
  # before it; the first section's group always gets one.
  defp new_group?(sections, i) do
    group = Enum.at(sections, i)[:group]
    group != nil and (i == 0 or Enum.at(sections, i - 1)[:group] != group)
  end
end
