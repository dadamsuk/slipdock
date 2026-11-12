defmodule SlipdockWeb.NotShippedLineTest do
  @moduledoc """
  A merged card's not-shipped line (#2819,
  `Slipdock.Deployments.NotShipped`) through the doors: the card's API
  JSON, MCP `get_card` and the card panel carry it once the board's minutes
  have gone by, and drop it when a succeeded deploy names the card. And the
  board's `not_shipped_minutes` setting, over the API and the settings form.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments, Repo}
  alias Slipdock.Boards.{Board, Card}

  @sha "1a634c6aa0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5"

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Shipping", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})

    Repo.update_all(from(b in Board, where: b.id == ^board.id),
      set: [delivery_metrics_since: DateTime.add(DateTime.utc_now(), -86_400)]
    )

    card = card_fixture(List.last(board.columns), %{"title" => "Feature"})

    %{
      conn: conn,
      json: put_req_header(conn, "accept", "application/json"),
      board: Repo.get!(Board, board.id),
      card: card
    }
  end

  # Accepted and merged `minutes` ago.
  defp merge!(card, minutes) do
    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: [
        completed: true,
        completed_at: DateTime.add(DateTime.utc_now(:second), -minutes * 60),
        verify_state: "accepted",
        merge_sha: @sha
      ]
    )
  end

  defp deploy!(board, card) do
    sha = :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)
    now = DateTime.utc_now()

    {:ok, _} =
      Deployments.start(board, %{
        environment: "production",
        sha: sha,
        status: "succeeded",
        started_at: now,
        finished_at: now,
        commits: [%{"sha" => sha, "subject" => "feat ##{card.id}"}]
      })
  end

  test "the card's JSON carries it after the board's minutes, not before, and a deploy drops it",
       %{json: json, board: board, card: card} do
    merge!(card, 10)
    body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)
    refute Map.has_key?(body["card"], "not_shipped")

    merge!(card, 45)
    body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)

    assert %{
             "text" => "Merged 1a634c6 · not shipped after 45m",
             "sha" => @sha,
             "minutes" => 20,
             "seconds" => seconds,
             "merged_at" => merged_at
           } = body["card"]["not_shipped"]

    assert seconds in 2700..2760
    assert {:ok, _, 0} = DateTime.from_iso8601(merged_at)
    # The outcome beside it still says what merged.
    assert body["card"]["outcome"]["merge_sha"] == @sha
    refute Map.has_key?(body["card"], "shipped")

    deploy!(board, card)
    body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)
    refute Map.has_key?(body["card"], "not_shipped")
    assert [%{"text" => "Shipped to production" <> _}] = body["card"]["shipped"]
  end

  test "MCP get_card carries it, and drops it on a covering deploy", %{
    conn: conn,
    board: board,
    card: card
  } do
    refute Map.has_key?(mcp_card(conn, card), "not_shipped")

    merge!(card, 45)
    got = mcp_card(conn, card)
    assert got["not_shipped"]["text"] == "Merged 1a634c6 · not shipped after 45m"
    assert got["not_shipped"]["sha"] == @sha

    deploy!(board, card)
    refute Map.has_key?(mcp_card(conn, card), "not_shipped")
  end

  test "the card panel shows an amber line, until a deploy covers the card", %{
    conn: conn,
    board: board,
    card: card
  } do
    merge!(card, 10)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    refute has_element?(view, "#card-not-shipped")

    merge!(card, 45)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    assert has_element?(
             view,
             "#card-not-shipped.text-warning",
             "Merged 1a634c6 · not shipped after 45m"
           )

    deploy!(board, card)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    refute has_element?(view, "#card-not-shipped")
    assert has_element?(view, "#card-shipped", "Shipped to production")
  end

  describe "on a board that releases in batches (#2839)" do
    setup %{board: board} do
      {:ok, _} = Boards.update_board(board, %{"release_mode" => "batched"})
      %{board: Repo.get!(Board, board.id)}
    end

    # A release request covering `card`, started `minutes` ago.
    defp release!(board, card, minutes, status \\ "running") do
      Repo.insert!(%Slipdock.Releases.Request{
        board_id: board.id,
        status: status,
        card_ids: [card.id],
        started_at: DateTime.add(DateTime.utc_now(), -minutes * 60)
      })
    end

    test "the JSON, get_card and the panel carry nothing while the card only awaits release", %{
      conn: conn,
      json: json,
      board: board,
      card: card
    } do
      merge!(card, 600)

      body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)
      refute Map.has_key?(body["card"], "not_shipped")
      assert body["card"]["release"]["state"] == "awaiting"
      refute Map.has_key?(mcp_card(conn, card), "not_shipped")

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
      refute has_element?(view, "#card-not-shipped")
    end

    test "they carry it counted from the release, with release_requested_at", %{
      conn: conn,
      json: json,
      board: board,
      card: card
    } do
      merge!(card, 600)
      request = release!(board, card, 45, "failed")
      body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)

      assert %{
               "text" => "Merged 1a634c6 · not shipped 45m after its release started",
               "sha" => @sha,
               "minutes" => 20,
               "seconds" => seconds,
               "release_requested_at" => asked
             } = body["card"]["not_shipped"]

      assert seconds in 2700..2760
      assert {:ok, at, 0} = DateTime.from_iso8601(asked)
      assert DateTime.compare(at, request.started_at) == :eq

      got = mcp_card(conn, card)["not_shipped"]
      assert got["text"] == "Merged 1a634c6 · not shipped 45m after its release started"
      assert got["release_requested_at"]

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

      assert has_element?(
               view,
               "#card-not-shipped.text-warning",
               "Merged 1a634c6 · not shipped 45m after its release started"
             )

      # Released again ten minutes ago: the clock starts over, at every door.
      release!(board, card, 10)
      body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)
      refute Map.has_key?(body["card"], "not_shipped")
      refute Map.has_key?(mcp_card(conn, card), "not_shipped")
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
      refute has_element?(view, "#card-not-shipped")
    end
  end

  test "a board with delivery metrics off shows nothing", %{json: json, board: board, card: card} do
    merge!(card, 45)
    {:ok, _} = Boards.update_board(board, %{"delivery_metrics" => false})
    body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)
    refute Map.has_key?(body["card"], "not_shipped")
  end

  test "the API reads and sets the board's minutes, and refuses a bad one", %{
    json: json,
    board: board
  } do
    body = json |> get(~p"/api/boards/#{board.code}") |> json_response(200)
    assert body["board"]["not_shipped_minutes"] == 20

    body =
      json
      |> patch(~p"/api/boards/#{board.code}", %{"not_shipped_minutes" => 45})
      |> json_response(200)

    assert body["board"]["not_shipped_minutes"] == 45
    assert Repo.get!(Board, board.id).not_shipped_minutes == 45

    assert json
           |> patch(~p"/api/boards/#{board.code}", %{"not_shipped_minutes" => -1})
           |> json_response(422)

    assert Repo.get!(Board, board.id).not_shipped_minutes == 45
  end

  test "the settings form has the minutes beside the other delivery settings, and saves them", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board.id}/settings")
    assert has_element?(view, ~s|#board-not-shipped-minutes[value="20"]|)

    view
    |> form("#board-form", board: %{not_shipped_minutes: "45"})
    |> render_submit()

    assert Repo.get!(Board, board.id).not_shipped_minutes == 45

    # With delivery metrics off the delivery settings are not offered.
    {:ok, _} = Boards.update_board(Repo.get!(Board, board.id), %{"delivery_metrics" => false})
    {:ok, view, _html} = live(conn, ~p"/boards/#{board.id}/settings")
    refute has_element?(view, "#board-not-shipped-minutes")
  end
end
