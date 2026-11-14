defmodule SlipdockWeb.SlipdockComponents.Marks do
  @moduledoc "The small marks drawn on a card and around it: priority bars, flags, tags, colour swatches and the people it is assigned to."
  use Phoenix.Component

  alias Slipdock.Palette

  import SlipdockWeb.CoreComponents, only: [icon: 1]

  ## Priority --------------------------------------------------------------

  # Priority draws as one family, signal bars (#1709): one bar lit for low,
  # two for medium, three for high, all four for critical. The same mark is
  # used on the card face, the outline, the table, the calendar and the
  # filter menu, so a priority looks the same wherever it is read.
  @priorities %{
    "none" => {"None", 0, nil},
    "low" => {"Low", 1, "text-sky-600 dark:text-sky-300"},
    "medium" => {"Medium", 2, "text-amber-600 dark:text-amber-300"},
    "high" => {"High", 3, "text-orange-600 dark:text-orange-300"},
    "critical" => {"Critical", 4, "text-rose-600 dark:text-rose-300"}
  }

  def priority_options, do: Enum.map(~w(none low medium high critical), &{priority_label(&1), &1})
  def priority_label(p), do: @priorities |> Map.fetch!(p) |> elem(0)

  @doc "How many of the four signal bars a priority lights: 0 for none (or an unknown value), 4 for critical."
  def priority_level(p) do
    case Map.fetch(@priorities, p) do
      {:ok, {_, level, _}} -> level
      :error -> 0
    end
  end

  @doc """
  Whether a priority is drawn where a card is shown on its own (the card
  face, the outline, the calendar). Medium is the default most cards carry,
  so it says nothing there; it is drawn only where every priority is listed,
  such as the table and the filter menu (#1708, #1709).
  """
  def priority_on_face?(p), do: priority_level(p) > 0 and p != "medium"

  attr :level, :integer, required: true, doc: "bars lit, 0 to 4"
  attr :class, :string, default: "size-3.5"

  @doc "Four signal bars, rising left to right, with `level` of them lit."
  def priority_bars(assigns) do
    ~H"""
    <svg
      viewBox="0 0 16 16"
      class={["shrink-0", @class]}
      fill="currentColor"
      aria-hidden="true"
      data-role="priority-bars"
      data-level={@level}
    >
      <rect
        :for={i <- 1..4}
        x={1 + (i - 1) * 3.75}
        y={14 - i * 3}
        width="2.5"
        height={i * 3}
        rx="0.6"
        data-lit={to_string(i <= @level)}
        opacity={if i <= @level, do: "1", else: "0.25"}
      />
    </svg>
    """
  end

  attr :priority, :string, required: true
  attr :with_label, :boolean, default: false

  @doc """
  A priority as signal bars, with a tooltip naming it ("Priority: High").
  No priority, nil or a value it doesn't know draws nothing, bar the "No
  priority" label when `with_label` asks for one.
  """
  def priority_badge(%{priority: p} = assigns)
      when not is_map_key(@priorities, p) or p == "none" do
    ~H"""
    <span :if={@with_label} class="text-xs opacity-50">No priority</span>
    """
  end

  def priority_badge(assigns) do
    {label, level, color} = Map.fetch!(@priorities, assigns.priority)
    assigns = assign(assigns, label: label, level: level, color: color)

    ~H"""
    <span
      class={["chip chip-tint", !@with_label && "chip-icon", @color]}
      title={"Priority: #{@label}"}
      role="img"
      aria-label={"Priority: #{@label}"}
      data-role="priority"
      data-priority={@priority}
    >
      <.priority_bars level={@level} />
      <span :if={@with_label} aria-hidden="true">{@label}</span>
    </span>
    """
  end

  attr :id, :string, required: true, doc: "the form's id, which must be unique on the page"
  attr :card_id, :string, required: true, doc: "the card's `item_id/1`, sent as `card_id`"
  attr :priority, :string, required: true, doc: "the card's priority now"
  attr :label, :string, default: "Priority", doc: "the select's accessible name"

  @doc """
  A card's priority as a select that saves when it changes (#2892): the
  table's Priority cell and both of Prioritise's layouts.

  It is a `table_update` form sending `card_id`, `field=priority` and the
  chosen `value`. The select has no visible label where it is drawn (a column
  or a `<dt>` names it by sight), so `label` is its `aria-label`.
  """
  def priority_select(assigns) do
    ~H"""
    <form phx-change="table_update" phx-submit="table_update" id={@id}>
      <input type="hidden" name="card_id" value={@card_id} />
      <input type="hidden" name="field" value="priority" />
      <select name="value" class="select field-bare w-28" aria-label={@label}>
        <option
          :for={{label, value} <- priority_options()}
          value={value}
          selected={value == @priority}
        >
          {label}
        </option>
      </select>
    </form>
    """
  end

  ## Flags ------------------------------------------------------------------

  @flags [
    {"flagged", "Flagged", "hero-flag-solid", "text-rose-600 dark:text-rose-300",
     "bg-rose-100 text-rose-700 ring-rose-200 dark:bg-rose-400/20 dark:text-rose-200 dark:ring-rose-400/30"},
    {"blocked", "Blocked", "hero-no-symbol", "text-red-600 dark:text-red-300",
     "bg-red-100 text-red-700 ring-red-200 dark:bg-red-400/20 dark:text-red-200 dark:ring-red-400/30"},
    {"review", "Needs review", "hero-eye", "text-violet-600 dark:text-violet-300",
     "bg-violet-100 text-violet-700 ring-violet-200 dark:bg-violet-400/20 dark:text-violet-200 dark:ring-violet-400/30"},
    {"waiting", "Waiting", "hero-clock", "text-amber-600 dark:text-amber-300",
     "bg-amber-100 text-amber-700 ring-amber-200 dark:bg-amber-400/20 dark:text-amber-200 dark:ring-amber-400/30"},
    {"starred", "Starred", "hero-star-solid", "text-yellow-600 dark:text-yellow-300",
     "bg-yellow-100 text-yellow-700 ring-yellow-200 dark:bg-yellow-400/20 dark:text-yellow-200 dark:ring-yellow-400/30"},
    {"stuck", "Stuck", "hero-lifebuoy", "text-orange-600 dark:text-orange-300",
     "bg-orange-100 text-orange-700 ring-orange-200 dark:bg-orange-400/20 dark:text-orange-200 dark:ring-orange-400/30"}
  ]

  def flags, do: @flags
  def flag_label(flag), do: @flags |> List.keyfind!(flag, 0) |> elem(1)

  @doc """
  A flag's icon. Given the `card` it is on, it also says who clears it
  (`Slipdock.Attention`, #2624): filled with a solid icon when a person has
  to act, outline only when the board's own processes clear it, plain for a
  mark that asks nothing; the tooltip and an `sr-only` line say which.
  Without a card it is drawn filled, as it always was.
  """
  attr :flag, :string, required: true
  attr :card, :any, default: nil
  attr :class, :string, default: "size-4"

  def flag_icon(assigns) do
    {_, label, icon, color, _} = List.keyfind!(@flags, assigns.flag, 0)
    {attention, why} = flag_attention(assigns.flag, assigns.card)

    assigns =
      assign(assigns,
        label: label,
        icon_name: flag_icon_name(icon, attention),
        color: color,
        attention: attention,
        tip: flag_tip(label, attention, why)
      )

    ~H"""
    <span
      class={["chip chip-icon", flag_chip_class(@attention), @color]}
      title={@tip}
      data-role="flag"
      data-flag={@flag}
      data-attention={@attention}
    >
      <.icon name={@icon_name} class={@class} />
      <span class="sr-only">{@tip}</span>
    </span>
    """
  end

  @doc "`{attention, why}` for a flag, or `{nil, nil}` with no card to read it from."
  def flag_attention(_flag, nil), do: {nil, nil}
  def flag_attention(flag, card), do: Slipdock.Attention.of(flag, card)

  @doc "The words that say who clears a flag: the tooltip, the `sr-only` line, the card panel's chip."
  def flag_tip(label, "person", why), do: "#{label} · Needs a person: #{why}"
  def flag_tip(label, "auto", why), do: "#{label} · Clears itself: #{why}"
  def flag_tip(label, "none", why), do: "#{label} · #{why}"
  def flag_tip(label, _attention, _why), do: label

  @doc "A flag's chip fill: outline only for one that clears itself, filled otherwise."
  def flag_chip_class("auto"), do: "chip-auto"
  def flag_chip_class(_attention), do: "chip-tint"

  @doc "A flag's icon: the solid one where a person must act, the outline one where it clears itself."
  def flag_icon_name(icon, "person"), do: solid_icon(icon)
  def flag_icon_name(icon, "auto"), do: String.replace_suffix(icon, "-solid", "")
  def flag_icon_name(icon, _attention), do: icon

  defp solid_icon(icon),
    do: if(String.ends_with?(icon, "-solid"), do: icon, else: icon <> "-solid")

  attr :flag, :string, required: true
  attr :active, :boolean, default: false
  attr :rest, :global

  def flag_toggle(assigns) do
    {_, label, icon, color, active_cls} = List.keyfind!(@flags, assigns.flag, 0)
    assigns = assign(assigns, label: label, icon_name: icon, color: color, active_cls: active_cls)

    ~H"""
    <button
      type="button"
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ring-1 transition",
        if(@active,
          do: @active_cls,
          else: "ring-base-content/10 text-base-content/60 hover:bg-base-200 hover:text-base-content"
        )
      ]}
      aria-pressed={to_string(@active)}
      {@rest}
    >
      <.icon name={@icon_name} class={["size-3.5", @active && @color]} />
      {@label}
    </button>
    """
  end

  ## Tags -------------------------------------------------------------------

  attr :tag, :map, required: true
  attr :size, :string, default: "sm"
  attr :rest, :global

  def tag_chip(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 rounded-md font-medium leading-none",
        @size == "xs" && "px-1.5 py-0.5 text-2xs",
        @size == "sm" && "px-2 py-1 text-xs",
        Palette.chip(@tag.color)
      ]}
      {@rest}
    >
      {@tag.name}
    </span>
    """
  end

  attr :tag, :map, required: true
  attr :active, :boolean, default: false
  attr :rest, :global

  @doc """
  A tag as a toggle, styled like `flag_toggle/1`: a muted outlined pill with
  the tag's colour as a dot, filling with the tag's colour when active.
  """
  def tag_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ring-1 transition",
        if(@active,
          do: [Palette.chip(@tag.color), "ring-transparent"],
          else: "ring-base-content/10 text-base-content/60 hover:bg-base-200 hover:text-base-content"
        )
      ]}
      aria-pressed={to_string(@active)}
      title={if @active, do: "Remove tag", else: "Add tag"}
      {@rest}
    >
      <.icon :if={@active} name="hero-check" class="size-3.5" />
      <span :if={!@active} class={["size-2 rounded-full", Palette.dot(@tag.color)]}></span>
      {@tag.name}
    </button>
    """
  end

  attr :color, :any,
    required: true,
    doc: "a `Slipdock.Palette` name, or nil for the \"none\" swatch"

  attr :selected, :boolean, default: false
  attr :class, :string, default: "size-6"

  attr :label, :string,
    default: nil,
    doc: "its `title` and `aria-label`: the colour's name unless given (\"None\" for nil)"

  attr :rest, :global, include: ~w(popovertarget popovertargetaction)

  @doc """
  One colour of a picker, as a round button: every colour picker's swatch
  (#2888). Its `title` and `aria-label` are the colour's name, `aria-pressed`
  says whether it is the one chosen, and the caller's `phx-click` (and a
  popover's `popovertarget`) pass through.

  `color={nil}` is the "none" swatch, a struck-through circle, for a picker
  whose colour can be cleared; give it a `label` saying what none means
  there ("No cover").
  """
  def color_swatch(%{color: nil} = assigns) do
    ~H"""
    <button
      type="button"
      class={[
        @class,
        "flex items-center justify-center rounded-full ring-1 ring-base-content/20 ring-offset-2 ring-offset-base-100",
        @selected && "ring-2 ring-base-content"
      ]}
      title={@label || "None"}
      aria-label={@label || "None"}
      aria-pressed={to_string(@selected)}
      data-swatch="none"
      {@rest}
    >
      <.icon name="hero-no-symbol" class="size-3/5 opacity-50" />
    </button>
    """
  end

  def color_swatch(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        @class,
        "rounded-full ring-offset-2 ring-offset-base-100 transition hover:scale-110",
        Palette.dot(@color),
        @selected && "ring-2 ring-base-content"
      ]}
      title={@label || Palette.label(@color)}
      aria-label={@label || Palette.label(@color)}
      aria-pressed={to_string(@selected)}
      data-swatch={@color}
      {@rest}
    ></button>
    """
  end

  ## Assignees --------------------------------------------------------------

  attr :user, :any, required: true, doc: "a `User`, or nil for someone unknown (drawn as ?)"
  attr :size, :string, default: "sm", values: ~w(xs sm md)
  attr :class, :any, default: nil
  attr :rest, :global

  @doc """
  A person's initials in a circle of their own colour (#1696):
  `Slipdock.Palette.person/1`, a chip tint picked by their user id, so they
  are the same colour on a card, in the header, the share list and the
  comments. At `xs` (16px) there is room for one initial only.
  """
  def avatar(assigns) do
    user = assigns.user
    initials = if user, do: Slipdock.Accounts.User.initials(user), else: "?"
    initials = if assigns.size == "xs", do: String.first(initials) || "?", else: initials

    assigns =
      assign(assigns,
        initials: if(initials == "", do: "?", else: initials),
        colour: Palette.person(user && user.id)
      )

    ~H"""
    <span
      class={[
        "avatar-initials inline-flex shrink-0 select-none items-center justify-center rounded-full font-semibold uppercase leading-none",
        @colour,
        @size == "xs" && "size-4 text-2xs",
        @size == "sm" && "size-6 text-2xs",
        @size == "md" && "size-8 text-xs",
        @class
      ]}
      data-colour={Palette.person_colour(@user && @user.id)}
      {@rest}
    >
      {@initials}
    </span>
    """
  end

  attr :user, :map, required: true
  attr :size, :string, default: "sm"
  attr :with_name, :boolean, default: false

  @doc "An initials avatar for the card's assignee."
  def assignee_chip(assigns) do
    assigns = assign(assigns, :name, Slipdock.Accounts.User.display_name(assigns.user))

    ~H"""
    <span class="inline-flex items-center gap-1" title={"Assigned to #{@name}"}>
      <.avatar user={@user} size={@size} />
      <span :if={@with_name} class="truncate text-sm">{@name}</span>
    </span>
    """
  end

  attr :users, :list, required: true
  attr :size, :string, default: "sm"
  attr :with_name, :boolean, default: false
  attr :max, :integer, default: 3

  @doc """
  Everybody a card is assigned to, as overlapping initials avatars, the lead
  first; past `max` the rest are counted rather than drawn. One person is
  drawn exactly as `assignee_chip/1` draws them.
  """
  def assignee_chips(%{users: [user]} = assigns) do
    assigns = assign(assigns, :user, user)

    ~H"""
    <.assignee_chip user={@user} size={@size} with_name={@with_name} />
    """
  end

  def assignee_chips(assigns) do
    names = Enum.map_join(assigns.users, ", ", &Slipdock.Accounts.User.display_name/1)

    assigns =
      assign(assigns,
        names: names,
        shown: Enum.take(assigns.users, assigns.max),
        more: max(length(assigns.users) - assigns.max, 0)
      )

    ~H"""
    <span :if={@users != []} class="inline-flex items-center gap-1" title={"Assigned to #{@names}"}>
      <span class="inline-flex -space-x-1">
        <.avatar :for={user <- @shown} user={user} size={@size} class="ring-1 ring-base-100" />
        <span
          :if={@more > 0}
          class={[
            "inline-flex shrink-0 items-center justify-center rounded-full bg-base-300 font-semibold text-base-content/70 ring-1 ring-base-100",
            @size == "xs" && "size-4 text-2xs",
            @size == "sm" && "size-6 text-2xs"
          ]}
        >
          +{@more}
        </span>
      </span>
      <span :if={@with_name} class="truncate text-sm">{@names}</span>
    </span>
    """
  end
end
