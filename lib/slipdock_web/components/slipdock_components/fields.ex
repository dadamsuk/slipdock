defmodule SlipdockWeb.SlipdockComponents.Fields do
  @moduledoc "Form fields laid out for a settings form: the switch with its title and hint."
  use Phoenix.Component

  @doc """
  A setting switched on or off: a checkbox, its title beside it and a hint
  under the title (#2894). Board settings and the overseer draw every switch
  with it.

  It is `<.input type="checkbox">`'s logic in a settings layout: a hidden
  input posts `unchecked` when the box is clear, the box posts `value` when
  ticked, and it is ticked when the field's value is (`checked` overrides
  that, for a field whose value isn't a boolean, such as a board's `kind`).
  The hint is the inner block, `text-xs text-base-content/60` (UX-15); with
  none, only the title shows.

      <.switch_field field={@form[:simple]} id="board-simple" label="Simple board">
        For a plain to-do list.
      </.switch_field>
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :id, :string, required: true, doc: "the checkbox's id"
  attr :label, :string, required: true, doc: "the setting's title"
  attr :value, :string, default: "true", doc: "what the ticked box posts"
  attr :unchecked, :string, default: "false", doc: "what the clear box posts"

  attr :checked, :boolean,
    default: nil,
    doc: "whether it is ticked; by default, whether the field's value is a true checkbox value"

  slot :inner_block, doc: "the hint under the title"

  def switch_field(assigns) do
    on =
      case assigns.checked do
        nil -> Phoenix.HTML.Form.normalize_value("checkbox", assigns.field.value)
        checked -> checked
      end

    assigns = assign(assigns, :on, on)

    ~H"""
    <input type="hidden" name={@field.name} value={@unchecked} />
    <label class="flex cursor-pointer items-start gap-2 text-sm" data-role="switch-field">
      <input
        type="checkbox"
        id={@id}
        name={@field.name}
        value={@value}
        checked={@on}
        class="checkbox mt-0.5"
      />
      <span>
        <span class="font-medium">{@label}</span>
        <span :if={@inner_block != []} class="block text-xs text-base-content/60">
          {render_slot(@inner_block)}
        </span>
      </span>
    </label>
    """
  end
end
