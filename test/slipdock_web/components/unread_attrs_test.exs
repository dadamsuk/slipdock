defmodule SlipdockWeb.Components.UnreadAttrsTest do
  @moduledoc """
  The nine attrs #2954 removed stay removed: each was declared, and mostly
  passed, while its component never read it. A declared attr says the
  component depends on the value, so these are held to what
  `__components__/0` records, and the callers by the compiler, which warns
  about an attribute a component doesn't declare.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.BoardLive.SettingsComponent
  alias SlipdockWeb.Layouts
  alias SlipdockWeb.NarrativeComponents
  alias SlipdockWeb.PrioritiseComponents
  alias SlipdockWeb.TableComponents
  alias SlipdockWeb.TimelineComponents

  @removed [
    {Layouts, :app, :current_scope},
    {Layouts, :brand_mark, :icon_class},
    {NarrativeComponents, :narrative_view, :can_write},
    {NarrativeComponents, :card_story, :today},
    {PrioritiseComponents, :prioritise_view, :board},
    {PrioritiseComponents, :prioritise_view, :current_user},
    {TableComponents, :table_view, :form_key},
    {TimelineComponents, :timeline_view, :form_key},
    {SettingsComponent, :settings_modal, :pages}
  ]

  defp attr_names(module, component) do
    %{attrs: attrs} = Map.fetch!(module.__components__(), component)
    Enum.map(attrs, & &1.name)
  end

  for {module, component, attr} <- @removed do
    test "#{inspect(module)}.#{component}/1 no longer declares #{attr}" do
      names = attr_names(unquote(module), unquote(component))

      refute unquote(attr) in names
    end
  end

  test "the components still declare the attrs they read" do
    # Guards the helper: a component that vanished, or a lookup that returned
    # nothing, would make every refute above pass.
    assert :flash in attr_names(Layouts, :app)
    assert :class in attr_names(Layouts, :brand_mark)
    assert :narrative in attr_names(NarrativeComponents, :narrative_view)
    assert :tell in attr_names(NarrativeComponents, :card_story)
    assert :prioritise in attr_names(PrioritiseComponents, :prioritise_view)
    assert :rows in attr_names(TableComponents, :table_view)
    assert :timeline in attr_names(TimelineComponents, :timeline_view)
    assert :form_key in attr_names(SettingsComponent, :settings_modal)
  end
end
