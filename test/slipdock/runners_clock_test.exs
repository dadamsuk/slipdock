defmodule Slipdock.RunnersClockTest do
  # The automation scheduler's clock is what takes back jobs whose lease ran
  # out. Sync: the scheduler is one process for the node, so it needs the
  # shared sandbox to see this test's rows.
  use Slipdock.DataCase, async: false

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.Job

  test "a scheduler tick requeues a job whose runner stopped answering" do
    board = board_fixture()
    card = card_fixture(hd(board.columns))
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "r", "pool" => "dev"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "x"})
    job = Runners.claim(runner)

    past = DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)
    Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [lease_expires_at: past])

    Slipdock.Automations.Scheduler.run_now()
    assert Repo.get!(Job, job.id).status == "queued"
  end
end
