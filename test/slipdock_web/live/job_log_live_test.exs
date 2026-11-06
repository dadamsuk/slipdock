defmodule SlipdockWeb.JobLogLiveTest do
  # A running job's live log (#1871) on the card's job panel and in a
  # runner's details on the Runners panel: one line per message, tool call
  # or result, updated as the runner sends more, without a reload.
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Runners
  alias Slipdock.Runners.Transcript
  alias SlipdockWeb.BoardLive.JobLogComponent

  @first """
  {"type":"user","timestamp":"2026-11-06T12:13:05Z","message":{"content":"Work on Slipdock card #4"}}
  {"type":"assistant","timestamp":"2026-11-06T12:13:07Z","message":{"content":[{"type":"text","text":"Reading the card first."},{"type":"tool_use","name":"Bash","input":{"command":"slipdock card 4","description":"Read it"}}]}}
  """

  @second """
  {"type":"user","timestamp":"2026-11-06T12:13:09Z","message":{"content":[{"type":"tool_result","content":"#4 Fix it\\nthe second line\\nthe third"}]}}
  {"type":"user","timestamp":"2026-11-06T12:13:10Z","message":{"content":[{"type":"tool_result","is_error":true,"content":"exit 1"}]}}
  """

  setup %{user: user} do
    board = board_fixture(%{"name" => "Agents"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Fix it"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "laptop", "pool" => "dev"})
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    %{board: board, card: card, runner: runner, job: job}
  end

  defp lines(view, id), do: view |> element("##{id}-lines") |> render()

  test "the card's job panel shows a running job's log and follows it live", ctx do
    Runners.claim(ctx.runner)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    id = JobLogComponent.id("card", ctx.job.id)

    # Running, so the log is open and says nothing has come yet.
    assert has_element?(view, "##{id}-toggle", "updating")
    assert has_element?(view, "##{id}-empty", "about once a minute")

    {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, @first)
    render(view)
    html = lines(view, id)
    assert html =~ "Work on Slipdock card #4"
    assert html =~ "Reading the card first."
    assert html =~ "Bash: slipdock card 4"
    refute has_element?(view, "##{id}-empty")
    assert has_element?(view, "##{id}-toggle", "2 lines")

    # Only the new lines are read and added under the old ones.
    {:ok, 4} = Transcript.append(ctx.runner, ctx.job.id, 2, @second)
    render(view)
    html = lines(view, id)
    assert html =~ "#4 Fix it  (+2 lines)"
    assert html =~ "exit 1"
    [first, last] = [:binary.match(html, "Reading the card"), :binary.match(html, "exit 1")]
    assert elem(first, 0) < elem(last, 0), "newest at the bottom"
    assert has_element?(view, ~s(##{id}-lines li[data-kind="error"]), "exit 1")
  end

  test "a line with more to it opens to the whole call", ctx do
    Runners.claim(ctx.runner)
    {:ok, 4} = Transcript.append(ctx.runner, ctx.job.id, 0, @first <> @second)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    id = JobLogComponent.id("card", ctx.job.id)

    # The tool call: its summary, and the whole input under it.
    assert has_element?(view, "##{id}-lines details summary", "Bash: slipdock card 4")
    assert has_element?(view, "##{id}-lines details pre", ~s("description": "Read it"))
    # The result: its first line, and all of it under it.
    assert has_element?(view, "##{id}-lines details pre", "the third")
    # A line with nothing more is no details at all.
    refute has_element?(view, "##{id}-lines details summary", "Reading the card first.")
    assert has_element?(view, "##{id}-lines li", "Reading the card first.")
  end

  test "a finished job's log is folded until opened; one with no log shows none", ctx do
    Runners.claim(ctx.runner)
    {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, @first)
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})

    {:ok, empty} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "again"})
    Runners.claim(ctx.runner)
    {:ok, _} = Runners.finish(ctx.runner, empty.id, %{exit: "0"})

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    id = JobLogComponent.id("card", ctx.job.id)

    assert has_element?(view, "##{id}-toggle", "2 lines")
    refute has_element?(view, "##{id}-toggle", "updating")
    refute has_element?(view, "##{id}-lines")
    refute has_element?(view, "#" <> JobLogComponent.id("card", empty.id))

    view |> element("##{id}-toggle") |> render_click()
    assert lines(view, id) =~ "Reading the card first."
    # Folding and opening again reads it afresh, once.
    view |> element("##{id}-toggle") |> render_click()
    refute has_element?(view, "##{id}-lines")
    view |> element("##{id}-toggle") |> render_click()
    html = lines(view, id)
    assert length(String.split(html, "Reading the card first.")) == 2
  end

  test "a long log starts near its end and says how to read the rest", ctx do
    Runners.claim(ctx.runner)

    body =
      Enum.map_join(1..310, "", fn n ->
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"step #{n}"}]}}\n)
      end)

    {:ok, 310} = Transcript.append(ctx.runner, ctx.job.id, 0, body)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    id = JobLogComponent.id("card", ctx.job.id)

    assert has_element?(view, "##{id}-skipped", "10 earlier lines not shown")
    assert has_element?(view, "##{id}-skipped", "slipdock job-log #{ctx.job.id}")
    html = lines(view, id)
    assert html =~ "step 310"
    assert html =~ ~r/step 11\s*</
    refute html =~ ~r/step 10\s*</
  end

  test "the Runners panel shows the runner's current job's log, live", ctx do
    Runners.claim(ctx.runner)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")
    view |> element("#show-runner-#{ctx.runner.id}") |> render_click()
    id = JobLogComponent.id("runner", ctx.job.id)
    assert has_element?(view, "#runner-now-#{ctx.runner.id} ##{id}-toggle", "updating")

    {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, @first)
    render(view)
    assert lines(view, id) =~ "Bash: slipdock card 4"
  end
end
