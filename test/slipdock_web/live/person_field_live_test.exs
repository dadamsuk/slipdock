defmodule SlipdockWeb.PersonFieldLiveTest do
  @moduledoc """
  A person field (#3614) through its doors: the card's and the table's
  editors offer the board's members only, a former member held is shown
  marked and can be taken off, a reader sees names, the toolbar's filter
  offers Me, and the REST API and MCP set and read it and refuse a
  non-member.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Actor, Boards, Fields}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Reviews"}, owner: user)
    [_backlog, todo | _] = board.columns

    ann = user_fixture("ann-live@example.com")
    zed = user_fixture("zed-live@example.com")
    outsider = user_fixture("outsider-live@example.com")
    {:ok, ann_grant} = Access.grant(board, ann, "write", user)
    {:ok, _} = Access.grant(board, zed, "read", user)

    {:ok, field} = Fields.create_field(board, %{"name" => "Reviewers", "kind" => "person"})

    held = card_fixture(todo, %{"title" => "Held"})
    empty = card_fixture(todo, %{"title" => "Empty"})
    {:ok, _} = Fields.set_value(held, field, [ann.email, zed.email])

    %{
      conn: conn,
      board: board,
      field: field,
      ann: ann,
      ann_grant: ann_grant,
      zed: zed,
      outsider: outsider,
      held: held,
      empty: empty
    }
  end

  defp people_of(card, field), do: Fields.value(Boards.Cards.get_card!(card.id), field)
  defp box(form, user), do: ~s|#{form} input[type="checkbox"][value="#{user.id}"]|

  defp leave(ctx, owner),
    do: {:ok, _} = Access.revoke(ctx.ann_grant, actor: Actor.web(owner))

  describe "the card" do
    test "offers the members only, ticks those held and sets those ticked, in order",
         %{conn: conn, user: user} = ctx do
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.held}")
      form = "#field-form-#{ctx.field.id}"

      assert has_element?(view, box(form, ctx.ann) <> "[checked]")
      assert has_element?(view, box(form, ctx.zed) <> "[checked]")
      assert has_element?(view, box(form, user))
      refute has_element?(view, box(form, user) <> "[checked]")
      refute has_element?(view, box(form, ctx.outsider))

      view
      |> form(form, %{"value" => ["", to_string(ctx.zed.id), to_string(user.id)]})
      |> render_change()

      assert people_of(ctx.held, ctx.field) == [to_string(ctx.zed.id), to_string(user.id)]

      # A non-member sent anyway is refused, and nothing changes.
      view
      |> form(form)
      |> render_change(%{"field_id" => ctx.field.id, "value" => [to_string(ctx.outsider.id)]})

      assert people_of(ctx.held, ctx.field) == [to_string(ctx.zed.id), to_string(user.id)]
    end

    test "a former member held is shown marked, can be taken off, and isn't offered again",
         %{conn: conn, user: user} = ctx do
      leave(ctx, user)
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.held}")
      form = "#field-form-#{ctx.field.id}"

      assert has_element?(view, box(form, ctx.ann) <> "[checked]")
      assert has_element?(view, ~s|#{form} label[data-former]|, "(former member)")

      view |> form(form, %{"value" => ["", to_string(ctx.zed.id)]}) |> render_change()
      assert people_of(ctx.held, ctx.field) == [to_string(ctx.zed.id)]
      refute has_element?(view, box(form, ctx.ann))

      # Another card doesn't offer her at all.
      {:ok, other, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.empty}")
      refute has_element?(other, box(form, ctx.ann))
    end

    test "a reader sees names, a former member marked, and no boxes",
         %{user: user} = ctx do
      leave(ctx, user)
      reader = log_in_user(build_conn(), ctx.zed)
      {:ok, view, _} = live(reader, ~p"/boards/#{ctx.board}/cards/#{ctx.held}")
      field = "#card-field-#{ctx.field.id}"

      assert has_element?(view, "#{field} [data-people] .chip", ctx.zed.email)
      assert has_element?(view, "#{field} [data-people] .chip[data-former]", "(former member)")
      refute has_element?(view, ~s|#{field} input[type="checkbox"]|)
    end
  end

  test "the table's editor offers the members only and sets in place",
       %{conn: conn, user: user} = ctx do
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/table?fields=title,f:#{ctx.field.id}")
    cell = "#row-all-#{ctx.empty.id} [data-field-cell=reviewers]"

    assert has_element?(view, box(cell, user))
    refute has_element?(view, box(cell, ctx.outsider))

    view |> element("#{cell} form") |> render_change(%{"value" => ["", to_string(user.id)]})
    assert people_of(ctx.empty, ctx.field) == [to_string(user.id)]
  end

  test "the toolbar filter offers Me and the members, and Me keeps the viewer's cards",
       %{conn: conn, user: user} = ctx do
    {:ok, _} = Fields.set_value(ctx.empty, ctx.field, [user.email])
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}")
    filter = ~s|[data-field-filter="reviewers"] button|

    assert has_element?(view, filter, ctx.zed.email)
    refute has_element?(view, filter, ctx.outsider.email)

    view |> element(filter, "Me") |> render_click()
    path = assert_patch(view)
    assert render(view) =~ ctx.empty.title
    refute render(view) =~ ctx.held.title

    # The address keeps the token, so it means whoever opens it.
    {:ok, _, html} = live(log_in_user(build_conn(), ctx.zed), path)
    assert html =~ ctx.held.title
    refute html =~ ctx.empty.title
  end

  describe "the REST API and MCP" do
    setup %{user: user} do
      {token, _} = Slipdock.Accounts.create_api_token(user, "people", scope: "write")

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

    test "REST sets people by email and me, reads them as assignees are, and refuses a non-member",
         %{api: api, user: user} = ctx do
      api
      |> patch("/api/cards/#{ctx.empty.id}", %{fields: %{"reviewers" => "me, #{ctx.zed.email}"}})
      |> json_response(200)

      read = api |> get("/api/cards/#{ctx.empty.id}") |> json_response(200)

      assert read["card"]["fields"]["reviewers"] == [
               %{"id" => user.id, "name" => user.email, "email" => user.email},
               %{"id" => ctx.zed.id, "name" => ctx.zed.email, "email" => ctx.zed.email}
             ]

      refused =
        api
        |> patch("/api/cards/#{ctx.empty.id}", %{
          fields: %{"reviewers" => [ctx.outsider.email]}
        })
        |> json_response(422)

      assert refused["error"] =~ "#{ctx.outsider.email} isn't a member of this board"
      assert people_of(ctx.empty, ctx.field) == [to_string(user.id), to_string(ctx.zed.id)]

      # A former member is read with `former`.
      leave(ctx, user)
      read = api |> get("/api/cards/#{ctx.held.id}") |> json_response(200)
      assert [%{"id" => ann_id, "former" => true}, zed] = read["card"]["fields"]["reviewers"]
      assert ann_id == ctx.ann.id
      refute Map.has_key?(zed, "former")
    end

    test "MCP sets and reads people, and refuses a non-member", %{api: api} = ctx do
      written =
        mcp(api, "update_card", %{card: ctx.empty.id, fields: %{"reviewers" => [ctx.zed.email]}})

      assert written["isError"] == false
      got = mcp(api, "get_card", %{card: ctx.empty.id})
      assert [%{"email" => email}] = mcp_data(got)["fields"]["reviewers"]
      assert email == ctx.zed.email

      refused =
        mcp(api, "update_card", %{
          card: ctx.empty.id,
          fields: %{"reviewers" => [ctx.outsider.email]}
        })

      assert refused["isError"] == true
      assert people_of(ctx.empty, ctx.field) == [to_string(ctx.zed.id)]
    end
  end
end
