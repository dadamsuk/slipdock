defmodule SlipdockWeb.Meetings.VisibilityTest do
  @moduledoc """
  A capture on a sub-board, read with its parent board, shown to a member
  of the sub-board alone (#549, G12): the parent board's cards it names are
  "a card you can't open" to them — on the review, the preview, the API
  and MCP — and in full to whoever can open them.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.Boards
  alias Slipdock.Meetings.Version

  setup %{user: user} do
    meetings_on()
    parent = board_fixture(%{"name" => "Company"}, owner: user)
    todo = Enum.find(parent.columns, &(&1.name == "To Do"))
    secret = card_fixture(todo, %{"title" => "Secret acquisition plan"})
    epic = card_fixture(todo, %{"title" => "Pricing epic"})
    {:ok, template} = Boards.find_template("Simple")
    {:ok, sub} = sub_board(epic, template)
    sub = Boards.get_board!(sub.id)

    member = user_fixture("member@example.com")
    share_fixture(sub, [member], "write")

    candidate = %{
      "type" => "card",
      "id" => secret.id,
      "ref" => "##{secret.id}",
      "title" => secret.title,
      "summary" => "Buy the competitor",
      "lines" => ["L3"],
      "strength" => "id",
      "version" => Version.of(secret)
    }

    change = %{
      "kind" => "card_change",
      "title" => "Move the date",
      "card" => "##{secret.id}",
      "change" => %{"field" => "due_date", "to" => "2026-10-09"},
      "evidence" => [%{"line" => "L3", "quote" => "update PL-14 by Friday"}]
    }

    capture =
      reviewed_capture(sub, user, [change], %{"candidates" => [candidate]}, %{
        context_scope: %{"board" => true, "wiki" => true, "parent" => true}
      })

    %{sub: sub, member: member, capture: capture, secret: secret}
  end

  test "the review names it to its owner, and hides it from the sub-board's member", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.sub}/meetings/#{ctx.capture.id}")
    assert render(view) =~ "Secret acquisition plan"

    {:ok, view, _} = live(conn_as(ctx.member), ~p"/boards/#{ctx.sub}/meetings/#{ctx.capture.id}")
    html = render(view)
    refute html =~ "Secret acquisition plan"
    refute html =~ "Buy the competitor"
    assert html =~ "a card you can&#39;t open"
  end

  test "the API and the preview hide it too", ctx do
    member = conn_as(ctx.member)
    body = member |> get(~p"/api/captures/#{ctx.capture.id}") |> response(200)
    refute body =~ "Secret acquisition plan"

    preview = member |> get(~p"/api/captures/#{ctx.capture.id}/preview") |> response(200)
    refute preview =~ "Secret acquisition plan"

    {:ok, view, _} = live(member, ~p"/boards/#{ctx.sub}/meetings/#{ctx.capture.id}/preview")
    refute render(view) =~ "Secret acquisition plan"

    # The owner, who can open it, sees it.
    assert ctx.conn |> get(~p"/api/captures/#{ctx.capture.id}") |> response(200) =~
             "Secret acquisition plan"
  end

  test "nor can the member commit a change to a board they can't write", ctx do
    assert {:error, :forbidden, _} = Slipdock.Meetings.Commit.commit(ctx.capture, ctx.member)
  end
end
