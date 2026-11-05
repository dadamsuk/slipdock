defmodule SlipdockWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: SlipdockWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :auto_dismiss, :boolean, default: false, doc: "close by itself after a few seconds"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook={@auto_dismiss && "AutoDismiss"}
      role="alert"
      class="toast toast-bottom toast-start z-50 p-4"
      {@rest}
    >
      <div class="kanban-toast-in flex w-80 max-w-[calc(100vw-2rem)] items-start gap-3 rounded-box bg-base-100 p-3.5 text-sm text-base-content shadow-xl ring-1 ring-base-content/10 sm:w-96">
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="size-5 shrink-0 text-primary"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="size-5 shrink-0 text-error"
        />
        <div class="min-w-0 flex-1 text-wrap">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <button
          type="button"
          class="group -m-1 shrink-0 cursor-pointer rounded-md p-1 hover:bg-base-200"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-4 opacity-50 group-hover:opacity-100" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  A notice set into the page (#1697): an icon and one flowing block of text,
  so inline `<code>` and links stay in the sentence rather than becoming
  flex columns. The text is base-content on a tinted surface with a tinted
  left rule, which keeps it AA in both themes; the kind only colours the
  surface, the rule and the icon.

  ## Examples

      <.callout kind={:warning}>Run <code>mix slipdock.reindex</code> on the server.</.callout>
      <.callout kind={:error} title="Couldn't save">The board is archived.</.callout>
  """
  attr :id, :string, default: nil
  attr :kind, :atom, values: [:info, :warning, :error], default: :info
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def callout(assigns) do
    ~H"""
    <div
      id={@id}
      role={if @kind == :info, do: "note", else: "alert"}
      data-callout={@kind}
      class={[
        "flex items-start gap-3 rounded-r-box border-l-4 px-4 py-3 text-sm text-base-content",
        callout_tone(@kind),
        @class
      ]}
      {@rest}
    >
      <.icon name={callout_icon(@kind)} class={["mt-0.5 size-4 shrink-0", callout_icon_tone(@kind)]} />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="font-semibold">{@title}</p>
        <div class="[&_code]:font-mono [&_code]:text-xs">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  defp callout_tone(:info), do: "border-info bg-info/10"
  defp callout_tone(:warning), do: "border-warning bg-warning/10"
  defp callout_tone(:error), do: "border-error bg-error/10"

  defp callout_icon(:info), do: "hero-information-circle"
  defp callout_icon(:warning), do: "hero-exclamation-triangle"
  defp callout_icon(:error), do: "hero-exclamation-circle"

  # The icon carries the kind's colour; the text never does (it would fail
  # contrast on its own tint).
  defp callout_icon_tone(:info), do: "text-info"
  defp callout_icon_tone(:warning), do: "text-warning"
  defp callout_icon_tone(:error), do: "text-error"

  @doc """
  What a page or a section shows when it has nothing in it yet (#1715): an
  icon in a soft tinted square, a heading, one line of copy (the inner block)
  and, when there is an obvious next step, one action. The full variant is
  a surface of its own for an empty page; `compact` is a dashed, smaller one
  for a section that already sits inside a card. `data-empty-state` carries
  the variant, for tests and the e2e checks.

  ## Examples

      <.empty_state id="garden-empty" icon="hero-sparkles" title="Nothing to tidy">
        Every suggestion has been dealt with.
        <:action><.button variant="primary" phx-click="run">Look it over</.button></:action>
      </.empty_state>

      <.empty_state icon="hero-key" title="No tokens yet" compact>
        Create one for the CLI or a script.
      </.empty_state>
  """
  attr :id, :string, default: nil
  attr :icon, :string, required: true, doc: "a Heroicon name, `hero-…`"
  attr :title, :string, required: true
  attr :compact, :boolean, default: false, doc: "the smaller variant, for a section in a card"
  attr :tone, :string, values: ~w(primary rose), default: "primary", doc: "the icon's tint"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, doc: "the one line of copy under the heading"
  slot :action, doc: "the next step: one button or link"

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      data-empty-state={if @compact, do: "compact", else: "full"}
      class={[
        "text-center",
        if(@compact,
          do: "rounded-xl border border-dashed border-base-content/15 px-4 py-6",
          else: "rounded-2xl bg-base-100 p-8 shadow-sm ring-1 ring-base-content/10 sm:p-12"
        ),
        @class
      ]}
      {@rest}
    >
      <span class={[
        "mx-auto flex items-center justify-center",
        if(@compact, do: "size-9 rounded-lg", else: "size-12 rounded-xl"),
        empty_state_tone(@tone)
      ]}>
        <.icon name={@icon} class={if @compact, do: "size-5", else: "size-6"} />
      </span>
      <h2 :if={!@compact} class="mt-3 section-title">{@title}</h2>
      <h3 :if={@compact} class="mt-2 text-sm font-semibold">{@title}</h3>
      <p
        :if={@inner_block != []}
        class={[
          "mx-auto max-w-md text-sm text-base-content/60 [&_code]:font-mono [&_code]:text-xs",
          if(@compact, do: "mt-1", else: "mt-2")
        ]}
      >
        {render_slot(@inner_block)}
      </p>
      <div
        :if={@action != []}
        data-role="empty-state-action"
        class={["flex justify-center", if(@compact, do: "mt-3", else: "mt-4")]}
      >
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  defp empty_state_tone("primary"), do: "bg-primary/10 text-primary"
  defp empty_state_tone("rose"), do: "bg-rose-500/10 text-rose-500"

  @doc """
  Renders a button with navigation support.

  `variant` picks its weight in the button hierarchy (#1703): `primary`
  (solid, one per form), `secondary` (the soft tint), `ghost` (tertiary) or
  `danger` (error-coloured ghost, behind `data-confirm`). With none it is
  the neutral surface with a hairline, for Cancel and Back.

  ## Examples

      <.button>Cancel</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button phx-click="delete" variant="danger" data-confirm="Delete it?">Delete</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary secondary ghost danger)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    # The hierarchy in app.css's Buttons block (#1703).
    variants = %{
      "primary" => "btn-primary",
      "secondary" => "btn-secondary",
      "ghost" => "btn-ghost",
      "danger" => "btn-ghost btn-error",
      nil => nil
    }

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select field", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea field",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input field",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  A date, written the app's way, that opens the browser's own picker (#1720).

  Use it for every date a person sets, never a raw `<input type="date">`
  (W-1947 §Core). It shows the date as `SlipdockWeb.Dates.short/2` writes
  it ("18 Nov"), or `placeholder` ("Add date") when there is none, in the
  `field` box (`bare` for in-place editing: `field-bare`). A hidden native
  `<input type="date">` carries the value, so the form posts and
  `phx-change` sees exactly what the raw input sent: `name=YYYY-MM-DD`, or
  `name=` once cleared.

  Clicking the date, or Enter or Space on it, opens the native picker
  (`input.showPicker()`, the `DateField` hook in `assets/js/date_field.js`);
  a digit hands the keys to the native input for typing. Where the browser
  has no `showPicker`, the native input is shown instead. `×` clears it,
  unless `required`.

  ```heex
  <.date_field field={@form[:due_date]} label="Due date" min={@card.start_date} />
  <.date_field id="due-12" name="value" value={@card.due_date} bare aria-label="Due date" />
  ```
  """
  attr :id, :string, default: nil, doc: "the wrapper's id; the input's is `<id>-input`"
  attr :name, :string, default: nil
  attr :value, :any, default: nil, doc: "a Date, an ISO string, or nil/\"\""
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :label, :string, default: nil
  attr :placeholder, :string, default: "Add date"
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :bare, :boolean, default: false, doc: "edit in place (`field-bare`), as on the card back"
  attr :min, :any, default: nil
  attr :max, :any, default: nil
  attr :class, :any, default: nil, doc: "added to the wrapper (width, margins); never a size"
  attr :errors, :list, default: []

  attr :rest, :global,
    include: ~w(form aria-label aria-describedby phx-debounce),
    doc: "goes on the native input"

  def date_field(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil)
    |> assign(:id, assigns.id || field.id)
    |> assign(:name, assigns.name || field.name)
    |> assign(:value, assigns.value || field.value)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> date_field()
  end

  def date_field(assigns) do
    date = date_value(assigns.value)
    id = assigns.id || "date-#{System.unique_integer([:positive])}"

    assigns =
      assign(assigns,
        id: id,
        date: date,
        iso: date && Date.to_iso8601(date),
        text: if(date, do: SlipdockWeb.Dates.short(date), else: assigns.placeholder),
        min: iso_or_nil(assigns.min),
        max: iso_or_nil(assigns.max)
      )

    ~H"""
    <div :if={@label} class="fieldset mb-2">
      <label for={"#{@id}-display"} class="label mb-1">{@label}</label>
      <.date_box {assigns} />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    <.date_box :if={!@label} {assigns} />
    <.error :for={msg <- if(@label, do: [], else: @errors)}>{msg}</.error>
    """
  end

  defp date_box(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="DateField"
      data-date-field
      data-placeholder={@placeholder}
      data-empty={is_nil(@date)}
      class={[
        "date-field",
        if(@bare, do: "field-bare", else: "field"),
        @errors != [] && "input-error",
        @class
      ]}
    >
      <button
        type="button"
        id={"#{@id}-display"}
        data-role="date-display"
        class="date-field-display"
        disabled={@disabled}
        aria-label={@rest[:"aria-label"] && "#{@rest[:"aria-label"]}: #{@text}"}
      >
        <.icon name="hero-calendar" class="size-4 shrink-0 opacity-60" />
        <span data-role="date-text" class={is_nil(@date) && "date-field-placeholder"}>{@text}</span>
      </button>
      <input
        type="date"
        id={"#{@id}-input"}
        name={@name}
        value={@iso}
        min={@min}
        max={@max}
        required={@required}
        disabled={@disabled}
        class="date-field-input"
        tabindex="-1"
        {@rest}
      />
      <button
        :if={not @required}
        type="button"
        data-role="date-clear"
        class="date-field-clear"
        hidden={is_nil(@date)}
        disabled={@disabled}
        aria-label="Clear the date"
        title="Clear"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </div>
    """
  end

  defp date_value(%Date{} = d), do: d
  defp date_value(%DateTime{} = dt), do: DateTime.to_date(dt)

  defp date_value(s) when is_binary(s) do
    case Date.from_iso8601(String.trim(s)) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp date_value(_), do: nil

  defp iso_or_nil(value), do: (d = date_value(value)) && Date.to_iso8601(d)

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Frames a page's content at one of three widths (#1714):

    * `narrow` (42rem): forms and settings
    * `standard` (64rem): lists and indexes
    * `full`: boards, tables and dashboards

  It centres the content and gives every page the same padding. Tests read
  `data-page-width`. Put it inside the page's scroller, around the
  `page_header/1` and the content.

  ## Examples

      <.page width="narrow" class="space-y-6">
        <.page_header title="Groups" subtitle="People you share boards with." />
        ...
      </.page>
  """
  attr :id, :string, default: nil
  attr :width, :string, values: ~w(narrow standard full), default: "standard"

  attr :padded, :boolean,
    default: true,
    doc: "false inside a container that already pads it (a pane beside a tree)"

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <div
      id={@id}
      data-page-width={@width}
      class={[
        "mx-auto w-full",
        @padded && "px-4 py-6 sm:px-6 sm:py-10",
        page_width_class(@width),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The max-width class for a page width: `narrow`, `standard` or `full`.
  Anything else raises, so a typo can't quietly give a page no width.
  """
  def page_width_class("narrow"), do: "max-w-2xl"
  def page_width_class("standard"), do: "max-w-5xl"
  def page_width_class("full"), do: "max-w-none"

  def page_width_class(other) do
    raise ArgumentError,
          "unknown page width #{inspect(other)}: use \"narrow\", \"standard\" or \"full\""
  end

  @doc """
  A page's one title (#1714): the page's only `h1`, a one-line subtitle under
  it, and the page's own buttons on the right, on the title's baseline. The
  layout's header row doesn't repeat the title (W-1946 §Layout).

  `subtitle` is plain text; for a subtitle with links or counts in it use the
  `:meta` slot instead. `:leading` goes inside the `h1` before the title: an
  icon or a colour dot.

  ## Examples

      <.page_header title="Templates" subtitle="Start a board from one.">
        <:actions><.button variant="primary">New template</.button></:actions>
      </.page_header>
  """
  attr :id, :string, default: "page-header"
  attr :title, :string, required: true
  attr :title_id, :string, default: nil, doc: "the h1's own id"
  attr :subtitle, :string, default: nil

  attr :class, :any,
    default: "mb-6",
    doc: "replaces the default bottom margin: pass your own, or \"\" inside a card"

  slot :leading, doc: "drawn in the h1 before the title: an icon or a dot"
  slot :meta, doc: "a subtitle with markup in it (links, counts), instead of `subtitle`"
  slot :actions, doc: "the page's own buttons, right-aligned on the title's baseline"

  def page_header(assigns) do
    ~H"""
    <header
      id={@id}
      data-role="page-header"
      class={[
        "flex flex-wrap items-baseline justify-between gap-x-6 gap-y-3",
        @class
      ]}
    >
      <div class="min-w-0">
        <%!-- Not a flex box: the h1's baseline stays the title's text, so the
             actions line up with it even with an icon in front. --%>
        <h1 id={@title_id} class="page-title">
          <span :if={@leading != []} class="mr-2 inline-flex align-middle">
            {render_slot(@leading)}
          </span>{@title}
        </h1>
        <p
          :if={@subtitle || @meta != []}
          data-role="page-subtitle"
          class="mt-1 max-w-2xl text-sm text-base-content/60"
        >
          {@subtitle}{render_slot(@meta)}
        </p>
      </div>
      <%!-- A button that starts with an icon has the icon's bottom edge as
           its baseline, not its label's. So the row centres its buttons and
           takes its baseline from the first piece: an empty line of label
           text, centred like the labels are, which the header then sets on
           the title's baseline (tools/e2e/page-header.sh measures it). --%>
      <div
        :if={@actions != []}
        data-role="page-actions"
        class="flex flex-wrap items-center gap-2"
      >
        <span aria-hidden="true" data-role="page-actions-baseline" class="-mr-2 w-0 text-sm leading-5">
          &#8203;
        </span>
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="page-title">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  attr :name, :string, default: "q"
  attr :value, :any, default: nil
  attr :type, :string, default: "search"
  attr :class, :any, default: nil, doc: "the input's own classes: its width, mostly"

  attr :trail, :integer,
    default: 0,
    values: [0, 1, 2],
    doc: "how many small buttons sit over the box's right edge (a clear X, a star)"

  attr :rest, :global,
    include:
      ~w(id placeholder autocomplete autofocus disabled title phx-debounce phx-focus phx-target)

  @doc """
  A search box: the `field` look with a magnifying glass drawn inside it.

  Renders the glass and the input side by side, so the parent (a form or a
  `search_box/1`) has to be positioned (`relative`). The glass is stacked
  above the input (`z-10`): daisyUI's `.input` is itself positioned, and an
  icon before it without a z-index is painted over (#1695). Both sit in a
  `contents` label, so a click on the glass still puts the cursor in the box.

  ## Examples

      <form id="wiki-search" phx-change="search" class="relative">
        <.search_input value={@q} placeholder="Titles, folders, #tags…" class="w-56" />
      </form>
  """
  def search_input(assigns) do
    ~H"""
    <label class="contents">
      <.icon
        name="hero-magnifying-glass"
        class="search-input-icon absolute left-2.5 top-1/2 z-10 size-4 -translate-y-1/2 cursor-text text-base-content/60"
      />
      <input
        type={@type}
        name={@name}
        value={@value}
        class={[
          "input field field-icon",
          @trail == 1 && "field-trail",
          @trail == 2 && "field-trail-2",
          @class
        ]}
        {@rest}
      />
    </label>
    """
  end

  attr :chips, :list, required: true, doc: "{kind, text} pairs, as Slipdock.QuickAdd returns them"

  attr :unknown, :list,
    default: [],
    doc: "words that were left in the title because nothing matched them"

  attr :class, :any, default: nil

  @doc """
  What a quick add line was understood to mean, as chips: the dates,
  priority, flags, list, board, tags and assignee it named.
  """
  def quick_chips(assigns) do
    ~H"""
    <span class={["flex flex-wrap items-center gap-1", @class]}>
      <span :for={{kind, text} <- @chips} class={["chip text-2xs", quick_chip_class(kind)]}>
        <.icon name={quick_chip_icon(kind)} class="size-3" /> {text}
      </span>
      <span
        :for={word <- @unknown}
        class="chip chip-line text-2xs text-base-content/50 line-through"
        title="Not a priority, flag, list or tag — it stays in the title"
      >
        {word}
      </span>
    </span>
    """
  end

  defp quick_chip_icon(:date), do: "hero-calendar"
  defp quick_chip_icon(:priority), do: "hero-chevron-double-up"
  defp quick_chip_icon(:flag), do: "hero-flag"
  defp quick_chip_icon(:column), do: "hero-view-columns"
  defp quick_chip_icon(:board), do: "hero-rectangle-stack"
  defp quick_chip_icon(:tag), do: "hero-tag"
  defp quick_chip_icon(:assignee), do: "hero-user"
  defp quick_chip_icon(:comment), do: "hero-chat-bubble-left"
  defp quick_chip_icon(_), do: "hero-sparkles"

  defp quick_chip_class(:date), do: "chip-tint text-primary"
  defp quick_chip_class(:priority), do: "chip-tint text-warning"
  defp quick_chip_class(:flag), do: "chip-tint text-error"
  defp quick_chip_class(:column), do: "chip-tint text-secondary"
  defp quick_chip_class(:board), do: "chip-tint text-secondary"
  defp quick_chip_class(:tag), do: "chip-tint text-info"
  defp quick_chip_class(:repeat), do: "chip-tint text-primary"
  defp quick_chip_class(:snooze), do: "chip-tint text-base-content/70"
  defp quick_chip_class(_), do: "chip-line"

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(SlipdockWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(SlipdockWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
