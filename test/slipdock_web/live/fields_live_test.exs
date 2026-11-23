defmodule SlipdockWeb.FieldsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.{Boards, Fields}

  # The card panel is a LiveComponent; what it is pushed goes to it.
  defp card_panel(view), do: with_target(view, "#board-card")

  setup do
    board = board_fixture(%{"name" => "Scored"})
    [backlog | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Idea"})
    %{board: reload(board), card: card}
  end

  @new "#field-editor-new-form"

  # The Fields tab's editor for a new field (#3647): the type first, as a
  # person picks it, then a row for each further choice, then the rest.
  defp add_field(view, %{"kind" => kind} = attrs) do
    view |> form(@new, %{"kind" => kind}) |> render_change()

    for _ <- 2..map_size(Map.get(attrs, "options", %{}))//1,
        do: view |> element("#{@new} [data-role=add-choice]") |> render_click()

    view |> form(@new, attrs) |> render_submit()
  end

  test "settings install a preset and add a custom choice field", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=fields")
    view |> with_target("#board-settings") |> render_click("install_preset", %{"key" => "rice"})

    assert Enum.map(Fields.list_fields(board.id), & &1.key) ==
             ~w(reach impact confidence effort rice)

    add_field(view, %{
      "name" => "Size",
      "kind" => "select",
      "options" => %{
        "0" => %{"label" => "Small", "weight" => "1"},
        "1" => %{"label" => "Large", "weight" => "3"}
      }
    })

    size = Fields.find_field(Fields.list_fields(board.id), "size")
    assert size.kind == "select"

    assert [%{"key" => "small", "weight" => 1.0}, %{"key" => "large", "weight" => 3.0}] =
             size.options

    # The table lists it, with its key and what its settings come to.
    assert has_element?(view, "#fields-table #field-#{size.id}", "{size}")

    assert has_element?(
             view,
             "#field-#{size.id} [data-role=field-summary]",
             "2 choices: Small, Large"
           )

    assert has_element?(view, "#panel-notice", "Added the field “Size”.")
  end

  test "a field with a blank name is refused, says why and adds nothing", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=fields")

    add_field(view, %{"name" => "", "kind" => "number"})

    assert has_element?(
             view,
             "#{@new} [data-role=field-editor-error]",
             "Couldn't add the field: name can't be blank"
           )

    assert Fields.list_fields(board.id) == []
  end

  test "a field with a bad formula is refused, says why and adds nothing", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=fields")

    add_field(view, %{
      "name" => "Score",
      "kind" => "formula",
      "config" => %{"expression" => "{reach} * ("}
    })

    assert has_element?(
             view,
             "#{@new} [data-role=field-editor-error]",
             "Couldn't add the field: config formula ends too early"
           )

    assert Fields.list_fields(board.id) == []
  end

  test "each type shows only its own settings, and Text, the default, needs none",
       %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=fields")

    assert has_element?(view, "#{@new} select[name=kind] option[value=text][selected]")
    assert has_element?(view, ~s|#{@new} input[name="config[max_length]"]|)
    refute has_element?(view, ~s|#{@new} [data-role=choices]|)

    view |> form(@new, %{"kind" => "number"}) |> render_change()

    for key <- ~w(min max step unit),
        do: assert(has_element?(view, ~s|#{@new} input[name="config[#{key}]"]|), key)

    refute has_element?(view, ~s|#{@new} input[name="config[max_length]"]|)

    view |> form(@new, %{"kind" => "select"}) |> render_change()
    assert has_element?(view, ~s|#{@new} [data-role=choices] input[name="options[0][label]"]|)
    refute has_element?(view, ~s|#{@new} input[name="config[min]"]|)

    view |> form(@new, %{"kind" => "email"}) |> render_change()
    assert has_element?(view, @new, "must be an email address")

    view |> form(@new, %{"kind" => "url"}) |> render_change()
    assert has_element?(view, @new, "must be an http or https link")

    # Text with nothing but a name is a field.
    add_field(view, %{"name" => "Notes", "kind" => "text"})
    assert [%{kind: "text", config: %{}}] = Fields.list_fields(board.id)
  end

  test "a text field's most characters is kept, and a value over it is refused",
       %{conn: conn, board: board, card: card} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=fields")
    add_field(view, %{"name" => "Code", "kind" => "text", "config" => %{"max_length" => "4"}})

    [code] = Fields.list_fields(board.id)
    assert code.config == %{"max_length" => 4}
    assert has_element?(view, "#field-#{code.id} [data-role=field-summary]", "Up to 4 characters")

    assert {:ok, _} = Fields.set_value(card, code, "ABCD")
    assert {:error, "Code takes at most 4 characters."} = Fields.set_value(card, code, "ABCDE")
  end

  test "a number's least more than its most is refused", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=fields")

    add_field(view, %{
      "name" => "Deal",
      "kind" => "number",
      "config" => %{"min" => "10", "max" => "1"}
    })

    assert has_element?(
             view,
             "#{@new} [data-role=field-editor-error]",
             "least must not be more than most"
           )

    assert Fields.list_fields(board.id) == []
  end

  test "Edit opens a field in the editor: renamed, its choices renamed, reordered and one removed",
       %{conn: conn, board: board, card: card} do
    {:ok, stage} =
      Fields.create_field(board, %{
        "name" => "Stage",
        "kind" => "select",
        "options" => ["Lead", "Won", "Lost"]
      })

    {:ok, _} = Fields.set_value(card, stage, "won")

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=fields")
    view |> element("#field-#{stage.id} [data-role=edit-field]") |> render_click()
    editor = "#field-editor-#{stage.id}-form"
    assert has_element?(view, editor)
    # Its type is fixed: it has values.
    refute has_element?(view, "#{editor} select[name=kind]")

    # Won moves up above Lead, and Lost goes.
    view
    |> element(
      ~s|#{editor} button[phx-click=move_option][phx-value-index="1"][phx-value-by="-1"]|
    )
    |> render_click()

    view
    |> element(~s|#{editor} button[phx-click=remove_option][phx-value-index="2"]|)
    |> render_click()

    view
    |> form(editor, %{
      "name" => "Pipeline stage",
      "options" => %{"0" => %{"label" => "Closed won"}, "1" => %{"label" => "Lead"}}
    })
    |> render_submit()

    stage = Fields.get_board_field(board.id, stage.id)
    assert stage.name == "Pipeline stage"

    assert Enum.map(stage.options, &{&1["key"], &1["label"]}) == [
             {"won", "Closed won"},
             {"lead", "Lead"}
           ]

    # The card kept its choice through the rename.
    assert Fields.value(Boards.Cards.get_card!(card.id), stage) == "won"
    # Saved, the editor closes.
    refute has_element?(view, editor)
    assert has_element?(view, "#panel-notice", "Saved the field “Pipeline stage”.")
  end

  test "Cancel closes the editor and changes nothing", %{conn: conn, board: board} do
    {:ok, notes} = Fields.create_field(board, %{"name" => "Notes", "kind" => "text"})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=fields")

    view |> element("#field-#{notes.id} [data-role=edit-field]") |> render_click()
    editor = "#field-editor-#{notes.id}-form"
    view |> form(editor, %{"name" => "Scribbles"}) |> render_change()
    view |> element("#{editor} button", "Cancel") |> render_click()

    refute has_element?(view, editor)
    assert Fields.get_board_field(board.id, notes.id).name == "Notes"
  end

  test "installing an unknown preset says so and adds nothing", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")

    view
    |> with_target("#board-settings")
    |> render_hook("install_preset", %{"key" => "no_such_preset"})

    assert render(view) =~ "Unknown preset."
    assert Fields.list_fields(board.id) == []
  end

  test "the card modal sets rating, number and choice fields and shows the formula", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, _} = Fields.install_preset(board, "value_effort")

    {:ok, size} =
      Fields.create_field(board, %{
        "name" => "Size",
        "kind" => "select",
        "options" =>
          "Small=1,Large=3"
          |> String.split(",")
          |> Enum.map(
            &(String.split(&1, "=")
              |> then(fn [l, w] -> %{"label" => l, "weight" => w} end))
          )
      })

    fields = Fields.list_fields(board.id)
    value = Fields.find_field(fields, "value")
    effort = Fields.find_field(fields, "effort")
    formula = Fields.find_field(fields, "value_effort")

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")

    render_click(card_panel(view), "set_field", %{
      "field_id" => to_string(value.id),
      "value" => "4"
    })

    render_click(card_panel(view), "set_field", %{
      "field_id" => to_string(effort.id),
      "value" => "2"
    })

    view
    |> form("#field-form-#{size.id}", %{"field_id" => size.id, "value" => "large"})
    |> render_change()

    card = Boards.Cards.get_card!(card.id)
    assert Fields.value(card, value) == 4.0
    assert Fields.value(card, size) == "large"
    assert Fields.value(card, formula) == 2.0
    assert render(view) =~ "Value ÷ Effort"

    # Out-of-range values are refused with a message.
    render_click(card_panel(view), "set_field", %{
      "field_id" => to_string(value.id),
      "value" => "9"
    })

    assert render(view) =~ "at most 5"
  end

  test "votes come from a budget", %{conn: conn, board: board, card: card} do
    {:ok, _} = Boards.update_board(board, %{"vote_budget" => 2, "vote_max" => 2})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")

    render_click(card_panel(view), "vote", %{"count" => "2"})
    assert Slipdock.Boards.Card.vote_total(Boards.Cards.get_card!(card.id)) == 2
    assert render(view) =~ "0 of 2 left"

    render_click(card_panel(view), "vote", %{"count" => "3"})
    assert render(view) =~ "At most 2"
  end

  test "custom fields become table columns, sorts and swimlane axes", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, _} = Fields.install_preset(board, "value_effort")
    fields = Fields.list_fields(board.id)
    value = Fields.find_field(fields, "value")
    {:ok, _} = Fields.set_value(card, value, 3)

    {:ok, table, _html} =
      live(conn, ~p"/boards/#{board}/table?fields=title,f:#{value.id}&sort=f:#{value.id}")

    # A writer edits it in place (#3610): three of five stars lit.
    lit = "#row-all-#{card.id} [data-field-cell=value] button.text-amber-500"
    assert table |> render() |> Floki.parse_document!() |> Floki.find(lit) |> length() == 3

    {:ok, _lv, html} =
      live(conn, ~p"/boards/#{board}/swimlanes?rows=f:#{value.id}&cols=column&empty=show")

    assert html =~ "Not rated"
    assert html =~ "★★★"
  end

  test "the API reads and writes fields and votes", %{conn: conn, board: board, card: card} do
    {:ok, _} = Fields.install_preset(board, "ice")

    conn =
      patch(conn, ~p"/api/cards/#{card}", %{
        "fields" => %{"impact" => 8, "confidence" => 5, "ease" => 2}
      })

    body = json_response(conn, 200)
    assert body["card"]["fields"] == %{"impact" => 8.0, "confidence" => 5.0, "ease" => 2.0}
    assert body["card"]["scores"] == %{"ice" => 80.0}

    conn =
      post(
        build_conn() |> Map.put(:req_headers, conn.req_headers),
        ~p"/api/cards/#{card}/vote",
        %{"count" => 3}
      )

    assert json_response(conn, 200)["card"]["votes"] == 3

    conn =
      get(
        build_conn() |> Map.put(:req_headers, conn.req_headers),
        ~p"/api/boards/#{board.id}/fields"
      )

    assert length(json_response(conn, 200)["fields"]) == 4

    conn =
      patch(build_conn() |> Map.put(:req_headers, conn.req_headers), ~p"/api/cards/#{card}", %{
        "fields" => %{"impact" => 99}
      })

    assert json_response(conn, 422)["error"] =~ "at most 10"
  end
end
