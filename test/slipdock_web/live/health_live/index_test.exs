defmodule SlipdockWeb.HealthLive.IndexTest do
  @moduledoc "The Health page (W-2310): what is stuck, what was lately, who can run it."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Repo}
  alias Slipdock.Health.Incident

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Ship"}, owner: owner)
    card = card_fixture(Enum.at(board.columns, 1), %{"title" => "Stalled"})
    %{board: board, card: card, owner: owner}
  end

  defp incident(board, attrs) do
    Repo.insert!(
      struct(
        %Incident{
          board_id: board.id,
          detector: "probe",
          fingerprint: "f#{System.unique_integer()}"
        },
        attrs
      )
    )
  end

  test "lists the stuck incidents with their cards and logs, then the recent ones", ctx do
    i =
      incident(ctx.board,
        card_id: ctx.card.id,
        summary: "Nobody takes job #3",
        status: "flagged",
        log: [%{"what" => "Found: Nobody takes job #3"}, %{"what" => "Flagged for a person."}]
      )

    incident(ctx.board, summary: "The feed sat idle", status: "fixed")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/health")

    assert has_element?(view, "#health-active #incident-#{i.id}", "Nobody takes job #3")
    assert has_element?(view, "#incident-#{i.id} a", "Stalled")
    assert has_element?(view, "#incident-#{i.id}", "Flagged for a person.")
    assert has_element?(view, "#health-recent", "The feed sat idle")
    refute has_element?(view, "#health-empty")
  end

  test "nothing stuck says so; a writer can run it now", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/health")
    assert has_element?(view, "#health-empty", "Nothing stuck")
    view |> element("#health-run") |> render_click()
    assert render(view) =~ "Looked the tree over: nothing stuck."
  end

  test "a reader can look but not run it; a stranger is sent away", ctx do
    reader = user_fixture("health-page-reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
    {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{ctx.board}/health")
    refute has_element?(view, "#health-run")
    assert render_hook(view, "run", %{}) =~ "read-only access"

    stranger = user_fixture("health-page-stranger@example.com")
    assert {:error, {_, %{to: "/"}}} = live(conn_as(stranger), ~p"/boards/#{ctx.board}/health")
  end

  test "a change on the tree reloads the page", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/health")
    incident(ctx.board, summary: "Appeared", status: "open")
    send(view.pid, {:health_changed, ctx.board.id})
    assert render(view) =~ "Appeared"
  end

  test "the stuck flag has its icon and label, and is in the flag list" do
    assert "stuck" in Slipdock.Boards.Card.flags()
    assert SlipdockWeb.SlipdockComponents.flag_label("stuck") == "Stuck"

    html = render_component(&SlipdockWeb.SlipdockComponents.flag_icon/1, flag: "stuck")
    assert html =~ "hero-lifebuoy"
    assert html =~ ~s(title="Stuck")
  end
end
