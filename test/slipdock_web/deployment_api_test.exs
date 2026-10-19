defmodule SlipdockWeb.DeploymentAPITest do
  @moduledoc """
  How deploys get in (#1134): the board's deploy token, issued, rotated and
  revoked by the owner, and the three endpoints CI calls with it. The token
  records deploys for its own board and does nothing else; the endpoints
  refuse while the board's delivery metrics are off; card ids are read from
  commit messages with the board's pattern and kept only for its own cards.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments, Repo}
  alias Slipdock.Deployments.Deployment

  @sha "aaaaaaa1111111"
  @sha2 "bbbbbbb2222222"

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Pipeline"}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    [_backlog, todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Ship me"})
    owner = put_req_header(conn, "accept", "application/json")

    %{"token" => token} =
      owner |> post(~p"/api/boards/#{board.code}/deploy-token") |> json_response(200)

    %{owner: owner, board: board, card: card, todo: todo, token: token}
  end

  defp ci(token) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp start(token, attrs) do
    ci(token) |> post(~p"/api/deployments", Map.merge(%{"environment" => "production"}, attrs))
  end

  test "issuing shows the token once and keeps only its hash", %{board: board, token: token} do
    assert "sdd_" <> _ = token
    stored = Repo.get!(Slipdock.Boards.Board, board.id)
    assert stored.deploy_token_hash == :crypto.hash(:sha256, token)
    refute inspect(stored) =~ token
    assert Deployments.authenticate(token).id == board.id
  end

  test "a start, a finish and the last sha", %{token: token, card: card} do
    body =
      token
      |> start(%{
        "sha" => @sha,
        "tag" => "v1.0.0",
        "commits" => [
          %{
            "sha" => @sha,
            "committed_at" => "2026-10-18T10:00:00Z",
            "subject" => "feat: ship it (##{card.id})"
          }
        ]
      })
      |> json_response(201)

    d = body["deployment"]
    assert d["status"] == "started"
    assert d["cards"] == [card.id]

    assert [%{"sha" => @sha, "cards" => [_], "committed_at" => "2026-10-18T10:00:00Z"}] =
             d["commits"]

    assert ci(token)
           |> get(~p"/api/deployments/last?environment=production")
           |> json_response(200)
           |> Map.get("sha") == nil

    assert ci(token)
           |> patch(~p"/api/deployments/#{d["id"]}", %{"status" => "succeeded"})
           |> json_response(200)
           |> get_in(["deployment", "status"]) == "succeeded"

    last =
      ci(token) |> get(~p"/api/deployments/last?environment=production") |> json_response(200)

    assert last["sha"] == @sha
    assert last["deployment"]["tag"] == "v1.0.0"

    assert ci(token)
           |> get(~p"/api/deployments/last?environment=staging")
           |> json_response(200)
           |> Map.get("sha") == nil
  end

  test "finishing twice, or with a bad status, is a 422", %{token: token} do
    id = token |> start(%{"sha" => @sha}) |> json_response(201) |> get_in(["deployment", "id"])

    assert ci(token)
           |> patch(~p"/api/deployments/#{id}", %{"status" => "done"})
           |> json_response(422)

    assert ci(token)
           |> patch(~p"/api/deployments/#{id}", %{"status" => "failed"})
           |> json_response(200)

    assert ci(token)
           |> patch(~p"/api/deployments/#{id}", %{"status" => "succeeded"})
           |> json_response(422)
  end

  test "an unknown deploy, or another board's, is a 404", %{token: token, user: user} do
    assert ci(token)
           |> patch(~p"/api/deployments/999999", %{"status" => "failed"})
           |> json_response(404)

    other = board_fixture(%{"name" => "Theirs"}, owner: user)
    {:ok, other} = Boards.update_board(other, %{"delivery_metrics" => true})
    {:ok, theirs} = Deployments.start(other, %{environment: "production", sha: @sha})

    assert ci(token)
           |> patch(~p"/api/deployments/#{theirs.id}", %{"status" => "failed"})
           |> json_response(404)

    assert Repo.get!(Deployment, theirs.id).status == "started"
  end

  test "the deploy token can't read or write anything else", %{
    token: token,
    board: board,
    card: card
  } do
    assert ci(token) |> get(~p"/api/boards/#{board.code}") |> json_response(401)
    assert ci(token) |> get(~p"/api/cards/#{card.id}") |> json_response(401)
    assert ci(token) |> get(~p"/api/boards") |> json_response(401)

    assert ci(token)
           |> post(~p"/api/boards/#{board.code}/cards", %{"title" => "sneaky"})
           |> json_response(401)
  end

  test "an API token, or none, can't record deploys", %{owner: owner} do
    assert owner |> post(~p"/api/deployments", %{"sha" => @sha}) |> json_response(401)

    assert build_conn()
           |> put_req_header("accept", "application/json")
           |> post(~p"/api/deployments", %{"sha" => @sha})
           |> json_response(401)

    assert Repo.aggregate(Deployment, :count) == 0
  end

  test "refused while the switch is off, saying how to turn it on", %{token: token, board: board} do
    {:ok, _} = Boards.update_board(board, %{"delivery_metrics" => false})

    body = token |> start(%{"sha" => @sha}) |> json_response(403)
    assert body["error"] == "delivery_metrics_off"
    assert body["message"] =~ "--delivery-metrics"
    assert ci(token) |> get(~p"/api/deployments/last") |> json_response(403)
    assert Repo.aggregate(Deployment, :count) == 0
  end

  test "rotating replaces the token, and revoking ends it", %{
    owner: owner,
    board: board,
    token: old
  } do
    %{"token" => new} =
      owner |> post(~p"/api/boards/#{board.code}/deploy-token") |> json_response(200)

    assert new != old
    assert old |> start(%{"sha" => @sha}) |> json_response(401)
    assert new |> start(%{"sha" => @sha}) |> json_response(201)

    assert owner
           |> get(~p"/api/boards/#{board.code}")
           |> json_response(200)
           |> get_in(["board", "deploy_token"])

    assert owner |> delete(~p"/api/boards/#{board.code}/deploy-token") |> json_response(200)
    assert new |> start(%{"sha" => @sha2}) |> json_response(401)
    refute Deployments.token?(Boards.get_board!(board.id))
  end

  test "only the owner issues a token", %{board: board} do
    stranger = user_fixture("stranger@example.com")

    assert conn_as(stranger)
           |> put_req_header("accept", "application/json")
           |> post(~p"/api/boards/#{board.code}/deploy-token")
           |> json_response(404)
  end

  test "card refs: none, several, unknown, and another tree's cards are dropped", %{
    token: token,
    card: card,
    todo: todo,
    user: user
  } do
    other_card = card_fixture(todo, %{"title" => "Also"})
    foreign = board_fixture(%{"name" => "Elsewhere"}, owner: user)
    [_, foreign_todo | _] = foreign.columns
    foreign_card = card_fixture(foreign_todo, %{"title" => "Not yours"})

    commits = [
      %{"sha" => @sha2, "subject" => "fix ##{card.id} and ##{other_card.id}, ##{card.id} again"},
      %{"sha" => @sha, "subject" => "chore: no refs at all"},
      %{"sha" => "ccccccc3333333", "subject" => "touch ##{foreign_card.id} and #999999999"},
      %{"subject" => "no sha: dropped"},
      "not a map"
    ]

    d = token |> start(%{"sha" => @sha2, "commits" => commits}) |> json_response(201)
    d = d["deployment"]

    assert Enum.map(d["commits"], & &1["cards"]) == [[card.id, other_card.id], [], []]
    assert Enum.sort(d["cards"]) == Enum.sort([card.id, other_card.id])
  end

  test "a card on a sub-board of the board counts", %{token: token, card: card} do
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(card, t)
    [first | _] = Boards.get_board!(sub.id).columns
    child = card_fixture(first, %{"title" => "Child"})

    d =
      token
      |> start(%{"sha" => @sha, "commits" => [%{"sha" => @sha, "subject" => "do ##{child.id}"}]})
      |> json_response(201)

    assert d["deployment"]["cards"] == [child.id]
  end

  test "a board's own card ref pattern", %{owner: owner, board: board, token: token, card: card} do
    assert owner
           |> patch(~p"/api/boards/#{board.code}", %{"card_ref_pattern" => "no groups"})
           |> json_response(422)

    assert owner
           |> patch(~p"/api/boards/#{board.code}", %{"card_ref_pattern" => "(unclosed"})
           |> json_response(422)

    assert owner
           |> patch(~p"/api/boards/#{board.code}", %{"card_ref_pattern" => "PROJ-(\\d+)"})
           |> json_response(200)
           |> get_in(["board", "card_ref_pattern"]) == "PROJ-(\\d+)"

    assert ci(token)
           |> get(~p"/api/deployments/last")
           |> json_response(200)
           |> Map.get("card_ref_pattern") == "PROJ-(\\d+)"

    commits = [%{"sha" => @sha, "subject" => "PROJ-#{card.id}: done, not ##{card.id + 1}"}]
    d = token |> start(%{"sha" => @sha, "commits" => commits}) |> json_response(201)
    assert d["deployment"]["cards"] == [card.id]

    owner |> patch(~p"/api/boards/#{board.code}", %{"card_ref_pattern" => ""})
    assert Boards.get_board!(board.id).card_ref_pattern == nil
  end

  describe "incident-of" do
    setup %{token: token} do
      id = token |> start(%{"sha" => @sha}) |> json_response(201) |> get_in(["deployment", "id"])
      %{deployment_id: id}
    end

    test "links a card to the deploy that caused it, and unlinks it", %{
      owner: owner,
      card: card,
      deployment_id: id
    } do
      body =
        owner
        |> post(~p"/api/cards/#{card.id}/incident-of", %{"deployment" => id})
        |> json_response(200)

      assert body == %{"card" => card.id, "incident_of" => id}
      assert Repo.get!(Slipdock.Boards.Card, card.id).caused_by_deployment_id == id

      assert owner |> delete(~p"/api/cards/#{card.id}/incident-of") |> json_response(200) ==
               %{"card" => card.id, "incident_of" => nil}
    end

    test "no deployment is a 400, an unknown one a 404", %{owner: owner, card: card} do
      assert owner |> post(~p"/api/cards/#{card.id}/incident-of", %{}) |> json_response(400)

      assert owner
             |> post(~p"/api/cards/#{card.id}/incident-of", %{"deployment" => 999_999})
             |> json_response(404)
    end

    test "someone who can't write the card can't link it", %{card: card, deployment_id: id} do
      stranger = user_fixture("incident-stranger@example.com")

      assert conn_as(stranger)
             |> put_req_header("accept", "application/json")
             |> post(~p"/api/cards/#{card.id}/incident-of", %{"deployment" => id})
             |> json_response(403)

      assert Repo.get!(Slipdock.Boards.Card, card.id).caused_by_deployment_id == nil
    end

    test "the board's incident settings are read and set", %{owner: owner, board: board} do
      body = owner |> get(~p"/api/boards/#{board.code}") |> json_response(200)
      assert body["board"]["incident_tag"] == "incident"
      assert body["board"]["hotfix_window_hours"] == 24

      body =
        owner
        |> patch(~p"/api/boards/#{board.code}", %{
          "incident_tag" => "sev",
          "hotfix_window_hours" => 6
        })
        |> json_response(200)

      assert body["board"]["incident_tag"] == "sev"
      assert body["board"]["hotfix_window_hours"] == 6

      assert owner
             |> patch(~p"/api/boards/#{board.code}", %{"hotfix_window_hours" => 100_000})
             |> json_response(422)
    end
  end

  describe "backfill" do
    defp backfill(token, sha, at) do
      start(token, %{
        "sha" => sha,
        "tag" => "v-" <> sha,
        "status" => "succeeded",
        "started_at" => at,
        "finished_at" => at,
        "source" => "backfill"
      })
    end

    test "recorded at the tag's date, and twice is once", %{token: token} do
      body = token |> backfill(@sha, "2026-03-01T10:00:00+01:00") |> json_response(201)
      d = body["deployment"]
      assert d["status"] == "succeeded"
      assert d["source"] == "backfill"
      assert d["started_at"] =~ "2026-03-01T09:00:00"
      refute body["existing"]

      again = token |> backfill(@sha, "2026-03-01T10:00:00+01:00") |> json_response(200)
      assert again["existing"] == true
      assert again["deployment"]["id"] == d["id"]
      assert Repo.aggregate(Deployment, :count) == 1
    end

    test "a sha CI already recorded isn't backfilled again", %{token: token} do
      id = token |> start(%{"sha" => @sha}) |> json_response(201) |> get_in(["deployment", "id"])

      assert token
             |> backfill(@sha, "2026-03-01T10:00:00Z")
             |> json_response(200)
             |> get_in(["deployment", "id"]) == id
    end

    test "the key is per environment, and an ordinary deploy is never deduplicated", %{
      token: token
    } do
      token |> backfill(@sha, "2026-03-01T10:00:00Z") |> json_response(201)

      assert token
             |> start(%{
               "environment" => "staging",
               "sha" => @sha,
               "status" => "succeeded",
               "source" => "backfill"
             })
             |> json_response(201)

      assert token |> start(%{"sha" => @sha}) |> json_response(201)
      assert Repo.aggregate(Deployment, :count) == 3
    end
  end
end
