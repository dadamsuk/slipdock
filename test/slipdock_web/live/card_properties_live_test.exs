defmodule SlipdockWeb.CardPropertiesLiveTest do
  @moduledoc """
  The card back's sidebar as a list of properties (#1726): a label on the
  left and the value on the right, each saving as it did, with no List
  select or Completed switch (the meta line and the title's check do those),
  and Precision under More while it is "day".
  `tools/e2e/card-properties.sh` checks the layout in a browser.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Plan the launch"})
    %{board: board, card: card, owner: owner}
  end

  defp open(conn, ctx), do: live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

  defp change(view, params),
    do: view |> form("#card-meta-form", card: params) |> render_change()

  test "the sidebar is label/value rows, one per property", ctx do
    {:ok, view, _} = open(ctx.conn, ctx)

    for {prop, label} <- [
          {"assignees", "Assignees"},
          {"priority", "Priority"},
          {"percent", "% complete"},
          {"start", "Start"},
          {"due", "Due"},
          {"health", "Health"}
        ] do
      row = ~s(#card-props [data-prop="#{prop}"])
      assert has_element?(view, "#{row} [data-role=prop-label]", label)
      assert has_element?(view, "#{row} [data-role=prop-value]")
    end

    # The values are edited in place: bare, never boxed.
    assert has_element?(view, "#card-props select#card-priority.field-bare")
    assert has_element?(view, "#card-props input#card-percent-complete.field-bare")
    assert has_element?(view, "#card-props [data-date-field].field-bare")
    refute has_element?(view, "#card-props .field")
    refute has_element?(view, "aside .section-label", "Priority")
  end

  test "no List select and no Completed switch in the sidebar", ctx do
    {:ok, view, _} = open(ctx.conn, ctx)

    refute has_element?(view, "aside select[name='card[column_id]']")
    refute has_element?(view, "aside input[name='card[completed]']")
    refute has_element?(view, "aside", "Completed")

    # The meta line's list and the title's check still do it.
    [_, second | _] = ctx.board.columns

    view
    |> form("#card-title-form", card: %{column_id: second.id})
    |> render_change()

    assert Boards.get_card!(ctx.card.id).column_id == second.id

    view |> element("#card-title-form button[phx-click=toggle_complete]") |> render_click()
    assert Boards.get_card!(ctx.card.id).completed
  end

  test "each property saves, and clears", ctx do
    {:ok, view, _} = open(ctx.conn, ctx)

    change(view, %{priority: "high"})
    assert Boards.get_card!(ctx.card.id).priority == "high"

    change(view, %{percent_complete: "35"})
    assert Boards.get_card!(ctx.card.id).percent_complete == 35
    assert has_element?(view, ~s([data-prop="percent"] progress[value="35"]))

    change(view, %{start_date: "2030-01-10", due_date: "2030-01-20"})
    card = Boards.get_card!(ctx.card.id)
    assert card.start_date == ~D[2030-01-10]
    assert card.due_date == ~D[2030-01-20]

    change(view, %{due_date: ""})
    assert Boards.get_card!(ctx.card.id).due_date == nil

    change(view, %{percent_complete: ""})
    assert Boards.get_card!(ctx.card.id).percent_complete == nil
  end

  test "a bad % or a start after the due date is said under its row", ctx do
    {:ok, view, _} = open(ctx.conn, ctx)

    html = change(view, %{percent_complete: "140"})
    assert html =~ "Use a whole number from 0 to 100."
    assert Boards.get_card!(ctx.card.id).percent_complete == nil

    html = change(view, %{start_date: "2030-02-01", due_date: "2030-01-01"})
    assert html =~ "Start must be on or before the due date."
  end

  test "assignees are added from the row's picker and removed from their chip", ctx do
    ada = user_fixture("props.ada@example.com")
    {:ok, _} = Access.grant(ctx.board, ada, "write", ctx.owner)
    {:ok, view, _} = open(ctx.conn, ctx)

    assert has_element?(view, ~s([data-prop="assignees"] option[value=""]), "Unassigned")

    change(view, %{add_assignee_id: ada.id})
    assert has_element?(view, "#card-assignee-#{ada.id}")
    assert has_element?(view, ~s([data-prop="assignees"] option[value=""]), "Add…")

    view
    |> element("#card-assignee-#{ada.id} button[phx-click=remove_assignee]")
    |> render_click()

    refute has_element?(view, "#card-assignee-#{ada.id}")
    assert Boards.get_card!(ctx.card.id).assignees == []
  end

  describe "Precision" do
    test "at day it is under More, hidden until opened", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)

      assert has_element?(view, "#card-props-more[hidden] #card-precision")

      assert has_element?(
               view,
               ~s(#card-props-more-toggle[aria-controls="card-props-more"][aria-expanded="false"]),
               "More"
             )

      # Opening is the client's: the button toggles the panel's `hidden`.
      toggle = view |> element("#card-props-more-toggle") |> render()
      assert toggle =~ "toggle_attr"
      assert toggle =~ "#card-props-more"
    end

    test "any other precision is its own row, and More goes", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)

      change(view, %{date_precision: "week"})
      assert Boards.get_card!(ctx.card.id).date_precision == "week"

      assert has_element?(view, ~s(#card-props [data-prop="precision"] #card-precision))
      refute has_element?(view, "#card-props-more")
      refute has_element?(view, "#card-props-more-toggle")

      change(view, %{date_precision: "day"})
      assert has_element?(view, "#card-props-more[hidden] #card-precision")
    end

    test "a simple board has neither Precision nor More", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"simple" => true})
      {:ok, view, _} = open(ctx.conn, ctx)

      refute has_element?(view, "#card-precision")
      refute has_element?(view, "#card-props-more-toggle")
      refute has_element?(view, ~s([data-prop="start"]))
      assert has_element?(view, ~s([data-prop="due"]))
      assert has_element?(view, ~s([data-prop="priority"]))
    end
  end

  test "the due badge shows only when it says more than the date", ctx do
    {:ok, _} = Boards.update_card(ctx.card, %{"due_date" => Date.add(Date.utc_today(), 60)})
    {:ok, view, _} = open(ctx.conn, ctx)
    refute has_element?(view, ~s([data-prop="due"] .chip))

    {:ok, _} = Boards.update_card(ctx.card, %{"due_date" => Date.add(Date.utc_today(), -3)})
    {:ok, view, _} = open(ctx.conn, ctx)
    assert has_element?(view, ~s([data-prop="due"] .chip.text-error))
  end

  test "a reader's properties are in a disabled fieldset", ctx do
    reader = user_fixture("props.reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)

    {:ok, view, _} =
      live(log_in_user(build_conn(), reader), ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    assert has_element?(view, "aside fieldset[disabled] #card-props #card-priority")
  end
end
