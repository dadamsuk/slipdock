defmodule SlipdockWeb.CardFieldsTest do
  @moduledoc """
  The card back draws every box a person types into or picks from as one
  field (#1672): the `field` class (or `field-bare`, for text edited in
  place), and never a daisyUI size modifier or a text size of its own,
  which is how its boxes came to be four sizes in three borders.
  tools/e2e/card-back-fields.sh checks the computed styles in a browser.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  @sizes ~w(input-xs input-sm input-md input-lg select-xs select-sm select-md select-lg
            textarea-xs textarea-sm textarea-md textarea-lg textarea-bordered select-ghost
            input-ghost text-xs text-sm text-base text-2xs rounded-full font-mono)

  # Every field in the card modal, with its classes: inputs a person types
  # into (not hidden, checkbox, radio or file inputs), textareas and selects.
  # A date field (#1720) is its box: the native input inside it is hidden.
  defp fields(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(
      "#card-modal :is(input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=file]):not(.date-field-input), textarea, select, [data-date-field])"
    )
    |> Enum.map(fn node ->
      [id] = LazyHTML.attribute(node, "id") |> then(&if &1 == [], do: [nil], else: &1)
      [name] = LazyHTML.attribute(node, "name") |> then(&if &1 == [], do: [nil], else: &1)
      [class] = LazyHTML.attribute(node, "class") |> then(&if &1 == [], do: [""], else: &1)
      {id || name, String.split(class)}
    end)
  end

  defp open_card(conn) do
    board = board_fixture(%{"name" => "Fields"})
    [todo | _] = board.columns

    card =
      card_fixture(todo, %{"title" => "Plan the launch", "description" => "The **plan**."})

    {:ok, card} =
      Boards.Cards.update_card(card, %{"bar" => "Shipped", "paths" => ["lib/launch/**"]})

    other = card_fixture(todo, %{"title" => "Write the post"})
    {:ok, _} = Boards.Checklists.add_checklist_item(card, "Book the room")
    {:ok, _} = Boards.CardUrls.add_card_url(card, %{"url" => "https://example.com/spec"})
    {:ok, _} = Boards.Links.add_link(card, other, "relates")

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")
    view
  end

  test "every field on the card back is a field, at the one size", %{conn: conn} do
    view = open_card(conn)

    # Open what stays closed until asked for.
    view |> element("#card-description-view") |> render_click()
    view |> element("#card-bar-view") |> render_click()
    view |> element("#repeat-edit") |> render_click()
    if has_element?(view, "#wait-ask"), do: view |> element("#wait-ask") |> render_click()
    if has_element?(view, "#handoff-edit"), do: view |> element("#handoff-edit") |> render_click()

    found = fields(render(view))
    ids = Enum.map(found, &elem(&1, 0))

    # What was opened is in the list, so the check covers it.
    assert "card-title" in ids
    assert "card-description" in ids
    assert "card-bar" in ids
    assert "card-paths" in ids
    assert "repeat_preset" in ids
    assert length(found) >= 25

    for {what, classes} <- found do
      assert "field" in classes or "field-bare" in classes,
             "#{what} is not drawn as a field: #{Enum.join(classes, " ")}"

      assert [] == Enum.filter(classes, &(&1 in @sizes)),
             "#{what} sets its own size or border: #{Enum.join(classes, " ")}"
    end

    # Text edited in place keeps no box; the paths are the one code field.
    assert {"card-title", title} = List.keyfind(found, "card-title", 0)
    assert "field-bare" in title
    assert {"card-paths", paths} = List.keyfind(found, "card-paths", 0)
    assert "field-mono" in paths
    assert {"card-bar", bar} = List.keyfind(found, "card-bar", 0)
    refute "field-mono" in bar
  end

  test "a read-only card's fields are fields too", %{conn: conn, user: owner} do
    board = board_fixture(%{"name" => "Read only fields"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Theirs"})
    viewer = user_fixture("viewer-fields@example.com")
    {:ok, _} = Slipdock.Access.grant(board, viewer, "read", owner)

    {:ok, view, _} = live(log_in_user(conn, viewer), ~p"/boards/#{board}/cards/#{card}")

    found = fields(render(view))
    assert found != []

    for {what, classes} <- found do
      assert "field" in classes or "field-bare" in classes, "#{what}: #{Enum.join(classes, " ")}"
    end
  end

  test "<.input> draws a field unless its class is replaced" do
    form = Phoenix.Component.to_form(%{"a" => "x"}, as: :f)

    for type <- ~w(text select textarea) do
      html =
        render_component(&SlipdockWeb.CoreComponents.input/1,
          field: form[:a],
          type: type,
          options: [{"X", "x"}]
        )

      assert html =~ ~r/class="w-full (input|select|textarea) field"/
    end

    custom = render_component(&SlipdockWeb.CoreComponents.input/1, field: form[:a], class: "mine")
    assert custom =~ ~s(class="mine")
    refute custom =~ ~r/class="[^"]*\bfield\b/
  end

  test "the field classes and the editor's face are defined in app.css" do
    css = File.read!("assets/css/app.css")

    for rule <- [".field {", "input.field, select.field", ".field-mono", ".field-bare {"] do
      assert css =~ rule
    end

    # The Markdown editor's face is the app's: under `inherit` it fell back
    # to system-ui, so the description and comments were in another font.
    assert css =~ "--atomic-editor-font: var(--font-sans);"
    refute css =~ "--atomic-editor-font: inherit;"
  end
end
