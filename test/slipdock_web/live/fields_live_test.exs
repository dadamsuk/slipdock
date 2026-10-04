defmodule SlipdockWeb.FieldsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.{Boards, Fields}

  setup do
    board = board_fixture(%{"name" => "Scored"})
    [backlog | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Idea"})
    %{board: reload(board), card: card}
  end

  test "settings install a preset and add a custom choice field", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    view |> with_target("#board-settings") |> render_click("install_preset", %{"key" => "rice"})

    assert Enum.map(Fields.list_fields(board.id), & &1.key) ==
             ~w(reach impact confidence effort rice)

    view
    |> form("#field-form-0", %{
      "name" => "Size",
      "kind" => "select",
      "options" => "Small=1, Large=3",
      "expression" => "",
      "sum" => "true"
    })
    |> render_submit()

    size = Fields.find_field(Fields.list_fields(board.id), "size")
    assert size.kind == "select"

    assert [%{"key" => "small", "weight" => 1.0}, %{"key" => "large", "weight" => 3.0}] =
             size.options

    assert render(view) =~ "{size}"
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
    render_click(view, "set_field", %{"field_id" => to_string(value.id), "value" => "4"})
    render_click(view, "set_field", %{"field_id" => to_string(effort.id), "value" => "2"})

    view
    |> form("#field-form-#{size.id}", %{"field_id" => size.id, "value" => "large"})
    |> render_change()

    card = Boards.get_card!(card.id)
    assert Fields.value(card, value) == 4.0
    assert Fields.value(card, size) == "large"
    assert Fields.value(card, formula) == 2.0
    assert render(view) =~ "Value ÷ Effort"

    # Out-of-range values are refused with a message.
    html = render_click(view, "set_field", %{"field_id" => to_string(value.id), "value" => "9"})
    assert html =~ "at most 5"
  end

  test "votes come from a budget", %{conn: conn, board: board, card: card} do
    {:ok, _} = Boards.update_board(board, %{"vote_budget" => 2, "vote_max" => 2})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")

    render_click(view, "vote", %{"count" => "2"})
    assert Slipdock.Boards.Card.vote_total(Boards.get_card!(card.id)) == 2
    assert render(view) =~ "0 of 2 left"

    html = render_click(view, "vote", %{"count" => "3"})
    assert html =~ "At most 2"
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

    {:ok, _lv, html} =
      live(conn, ~p"/boards/#{board}/table?fields=title,f:#{value.id}&sort=f:#{value.id}")

    assert html =~ "★★★"

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
