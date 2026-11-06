defmodule SlipdockWeb.UnworkedInProgressWebTest do
  @moduledoc """
  #1922 where people and runners read it: a card in progress with no open
  job is named by no held line — not in a card's jobs on the board page,
  not as a job's `waiting_on` over the API, not in a claim's `waiting` —
  and one with a job open on it still is.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Unworked web"}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "laptop", "pool" => "dev"})
    # Seen just now, so the held line doesn't fall through to "No runner online".
    runner |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now(:second)) |> Repo.update!()

    busy = card_fixture(doing, %{"title" => "In progress"})
    card = card_fixture(todo, %{"title" => "Next"})

    {:ok, job} =
      Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go", wait_while_doing: true})

    %{
      conn: conn,
      board: board,
      busy: busy,
      card: card,
      job: job
    }
  end

  defp listed(ctx) do
    ctx.conn
    |> put_req_header("accept", "application/json")
    |> get(~p"/api/boards/#{ctx.board.id}/jobs?status=open")
    |> json_response(200)
    |> Map.fetch!("jobs")
    |> Enum.find(&(&1["id"] == ctx.job.id))
  end

  defp claim(ctx) do
    ctx.conn
    |> put_req_header("accept", "application/json")
    |> post(~p"/api/boards/#{ctx.board.id}/jobs/claim", %{"pool" => "dev"})
    |> json_response(200)
  end

  test "with no job on the card in progress, nothing names it", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    refute has_element?(view, "#card-job-held-#{ctx.job.id}")

    assert listed(ctx)["waiting_on"] == nil
    assert claim(ctx)["job"]["id"] == ctx.job.id
  end

  test "with a job open on the card in progress, each place names it", ctx do
    working_job_fixture(ctx.busy, %{pool: "elsewhere"})
    line = "##{ctx.busy.id} is in progress"

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    assert has_element?(view, "#card-job-held-#{ctx.job.id}", "Held: #{line}")

    assert listed(ctx)["waiting_on"] == line
    body = claim(ctx)
    assert body["job"] == nil
    assert body["waiting"]["reason"] == line
  end
end
