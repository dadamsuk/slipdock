defmodule SlipdockWeb.FieldEditorComponent do
  @moduledoc """
  The one editor for a custom field's definition (#3647): its name, its
  type, and the settings that type takes. Board settings' Fields tab uses it
  to add a field and to edit one; the table header's "+" uses it to add one.

  It keeps a draft while the person types, and only Save writes, through
  `Slipdock.Fields.create_field/2` or `update_field/2`, which ask write on
  the tree's root. A refusal shows inside the editor. Once saved, or on
  Cancel, it tells whoever holds it: the LiveComponent named by `parent`
  (`send_update` with `field_editor: {id, message}`), or else the LiveView
  it runs in (`{SlipdockWeb.FieldEditorComponent, id, message}`), where the
  message is `{:saved, field}` or `:cancelled`.

  What each type takes:

    * text (the default): an optional most characters, nothing required
    * number: optional least and most values, a step and a unit
    * rating: how many stars
    * choice: its options, as rows to add, rename, value, colour, reorder
      and remove (an option keeps its key when renamed, so cards keep it),
      and, for a new field, Allow several
    * formula: its expression (only where `kinds` offers it)
    * URL, email, date, checkbox, person: nothing; URL and email say what
      a value must look like

  A field's type is fixed once it exists: its values were made for it.
  Roll up totals and Allow several on an existing field are switched in the
  Fields tab's table, which asks before a switch drops values.
  """
  use SlipdockWeb, :live_component

  alias Slipdock.Boards.FieldDefinition
  alias Slipdock.{Fields, Palette}

  # The config keys each type's editor owns. Saving replaces these and keeps
  # the rest (a choice's Allow several, a weighted formula's weights).
  @owned %{
    "number" => ~w(min max step unit),
    "rating" => ~w(max),
    "text" => ~w(max_length),
    "formula" => ~w(expression)
  }

  @impl true
  def update(%{} = assigns, socket) do
    field = assigns[:field]
    same? = socket.assigns[:draft] && socket.assigns[:field_id] == field_id(field)

    socket =
      socket
      |> assign(
        id: assigns.id,
        board: assigns.board,
        field: field,
        field_id: field_id(field),
        kinds: assigns[:kinds] || FieldDefinition.kinds(),
        parent: assigns[:parent],
        compact: assigns[:compact] || false
      )

    {:ok, if(same?, do: socket, else: assign(socket, draft: draft(field), error: nil))}
  end

  defp field_id(nil), do: nil
  defp field_id(%FieldDefinition{id: id}), do: id

  @impl true
  def handle_event("change", params, socket),
    do:
      {:noreply, assign(socket, draft: merge(socket.assigns.draft, params, socket.assigns.field))}

  def handle_event("add_option", _, socket),
    do:
      {:noreply, update(socket, :draft, &Map.update!(&1, "options", fn o -> o ++ [blank()] end))}

  def handle_event("remove_option", %{"index" => i}, socket) do
    i = String.to_integer(i)

    {:noreply,
     update(socket, :draft, fn d ->
       case List.delete_at(d["options"], i) do
         [] -> %{d | "options" => [blank()]}
         rest -> %{d | "options" => rest}
       end
     end)}
  end

  def handle_event("move_option", %{"index" => i, "by" => by}, socket) do
    i = String.to_integer(i)
    j = i + String.to_integer(by)

    {:noreply,
     update(socket, :draft, fn d ->
       options = d["options"]

       if j < 0 or j >= length(options),
         do: d,
         else: %{d | "options" => swap(options, i, j)}
     end)}
  end

  def handle_event("cancel", _, socket) do
    tell(socket, :cancelled)
    {:noreply, assign(socket, draft: draft(socket.assigns.field), error: nil)}
  end

  def handle_event("save", params, socket) do
    %{field: field, board: board} = socket.assigns
    draft = merge(socket.assigns.draft, params, field)
    attrs = attrs(draft, field)

    result =
      if field, do: Fields.update_field(field, attrs), else: Fields.create_field(board, attrs)

    case result do
      {:ok, saved} ->
        tell(socket, {:saved, saved})
        # A new field's editor is ready for the next; an edited one shows
        # what was saved.
        {:noreply, assign(socket, draft: draft(if(field, do: saved)), error: nil)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, draft: draft, error: refusal(field, cs))}

      {:error, %Slipdock.Policy.Refused{message: message}} ->
        {:noreply, assign(socket, draft: draft, error: message)}
    end
  end

  defp tell(%{assigns: %{parent: {module, id}, id: me}}, message),
    do: send_update(module, id: id, field_editor: {me, message})

  defp tell(%{assigns: %{id: me}}, message), do: send(self(), {__MODULE__, me, message})

  defp refusal(field, cs) do
    verb = if field, do: "save", else: "add"
    "Couldn't #{verb} the field: #{Slipdock.ChangesetErrors.message(cs)}"
  end

  ## The draft ------------------------------------------------------------

  defp draft(nil),
    do: %{
      "name" => "",
      "kind" => "text",
      "options" => [blank()],
      "config" => %{},
      "sum" => false,
      "several" => false
    }

  defp draft(%FieldDefinition{} = f) do
    %{
      "name" => f.name,
      "kind" => f.kind,
      "options" =>
        case f.options || [] do
          [] -> [blank()]
          options -> Enum.map(options, &option_row/1)
        end,
      "config" => Map.new(f.config || %{}, fn {k, v} -> {k, shown(v)} end),
      "sum" => f.sum,
      "several" => FieldDefinition.several?(f)
    }
  end

  defp blank, do: %{"key" => "", "label" => "", "weight" => "", "color" => ""}

  defp option_row(o),
    do: %{
      "key" => o["key"] || "",
      "label" => o["label"] || "",
      "weight" => shown(o["weight"]),
      "color" => o["color"] || ""
    }

  # A number as a person typed it: 3, not 3.0.
  defp shown(n) when is_float(n) and n == trunc(n), do: Integer.to_string(trunc(n))
  defp shown(n) when is_number(n), do: to_string(n)
  defp shown(nil), do: ""
  defp shown(v), do: v

  # What the form sent, over the draft. The type is only the draft's to
  # change while the field is new.
  defp merge(draft, params, field) do
    kind = if field, do: draft["kind"], else: params["kind"] || draft["kind"]

    draft
    |> put_if(params, "name")
    |> Map.put("kind", kind)
    |> merge_config(params["config"], kind != draft["kind"])
    |> merge_options(params["options"])
    |> Map.put("sum", params["sum"] == "true")
    |> Map.put(
      "several",
      params["several"] == "true" or (field != nil and draft["several"] == true)
    )
  end

  # A new type starts its settings afresh: a rating's 5 stars aren't a
  # number's most. What the form sent was the old type's.
  defp merge_config(d, _config, true = _switched?), do: %{d | "config" => %{}}
  defp merge_config(d, %{} = config, _), do: %{d | "config" => Map.merge(d["config"], config)}
  defp merge_config(d, _config, _), do: d

  defp merge_options(d, %{} = rows),
    do: %{d | "options" => rows |> Enum.sort_by(&row_index/1) |> Enum.map(&elem(&1, 1))}

  defp merge_options(d, _rows), do: d

  defp put_if(d, params, key),
    do: if(Map.has_key?(params, key), do: Map.put(d, key, params[key]), else: d)

  defp row_index({i, _}), do: String.to_integer(to_string(i))

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  # The draft as `Fields` takes it: only what the type has.
  defp attrs(draft, field) do
    kind = if field, do: field.kind, else: draft["kind"]
    owned = Map.get(@owned, kind, [])
    kept = Map.drop((field && field.config) || %{}, owned)

    config =
      draft["config"]
      |> Map.take(owned)
      |> Map.merge(kept)
      |> put_new_only(field, kind, draft)

    %{
      "name" => draft["name"],
      "kind" => kind,
      "options" => if(kind == "select", do: Enum.reject(draft["options"], &blank?/1), else: []),
      "config" => config
    }
    |> then(fn a ->
      if field,
        do: a,
        else: Map.put(a, "sum", draft["sum"] and Enum.member?(~w(number rating), kind))
    end)
  end

  # Only a new field takes Allow several here, and a formula its mode.
  defp put_new_only(config, nil, "select", %{"several" => true}),
    do: Map.put(config, "several", true)

  defp put_new_only(config, nil, "formula", _), do: Map.put(config, "mode", "expression")
  defp put_new_only(config, _field, _kind, _draft), do: config

  defp blank?(row), do: String.trim(row["label"] || "") == ""

  ## Drawing ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        kind: if(assigns.field, do: assigns.field.kind, else: assigns.draft["kind"]),
        new?: is_nil(assigns.field)
      )

    ~H"""
    <form
      id={"#{@id}-form"}
      phx-target={@myself}
      phx-change="change"
      phx-submit="save"
      class="space-y-3 text-left text-sm font-normal normal-case tracking-normal whitespace-normal"
      data-role="field-editor"
    >
      <div class={["grid gap-2", if(@compact, do: "grid-cols-1", else: "sm:grid-cols-[1fr_12rem]")]}>
        <label class="block space-y-1">
          <span class="field-label">Name</span>
          <input
            type="text"
            name="name"
            value={@draft["name"]}
            placeholder="Field name"
            class="input field w-full"
            required
            autocomplete="off"
            phx-debounce="200"
          />
        </label>
        <label :if={@new?} class="block space-y-1">
          <span class="field-label">Type</span>
          <select name="kind" class="select field w-full">
            <option :for={{k, l} <- @kinds} value={k} selected={k == @kind}>{l}</option>
          </select>
        </label>
        <div :if={!@new?} class="space-y-1">
          <span class="field-label">Type</span>
          <p class="flex h-7 items-center text-sm" title="A field's type is fixed once it has values">
            {FieldDefinition.kind_label(@kind)}
          </p>
        </div>
      </div>

      <.kind_settings
        kind={@kind}
        draft={@draft}
        new?={@new?}
        compact={@compact}
        myself={@myself}
        field={@field}
      />

      <label
        :if={@new? and @kind in ~w(number rating)}
        class="flex cursor-pointer items-center gap-2 text-sm"
      >
        <input type="checkbox" name="sum" value="true" checked={@draft["sum"]} class="checkbox" />
        Roll up totals
      </label>

      <p :if={@error} role="alert" class="text-sm text-error" data-role="field-editor-error">
        {@error}
      </p>

      <div class="flex justify-end gap-2">
        <button
          :if={!@new?}
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="cancel"
          phx-target={@myself}
        >
          Cancel
        </button>
        <button type="submit" class={["btn btn-primary btn-sm", @compact && "w-full"]}>
          {if @new?, do: "Add field", else: "Save"}
        </button>
      </div>
    </form>
    """
  end

  attr :kind, :string, required: true
  attr :draft, :map, required: true
  attr :new?, :boolean, required: true
  attr :compact, :boolean, required: true
  attr :myself, :any, required: true
  attr :field, :any, required: true

  defp kind_settings(%{kind: "text"} = assigns) do
    ~H"""
    <label class="block space-y-1">
      <span class="field-label">Most characters</span>
      <input
        type="number"
        name="config[max_length]"
        value={@draft["config"]["max_length"]}
        min="1"
        step="1"
        placeholder="No limit"
        class="input field w-32"
      />
      <span class="block text-xs text-base-content/60">Optional. Leave empty for no limit.</span>
    </label>
    """
  end

  defp kind_settings(%{kind: "number"} = assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-2">
      <label class="block space-y-1">
        <span class="field-label">Least</span>
        <input
          type="number"
          step="any"
          name="config[min]"
          value={@draft["config"]["min"]}
          placeholder="None"
          class="input field w-full"
        />
      </label>
      <label class="block space-y-1">
        <span class="field-label">Most</span>
        <input
          type="number"
          step="any"
          name="config[max]"
          value={@draft["config"]["max"]}
          placeholder="None"
          class="input field w-full"
        />
      </label>
      <label class="block space-y-1">
        <span class="field-label">Step</span>
        <input
          type="number"
          step="any"
          min="0"
          name="config[step]"
          value={@draft["config"]["step"]}
          placeholder="Any"
          class="input field w-full"
        />
      </label>
      <label class="block space-y-1">
        <span class="field-label">Unit</span>
        <input
          type="text"
          name="config[unit]"
          value={@draft["config"]["unit"]}
          placeholder="e.g. %, days"
          class="input field w-full"
          autocomplete="off"
        />
      </label>
    </div>
    <p class="text-xs text-base-content/60">
      All optional. A value outside the least and most is refused.
    </p>
    """
  end

  defp kind_settings(%{kind: "rating"} = assigns) do
    ~H"""
    <label class="block space-y-1">
      <span class="field-label">Stars</span>
      <input
        type="number"
        name="config[max]"
        value={@draft["config"]["max"]}
        min="2"
        max="10"
        step="1"
        placeholder="5"
        class="input field w-24"
      />
    </label>
    """
  end

  defp kind_settings(%{kind: "select"} = assigns) do
    assigns = assign(assigns, count: length(assigns.draft["options"]))

    ~H"""
    <fieldset class="space-y-1.5" data-role="choices">
      <legend class="field-label mb-1">Choices</legend>
      <div
        :for={{row, i} <- Enum.with_index(@draft["options"])}
        class="flex items-center gap-1"
        data-role="choice"
      >
        <input type="hidden" name={"options[#{i}][key]"} value={row["key"]} />
        <input
          type="text"
          name={"options[#{i}][label]"}
          value={row["label"]}
          placeholder={"Choice #{i + 1}"}
          aria-label={"Choice #{i + 1}"}
          class="input field min-w-0 flex-1"
          autocomplete="off"
          phx-debounce="200"
        />
        <input
          type="number"
          step="any"
          name={"options[#{i}][weight]"}
          value={row["weight"]}
          placeholder="Value"
          aria-label={"Value of choice #{i + 1}"}
          title="Its value in formulas (optional)"
          class="input field w-20"
        />
        <select
          :if={!@compact}
          name={"options[#{i}][color]"}
          aria-label={"Colour of choice #{i + 1}"}
          class="select field w-28"
        >
          <option value="">No colour</option>
          <option :for={{n, l} <- Palette.all()} value={n} selected={row["color"] == n}>{l}</option>
        </select>
        <input :if={@compact} type="hidden" name={"options[#{i}][color]"} value={row["color"]} />
        <button
          type="button"
          class="btn btn-ghost btn-xs btn-square"
          phx-click="move_option"
          phx-value-index={i}
          phx-value-by="-1"
          phx-target={@myself}
          disabled={i == 0}
          title="Move up"
          aria-label={"Move choice #{i + 1} up"}
        >
          <.icon name="hero-chevron-up" class="size-3.5" />
        </button>
        <button
          type="button"
          class="btn btn-ghost btn-xs btn-square"
          phx-click="move_option"
          phx-value-index={i}
          phx-value-by="1"
          phx-target={@myself}
          disabled={i == @count - 1}
          title="Move down"
          aria-label={"Move choice #{i + 1} down"}
        >
          <.icon name="hero-chevron-down" class="size-3.5" />
        </button>
        <%!-- Not a destructive button: it changes the draft, and nothing
              is lost until Save. --%>
        <button
          type="button"
          class="btn btn-ghost btn-xs btn-square"
          phx-click="remove_option"
          phx-value-index={i}
          phx-target={@myself}
          title="Remove"
          aria-label={"Remove choice #{i + 1}"}
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
      <button
        type="button"
        class="btn btn-ghost btn-xs gap-1"
        phx-click="add_option"
        phx-target={@myself}
        data-role="add-choice"
      >
        <.icon name="hero-plus" class="size-3.5" /> Add a choice
      </button>
      <p :if={!@new?} class="text-xs text-base-content/60">
        A renamed choice keeps its cards. A removed one leaves its cards' value without a choice.
      </p>
    </fieldset>
    <label :if={@new?} class="flex cursor-pointer items-center gap-2 text-sm">
      <input type="checkbox" name="several" value="true" checked={@draft["several"]} class="checkbox" />
      Allow several per card
    </label>
    """
  end

  defp kind_settings(%{kind: "formula"} = assigns) do
    assigns =
      assign(assigns, weighted?: assigns.field && assigns.field.config["mode"] == "weighted")

    ~H"""
    <label :if={!@weighted?} class="block space-y-1">
      <span class="field-label">Formula</span>
      <input
        type="text"
        name="config[expression]"
        value={@draft["config"]["expression"]}
        placeholder="e.g. {value} / {effort}"
        class="input field field-mono w-full"
        autocomplete="off"
        phx-debounce="200"
      />
      <span class="block text-xs text-base-content/60">
        Refer to other fields by their key in braces.
      </span>
    </label>
    <p :if={@weighted?} class="text-xs text-base-content/60">
      A weighted score from a preset. Its inputs and weights come with the preset.
    </p>
    """
  end

  defp kind_settings(%{kind: "url"} = assigns) do
    ~H"""
    <p class="text-xs text-base-content/60">
      Each value must be an http or https link, like https://example.com.
    </p>
    """
  end

  defp kind_settings(%{kind: "email"} = assigns) do
    ~H"""
    <p class="text-xs text-base-content/60">
      Each value must be an email address, like name@example.com.
    </p>
    """
  end

  defp kind_settings(assigns), do: ~H""
end
