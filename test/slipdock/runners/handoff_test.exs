defmodule Slipdock.Runners.HandoffTest do
  @moduledoc """
  A runner job that ends with its card still open leaves its summary as the
  card's handoff (W-1804) — unless the agent wrote one during the job, which
  stands.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Boards.Handoff

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Fix the login page"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "dev-box", "pool" => "dev"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "do it"})
    %{owner: owner, card: card, runner: runner, job: Runners.claim(runner)}
  end

  defp backdate(handoff, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)
    Repo.update_all(from(h in Handoff, where: h.id == ^handoff.id), set: [inserted_at: at])
  end

  test "a job ending with the card open leaves its summary as the handoff", ctx do
    {:ok, _} =
      Runners.finish(ctx.runner, ctx.job.id, %{
        exit: "1",
        output: "Write the migration test next\nState: the schema is in, the API isn't"
      })

    job_id = ctx.job.id

    assert %Handoff{
             next_step: "Write the migration test next",
             via: "runner",
             job_id: ^job_id,
             user_id: nil,
             body: body
           } = Boards.current_handoff(ctx.card)

    assert body =~ "State: the schema is in, the API isn't"
    assert body =~ "Job ##{job_id} on dev-box ended failed (exit 1)."
  end

  test "a done job whose card is still open leaves one too", ctx do
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0", output: "Review the PR"})
    assert %{next_step: "Review the PR"} = Boards.current_handoff(ctx.card)
  end

  test "with no summary, the next step points at the job", ctx do
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{status: "timeout"})

    assert %{next_step: next, body: body} = Boards.current_handoff(ctx.card)
    assert next == "Pick up where job ##{ctx.job.id} stopped (timeout): see its log"
    assert body == "Job ##{ctx.job.id} on dev-box ended timeout."
  end

  test "a long first line is cut to fit a next step", ctx do
    {:ok, _} =
      Runners.finish(ctx.runner, ctx.job.id, %{exit: "1", output: String.duplicate("x", 400)})

    next = Boards.current_handoff(ctx.card).next_step
    assert String.length(next) == 280
    assert String.ends_with?(next, "…")
  end

  test "a handoff the agent wrote during the job is not overwritten", ctx do
    {:ok, _} =
      Boards.leave_handoff(ctx.card, ctx.owner, %{next_step: "Agent's own", via: "mcp"})

    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "1", output: "Runner summary"})

    assert %{next_step: "Agent's own"} = Boards.current_handoff(ctx.card)
    assert length(Boards.handoff_history(ctx.card)) == 1
  end

  test "one from before the job was claimed is replaced", ctx do
    {:ok, old} = Boards.leave_handoff(ctx.card, ctx.owner, %{next_step: "Old", via: "ui"})
    backdate(old, 3600)

    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "1", output: "New from the job"})

    assert %{next_step: "New from the job"} = Boards.current_handoff(ctx.card)
    assert [%{via: "runner"}, %{next_step: "Old"}] = Boards.handoff_history(ctx.card)
  end

  test "a completed card gets none", ctx do
    {:ok, _} = Boards.update_card(ctx.card, %{"completed" => true})
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0", output: "Shipped"})
    assert Boards.handoff_history(ctx.card) == []
  end

  test "finishing twice writes it once", ctx do
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "1", output: "Once"})
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "1", output: "Twice"})
    assert [%{next_step: "Once"}] = Boards.handoff_history(ctx.card)
  end

  test "the runner prompt tells the agent to leave a handoff when stopping short" do
    text = Slipdock.Automations.Runner.unattended()
    assert text =~ "Whenever you stop with the card unfinished, leave a handoff"
    assert text =~ "leave_handoff"
    assert text =~ "slipdock handoff <id> --next"
  end
end
