defmodule SlipdockWeb.JobLogLiveTest do
  # A running job's live log (#1871) on the card's job panel and in a
  # runner's details on the Runners panel: one line per message, tool call
  # or result, updated as the runner sends more, without a reload.
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
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

  describe "what becomes of the log (#1872)" do
    defp ended(ctx, status \\ "done") do
      Runners.claim(ctx.runner)
      {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, @first)
      exit = if status == "done", do: "0", else: "1"
      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: exit, status: status})
      Slipdock.Repo.get!(Slipdock.Runners.Job, ctx.job.id)
    end

    test "an ended job says when its log goes, and Keep this log keeps it", ctx do
      job = ended(ctx)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      id = JobLogComponent.id("card", job.id)

      assert has_element?(view, "##{id}-expires", "unless kept")
      refute has_element?(view, "##{id}-expires", "the work failed")
      expires = Slipdock.Runners.TranscriptRetention.expires_at(job)

      assert has_element?(
               view,
               ~s(##{id}-expires time[datetime="#{DateTime.to_iso8601(expires)}"])
             )

      view |> element("##{id}-keep") |> render_click()

      job = Slipdock.Repo.get!(Slipdock.Runners.Job, job.id)
      page = Slipdock.Wiki.get_page(job.transcript_page_id)
      assert page.title =~ "Pass #{ctx.card.id} ("

      assert has_element?(
               view,
               ~s(##{id}-kept a[href="/boards/#{page.board_id}/wiki/#{page.slug}"])
             )

      assert has_element?(view, "##{id}-kept", page.title)
      refute has_element?(view, "##{id}-keep")
      refute has_element?(view, "##{id}-expires")
      # The card's Docs list it without a reload.
      assert has_element?(view, "#card-docs", page.title)
    end

    test "a failure keeps longer, and says so", ctx do
      ended(ctx, "failed")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      id = JobLogComponent.id("card", ctx.job.id)
      assert has_element?(view, "##{id}-expires", "kept longer: the work failed")
    end

    test "a deleted log says when it went, with nothing to keep", ctx do
      job = ended(ctx)

      Slipdock.Repo.update_all(
        from(j in Slipdock.Runners.Job, where: j.id == ^job.id),
        set: [finished_at: ~U[2020-01-01 00:00:00Z]]
      )

      1 = Slipdock.Runners.TranscriptRetention.sweep()
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      id = JobLogComponent.id("card", job.id)
      assert has_element?(view, "##{id}-deleted", "Log deleted")
      refute has_element?(view, "##{id}-keep")
      refute has_element?(view, "##{id}-expires")
    end

    test "someone who can only read the card sees when it goes, but no Keep", ctx do
      ended(ctx)
      reader = user_fixture("reader#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [reader], "read")

      {:ok, view, _} =
        live(log_in_user(build_conn(), reader), ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      id = JobLogComponent.id("card", ctx.job.id)
      assert has_element?(view, "##{id}-expires")
      refute has_element?(view, "##{id}-keep")
    end

    test "a keep that fails says why in the panel", ctx do
      job = ended(ctx)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      id = JobLogComponent.id("card", job.id)

      # The log goes between the page drawing and the click.
      Slipdock.Repo.update_all(
        from(j in Slipdock.Runners.Job, where: j.id == ^job.id),
        set: [finished_at: ~U[2020-01-01 00:00:00Z]]
      )

      Slipdock.Runners.TranscriptRetention.sweep()
      view |> element("##{id}-keep") |> render_click()
      assert has_element?(view, "##{id}-keep-error", "no log to keep")
    end
  end

  describe "the board's job log times (#1872)" do
    test "are set in the board's settings", ctx do
      {:ok, view, _} = live(ctx.conn, agentic_path(ctx.board))
      assert has_element?(view, "#board-job-logs #board-job-log-hours[value=\"24\"]")
      assert has_element?(view, "#board-job-logs #board-failure-log-hours[value=\"168\"]")

      view
      |> form("#agentic-form", %{
        "board" => %{"job_log_hours" => "6", "failure_log_hours" => "72"}
      })
      |> render_submit()

      board = Slipdock.Boards.get_board!(ctx.board.id)
      assert {board.job_log_hours, board.failure_log_hours} == {6, 72}
    end

    test "a sub-board follows its top board: shown read-only, linking to it", ctx do
      {:ok, t} = Slipdock.Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.card, t)
      {:ok, view, _} = live(ctx.conn, agentic_path(sub))
      refute has_element?(view, "#board-job-log-hours")
      assert has_element?(view, "#board-job-logs-read", "24 hours")
      assert has_element?(view, ~s(#board-job-logs a[href="/boards/#{ctx.board.id}/agentic"]))
    end
  end
end
