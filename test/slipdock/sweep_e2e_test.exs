defmodule Slipdock.SweepE2ETest do
  @moduledoc """
  Code sweeps, end to end (#1792, W-2310 §Sweeps and static checks), across
  its three parts: the Sweep Tool's Triage list holds what a sweep files
  without feeding the loop (#1793); a security issue a person moves on from
  Triage ships a pull request that doesn't describe the hole (#1794); and
  the machine that runs it reports skill and CLI drift (#1795).
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Repo, Runners, Sweep}
  alias Slipdock.Automations.Alert
  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Runners.{Drift, Job, Runner}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Public repo", "code" => unique_code()}, owner: user)

    {:ok, board} =
      Boards.update_board(board, %{"verify_work" => true, "ship_via" => "pull_request"})

    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})

    %{board: board, runner: runner, token: token}
  end

  defp column(board, name),
    do: Repo.one!(from(c in Column, where: c.board_id == ^board.id and c.name == ^name))

  defp feed_all(board) do
    board.id
    |> Automations.list_rules()
    |> Enum.filter(&Automations.Spec.feed?(&1.spec))
    |> Enum.map(&Automations.feed/1)
  end

  test "a sweep's finding waits in Triage, then ships neutrally from To Do, on a runner that reports drift",
       %{user: user, board: board, runner: runner, token: token} do
    # The Tool is installed: the rotation page, the Triage list and the daily card.
    {:ok, _} = Sweep.install(user, board)
    assert %{page: %{title: "Sweeps"}, card: %{title: "Sweep the code"}} = Sweep.find(board)
    triage = column(board, "Triage")
    assert triage.category == "triage"

    # The daily sweep card is put aside, so the feed's top card is the issue.
    sweep_card = Sweep.find(board).card

    Repo.update_all(from(c in Card, where: c.id == ^sweep_card.id),
      set: [archived_at: DateTime.utc_now()]
    )

    # Both lists have a feed rule: To Do's sends, Triage's never does.
    for list <- ["To Do", "Triage"] do
      rule_fixture(board, %{
        "trigger" => %{"type" => "list_top", "column" => list},
        "actions" => [%{"type" => "runner", "pool" => "loop"}]
      })
    end

    # The sweep files a security issue in Triage: nothing sends it to the loop.
    {:ok, issue} =
      Boards.create_card(triage, %{
        "title" => "Board events skip the write check",
        "description" => "Where, why it matters, the fix."
      })

    # The Tool made the `security` tag the procedure files them with.
    {:ok, security} = Boards.find_tag(board, "security")
    {:ok, _} = Boards.set_card_tags(issue, [security])
    feed_all(board)
    refute Repo.exists?(from(j in Job, where: j.card_id == ^issue.id))
    roles = SlipdockWeb.APIGuide.list_roles(Boards.get_board!(board.id).columns)
    refute roles.ready.id == triage.id

    # A person moves it into To Do: the feed sends it, and its prompt is neutral.
    :ok = Boards.move_card(issue.id, column(board, "To Do").id)
    feed_all(board)
    assert %Job{} = job = Repo.one(from(j in Job, where: j.card_id == ^issue.id))
    prompt = Runners.claimed_prompt(job)
    assert prompt =~ ~s|--title "Maintenance (##{issue.id})" --body "Card ##{issue.id}."|
    assert prompt =~ "Describe the change neutrally"
    refute prompt =~ "--fill"

    # The runner that claims it says its loop skill was edited by hand: one alert.
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("x-runner-skills", "slipdock-loop=" <> String.duplicate("a", 64))
      |> post("/api/runner/claim?wait=0")

    assert conn.status == 200
    assert get_resp_header(conn, "x-card-id") == [to_string(issue.id)]

    runner = Repo.get!(Runner, runner.id)
    assert Drift.states(runner).skills == {:drifted, ["slipdock-loop"]}

    assert [
             %Alert{
               title: "Runner box has drifted from this server: skills drifted (slipdock-loop)"
             }
           ] =
             Repo.all(from(a in Alert, where: a.board_id == ^board.id))
  end
end
