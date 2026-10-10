defmodule SlipdockWeb.Meetings.CommitLiveTest do
  @moduledoc """
  The commit preview (#538, screen 7) and committing over the API: what
  will be written, grouped by destination; the stale check named; a commit
  that lands once; and the 409s for a second commit and for a stale target.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Boards, Meetings, Repo}
  alias Slipdock.Meetings.Version

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing", "code" => "PL"}, owner: user)

    card =
      card_fixture(Enum.find(board.columns, &(&1.name == "To Do")), %{
        "title" => "Pricing page refresh"
      })

    candidate = %{
      "type" => "card",
      "id" => card.id,
      "ref" => "##{card.id}",
      "title" => card.title,
      "lines" => ["L3"],
      "strength" => "id",
      "version" => Version.of(card)
    }

    change = %{
      "kind" => "card_change",
      "title" => "Refresh due Friday",
      "card" => "##{card.id}",
      "change" => %{"field" => "due_date", "to" => "2026-10-09"},
      "evidence" => [%{"line" => "L3", "quote" => "update PL-14 by Friday"}]
    }

    capture =
      reviewed_capture(
        board,
        user,
        [
          decision_finding(),
          action_finding(nil, %{
            "owner" => nil,
            "evidence" => [%{"line" => "L4", "quote" => "Yes, that's mine."}]
          }),
          change
        ],
        %{"candidates" => [candidate]}
      )

    %{board: board, card: card, capture: capture}
  end

  test "the preview shows each destination, and committing lands on the receipt", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}/preview")

    assert view |> element("#preview-new-cards") |> render() =~ "Update the pricing page"
    changes = view |> element("#preview-changes") |> render()
    assert changes =~ "##{ctx.card.id} Pricing page refresh"
    assert changes =~ "Due"
    assert changes =~ "Fri 9 Oct"
    assert view |> element("#preview-wiki") |> render() =~ "- **Annual plan at 20% off**"
    assert view |> element("#stale-check") |> render() =~ "Everything is as the review read it."

    view |> form("#commit-form") |> render_submit()
    assert_redirect(view, ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}")
    assert Meetings.get_capture!(ctx.capture.id).state == "committed"
  end

  test "a new meeting page is previewed whole, exactly as it is written", %{
    conn: conn,
    user: user
  } do
    board = board_fixture(%{"name" => "Hiring"}, owner: user)

    capture =
      reviewed_capture(
        board,
        user,
        [
          decision_finding(),
          decision_finding(%{
            "title" => "Start part-time",
            "topic" => "The role",
            "evidence" => [%{"line" => "L3", "quote" => "update PL-14 by Friday"}]
          })
        ],
        %{},
        %{
          notes: %{
            "summary" => "A CTO interview.",
            "topics" => [%{"title" => "Equity", "summary" => "Rate plus equity."}]
          }
        }
      )

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}/preview")
    [change] = Slipdock.Meetings.Commit.build(capture)["changes"]
    shown = view |> element("#page-#{change["id"]}") |> render()

    for words <- [
          "**Summary.** A CTO interview.",
          "**Equity.** Rate plus equity.",
          "## Pricing",
          "## The role"
        ],
        do: assert(shown =~ words)

    view |> form("#commit-form") |> render_submit()
    [written] = Meetings.get_capture!(capture.id).change_set["changes"]
    page = Repo.get!(Slipdock.Wiki.Page, written["page_id"])

    # What the preview showed is the page, character for character.
    assert shown =~ Phoenix.HTML.html_escape(page.body) |> Phoenix.HTML.safe_to_string()
  end

  test "a card edited after the review is named, and commit is held back", ctx do
    {:ok, _} = Boards.update_card(ctx.card, %{"title" => "Renamed meanwhile"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}/preview")

    assert has_element?(view, "#stale-check [data-stale='##{ctx.card.id}']")
    assert has_element?(view, "#commit-now[disabled]")
  end

  test "a change made between opening the preview and pressing commit stops it", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}/preview")
    {:ok, _} = Boards.update_card(ctx.card, %{"title" => "Renamed meanwhile"})

    html = view |> form("#commit-form") |> render_submit()
    assert html =~ "Something moved since the review read it. Nothing was written."
    assert Meetings.get_capture!(ctx.capture.id).state == "ready"
  end

  test "somebody who can only read the board is not shown the preview", ctx do
    reader = user_fixture("reader@example.com")
    share_fixture(ctx.board, [reader], "read")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(conn_as(reader), ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}/preview")
  end

  describe "the API" do
    test "preview, then commit with its digest; a second commit is a 409 that writes nothing",
         ctx do
      preview = ctx.conn |> get(~p"/api/captures/#{ctx.capture.id}/preview") |> json_response(200)
      assert preview["stale"] == []

      assert Enum.map(preview["preview"]["changes"], & &1["op"]) == [
               "create_card",
               "update_card",
               "decision_entry"
             ]

      body =
        ctx.conn
        |> post(~p"/api/captures/#{ctx.capture.id}/commit", %{
          "preview" => preview["preview"]["digest"]
        })
        |> json_response(200)

      assert body["capture"]["state"] == "committed"
      cards = Repo.aggregate(Slipdock.Boards.Card, :count)

      again = ctx.conn |> post(~p"/api/captures/#{ctx.capture.id}/commit") |> json_response(409)
      assert again["error"] == "this capture was committed already; it is never written twice"
      assert Repo.aggregate(Slipdock.Boards.Card, :count) == cards
    end

    test "a stale target is a 409 naming it", ctx do
      {:ok, _} = Boards.update_card(ctx.card, %{"title" => "Renamed meanwhile"})
      body = ctx.conn |> post(~p"/api/captures/#{ctx.capture.id}/commit") |> json_response(409)
      assert body["error"] =~ "##{ctx.card.id} (it was changed after the review read it)"
      assert [%{"ref" => ref}] = body["stale"]
      assert ref == "##{ctx.card.id}"
    end

    test "an out-of-date preview digest is a 409", ctx do
      body =
        ctx.conn
        |> post(~p"/api/captures/#{ctx.capture.id}/commit", %{"preview" => "0000"})
        |> json_response(409)

      assert body["error"] =~ "the review changed since that preview"
    end

    test "a read-only member gets a 403", ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, [reader], "read")
      conn_as(reader) |> post(~p"/api/captures/#{ctx.capture.id}/commit") |> json_response(403)
    end
  end
end
