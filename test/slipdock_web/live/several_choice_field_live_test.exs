defmodule SlipdockWeb.SeveralChoiceFieldLiveTest do
  @moduledoc """
  A choice field that allows several (#3611) through its doors: the card's
  and the table's editors, a reader's chips, board settings' Allow several
  switch and the question it asks before switching off, and the REST API
  and MCP setting and reading it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields}
  alias Slipdock.Boards.FieldDefinition

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Releases"}, owner: user)
    [_backlog, todo | _] = board.columns

    {:ok, area} =
      Fields.create_field(board, %{
        "name" => "Area",
        "kind" => "select",
        "options" => [
          %{"label" => "Web", "color" => "sky"},
          %{"label" => "API"},
          %{"label" => "Billing"}
        ],
        "config" => %{"several" => true}
      })

    both = card_fixture(todo, %{"title" => "Both areas"})
    empty = card_fixture(todo, %{"title" => "No area"})
    {:ok, _} = Fields.set_value(both, area, "web, api")

    %{conn: conn, board: board, area: area, both: both, empty: empty}
  end

  defp area_of(card, area), do: Fields.value(Boards.Cards.get_card!(card.id), area)

  defp reader_conn(board, owner) do
    reader = user_fixture("reader-several@example.com")
    {:ok, _} = Slipdock.Access.grant(board, reader, "read", owner)
    log_in_user(build_conn(), reader)
  end

  describe "the card" do
    test "ticks the options it holds and sets the ones ticked, in option order",
         %{conn: conn, board: board, area: area, both: both} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{both}")
      form = "#field-form-#{area.id}"

      assert has_element?(view, ~s|#{form} input[type="checkbox"][value="web"][checked]|)
      assert has_element?(view, ~s|#{form} input[type="checkbox"][value="api"][checked]|)
      refute has_element?(view, ~s|#{form} input[type="checkbox"][value="billing"][checked]|)

      view
      |> form(form, %{"field_id" => area.id, "value" => ["", "billing", "web"]})
      |> render_change()

      assert area_of(both, area) == ["web", "billing"]
      assert has_element?(view, ~s|#{form} input[type="checkbox"][value="billing"][checked]|)

      # Unticking every box sends only the blank, which clears it.
      view |> form(form, %{"field_id" => area.id, "value" => [""]}) |> render_change()
      assert area_of(both, area) == nil
    end

    test "a reader sees the labels as chips and no boxes",
         %{board: board, area: area, both: both, user: user} do
      {:ok, view, _} = live(reader_conn(board, user), ~p"/boards/#{board}/cards/#{both}")
      field = "#card-field-#{area.id}"

      assert has_element?(view, "#{field} [data-chosen] .chip", "Web")
      assert has_element?(view, "#{field} [data-chosen] .chip", "API")
      refute has_element?(view, "#{field} [data-chosen] .chip", "Billing")
      refute has_element?(view, ~s|#{field} input[type="checkbox"]|)
    end
  end

  test "the toolbar filter keeps a card holding any option picked, and a reload keeps it",
       %{conn: conn, board: board, both: both, empty: empty} do
    other =
      card_fixture(hd(tl(Boards.get_board!(board.id).columns)), %{"title" => "Billing card"})

    {:ok, _} =
      Fields.set_value(other, Fields.get_board_field(board.id, area_id(board)), "billing")

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    view |> element(~s|[data-field-filter="area"] button|, "API") |> render_click()
    path = assert_patch(view)
    assert render(view) =~ both.title
    refute render(view) =~ empty.title
    refute render(view) =~ "Billing card"

    {:ok, reloaded, html} = live(conn, path)
    assert html =~ both.title
    refute html =~ "Billing card"

    reloaded |> element(~s|[data-field-filter="area"] button|, "Billing") |> render_click()
    assert_patch(reloaded)
    assert render(reloaded) =~ both.title
    assert render(reloaded) =~ "Billing card"
    refute render(reloaded) =~ empty.title
  end

  defp area_id(board), do: Fields.find_field(Fields.list_fields(board.id), "area").id

  describe "the table" do
    test "a writer ticks options in place", %{conn: conn, board: board, area: area, empty: empty} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?fields=title,f:#{area.id}")
      cell = "#row-all-#{empty.id} [data-field-cell=area]"

      assert has_element?(view, ~s|#{cell} input[type="hidden"][name="value[]"][value=""]|)
      refute has_element?(view, ~s|#{cell} input[type="checkbox"][checked]|)

      view |> element("#{cell} form") |> render_change(%{"value" => ["", "api", "billing"]})
      assert area_of(empty, area) == ["api", "billing"]
      assert has_element?(view, ~s|#{cell} input[type="checkbox"][value="api"][checked]|)
    end

    test "a reader sees a chip for each option, in option order",
         %{board: board, area: area, both: both, user: user} do
      path = ~p"/boards/#{board}/table?fields=title,f:#{area.id}"
      {:ok, view, _} = live(reader_conn(board, user), path)
      row = "#row-all-#{both.id}"

      assert has_element?(view, "#{row} .chip", "Web")
      assert has_element?(view, "#{row} .chip", "API")
      refute has_element?(view, "#{row} [data-field-cell]")

      chips = view |> element(row) |> render() |> Floki.parse_fragment!() |> Floki.find(".chip")

      assert Enum.map(chips, &String.trim(Floki.text(&1))) |> Enum.filter(&(&1 in ~w(Web API))) ==
               ~w(Web API)
    end
  end

  describe "board settings" do
    test "a choice field is added allowing several, and switched off and on",
         %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")

      editor = "#field-editor-new-form"
      view |> form(editor, %{"kind" => "select"}) |> render_change()
      view |> element("#{editor} [data-role=add-choice]") |> render_click()

      view
      |> form(editor, %{
        "name" => "Team",
        "kind" => "select",
        "options" => %{"0" => %{"label" => "Red"}, "1" => %{"label" => "Blue"}},
        "several" => "true"
      })
      |> render_submit()

      team = Fields.find_field(Fields.list_fields(board.id), "team")
      assert FieldDefinition.several?(team)

      toggle = ~s|#field-#{team.id} input[phx-click="toggle_field_several"]|
      assert view |> element(toggle) |> render() =~ "checked"

      # Nobody holds several, so it switches off without asking.
      view |> element(toggle) |> render_click()
      refute has_element?(view, "#field-several-confirm-#{team.id}")
      refute FieldDefinition.several?(Fields.get_board_field(board.id, team.id))

      view |> element(toggle) |> render_click()
      assert FieldDefinition.several?(Fields.get_board_field(board.id, team.id))
    end

    test "switching off where a card holds several asks first, and Cancel keeps them",
         %{conn: conn, board: board, area: area, both: both} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
      toggle = ~s|#field-#{area.id} input[phx-click="toggle_field_several"]|
      confirm = "#field-several-confirm-#{area.id}"

      view |> element(toggle) |> render_click()
      assert has_element?(view, confirm, "keeps")
      assert render(element(view, confirm)) =~ "first option, in the field&#39;s option order"
      # Nothing has changed yet.
      assert FieldDefinition.several?(Fields.get_board_field(board.id, area.id))
      assert area_of(both, area) == ["web", "api"]

      view |> element("#{confirm} button", "Cancel") |> render_click()
      refute has_element?(view, confirm)
      assert area_of(both, area) == ["web", "api"]
    end

    test "confirmed, it switches off and each card keeps its first option",
         %{conn: conn, board: board, area: area, both: both} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
      confirm = "#field-several-confirm-#{area.id}"

      view
      |> element(~s|#field-#{area.id} input[phx-click="toggle_field_several"]|)
      |> render_click()

      view |> element("#{confirm} button", "Keep the first option") |> render_click()
      refute has_element?(view, confirm)

      single = Fields.get_board_field(board.id, area.id)
      refute FieldDefinition.several?(single)
      assert area_of(both, single) == "web"
    end
  end

  describe "the REST API and MCP" do
    setup %{user: user} do
      {token, _} = Slipdock.Accounts.create_api_token(user, "several", scope: "write")

      api =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("accept", "application/json")

      %{api: api}
    end

    defp mcp(conn, tool, args) do
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: tool, arguments: args}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")
    end

    test "REST sets it from a list or labels, reads the keys, and refuses an unknown option",
         %{api: api, area: area, empty: empty} do
      api
      |> patch("/api/cards/#{empty.id}", %{fields: %{"area" => ["billing", "web"]}})
      |> json_response(200)

      read = api |> get("/api/cards/#{empty.id}") |> json_response(200)
      assert read["card"]["fields"]["area"] == ["web", "billing"]

      api
      |> patch("/api/cards/#{empty.id}", %{fields: %{"area" => "API, Billing"}})
      |> json_response(200)

      assert area_of(empty, area) == ["api", "billing"]

      refused =
        api
        |> patch("/api/cards/#{empty.id}", %{fields: %{"area" => "web, mobile"}})
        |> json_response(422)

      assert refused["error"] =~ "Area"
      assert area_of(empty, area) == ["api", "billing"]
    end

    test "MCP sets and reads the list of keys", %{api: api, area: area, empty: empty} do
      written = mcp(api, "update_card", %{card: empty.id, fields: %{"area" => ["api", "web"]}})
      assert written["isError"] == false, inspect(written["content"])
      assert area_of(empty, area) == ["web", "api"]

      got = mcp(api, "get_card", %{card: empty.id})
      assert mcp_data(got)["fields"]["area"] == ["web", "api"]
    end

    test "PATCHing the field's config switches it off without asking, keeping the first",
         %{api: api, board: board, area: area, both: both} do
      json =
        api
        |> patch("/api/boards/#{board.id}/fields/#{area.id}", %{config: %{several: false}})
        |> json_response(200)

      assert json["field"]["config"]["several"] == false
      assert area_of(both, Fields.get_board_field(board.id, area.id)) == "web"

      assert (api |> get("/api/cards/#{both.id}") |> json_response(200))["card"]["fields"]["area"] ==
               "web"
    end
  end
end
