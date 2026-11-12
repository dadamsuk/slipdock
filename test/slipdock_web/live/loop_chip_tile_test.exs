defmodule SlipdockWeb.LoopChipTileTest do
  @moduledoc """
  The runner loop holding a card (#2027) on the board tile and the outline
  rows (#2030): a chip beside the assignee chips, linked to the job, while
  the job is claimed or running and the assignee field is on; gone when the
  job ends. Also `Slipdock.CardState.loops/1`, which the outline reads.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, CardState, Runners}
  alias Slipdock.Runners.Job

  setup %{conn: conn} do
    user = user_fixture()
    board = board_fixture(%{"name" => "Loop tiles"}, owner: user)
    [_backlog, _todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "Mac Studio", "pool" => "dev"})
    card = card_fixture(doing, %{"title" => "Held by a loop"})
    other = card_fixture(doing, %{"title" => "Nobody's loop"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    %Job{} = job = Runners.claim(runner)
    {:ok, :ok} = Runners.heartbeat(runner, job.id)

    %{
      conn: log_in_user(conn, user),
      user: user,
      board: board,
      runner: runner,
      card: card,
      other: other,
      job: job
    }
  end

  defp job_href(ctx, job \\ nil),
    do: "/boards/#{ctx.board.id}/cards/#{ctx.card.id}#card-job-#{(job || ctx.job).id}"

  # The job ends, and the page hears of it as it would from the runner.
  defp finish(view, ctx) do
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: 0})
    send(view.pid, {:jobs_changed, ctx.card.id})
    render(view)
  end

  # The page as the server sends it, without joining its LiveView: for the
  # tests that only read it. A join the channel refuses (this host's clock
  # stepping back under load, W-1950 §Tests, #2732) came back from `live/2` as
  # a redirect to the board itself (#2870).
  defp page(conn, path), do: conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

  defp page_showing(ctx, path, keys) do
    Slipdock.CardViewHelpers.show_on_cards(ctx.user, ctx.board, keys)
    page(ctx.conn, path)
  end

  # `has_element?/3` on that page: an element matching `selector`, and with
  # `text`, one whose text contains it.
  defp on_page?(page, selector, text \\ nil) do
    page
    |> LazyHTML.query(selector)
    |> Enum.any?(&(is_nil(text) or LazyHTML.text(&1) =~ text))
  end

  describe "the board tile" do
    test "shows the loop beside the assignees, linked to the job, until the job ends", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(
               view,
               "#card-#{ctx.card.id}-loop[href='#{job_href(ctx)}']",
               "Mac Studio · build"
             )

      refute has_element?(view, "#card-#{ctx.other.id}-loop")
      refute has_element?(view, "#card-#{ctx.other.id} [data-loop-job]")

      finish(view, ctx)
      refute has_element?(view, "#card-#{ctx.card.id}-loop")
    end

    test "sits beside a person assignee in the card's meta row", ctx do
      {:ok, _} = Boards.Cards.update_card(ctx.card, %{"assignee_ids" => [ctx.user.id]})
      page = page(ctx.conn, ~p"/boards/#{ctx.board}")

      assert on_page?(
               page,
               "#card-#{ctx.card.id} [data-role=card-meta] #card-#{ctx.card.id}-loop"
             )

      assert page
             |> LazyHTML.query("#card-#{ctx.card.id} [data-role=card-meta]")
             |> LazyHTML.to_html() =~ "hero-cpu-chip"
    end

    test "shows on the compact face too, and says verify for a verify job", ctx do
      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: 0})
      {:ok, _} = Runners.queue(ctx.card, %{pool: "dev", kind: "verify", prompt: "check"})
      %Job{kind: "verify"} = verify = Runners.claim(ctx.runner)

      page = page_showing(ctx, ~p"/boards/#{ctx.board}?#{[density: "compact"]}", ~w(assignee))

      assert on_page?(
               page,
               "#card-#{ctx.card.id}-loop[href='#{job_href(ctx, verify)}']",
               "Mac Studio · verify"
             )

      # The finished build job's chip is not left beside it.
      refute on_page?(page, "#card-#{ctx.card.id}-loop", "Mac Studio · build")
    end

    test "is left off with the assignee field", ctx do
      page = page_showing(ctx, ~p"/boards/#{ctx.board}", ~w(tags status))

      assert on_page?(page, "#card-#{ctx.card.id}")
      refute on_page?(page, "#card-#{ctx.card.id}-loop")

      page = page_showing(ctx, ~p"/boards/#{ctx.board}?#{[density: "compact"]}", ~w(tags))

      assert on_page?(page, "#card-#{ctx.card.id}")
      refute on_page?(page, "#card-#{ctx.card.id}-loop")
    end

    test "a queued job is not a loop yet", ctx do
      {:ok, _} = Runners.queue(ctx.other, %{pool: "dev", kind: "claude", prompt: "later"})
      page = page(ctx.conn, ~p"/boards/#{ctx.board}")

      # The tile is on the page, and so is the claimed job's chip beside it.
      assert on_page?(page, "#card-#{ctx.other.id}")
      assert on_page?(page, "#card-#{ctx.card.id}-loop")
      refute on_page?(page, "#card-#{ctx.other.id}-loop")
    end
  end

  describe "the outline" do
    test "a row shows the loop beside the assignees, linked to the job, until it ends", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/outline")

      assert has_element?(
               view,
               "#ol-#{ctx.card.id} #ol-loop-#{ctx.card.id}[href='#{job_href(ctx)}']",
               "Mac Studio · build"
             )

      assert has_element?(view, "#ol-#{ctx.other.id}")
      refute has_element?(view, "#ol-loop-#{ctx.other.id}")

      finish(view, ctx)
      assert has_element?(view, "#ol-#{ctx.card.id}")
      refute has_element?(view, "#ol-loop-#{ctx.card.id}")
    end

    test "a subcard on a sub-board shows its loop too", ctx do
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(ctx.other, t, code: unique_code())
      sub = Boards.get_board!(sub.id)

      kid = card_fixture(hd(sub.columns), %{"title" => "Subcard in a loop"})
      {:ok, queued} = Runners.queue(kid, %{pool: "sub", kind: "merge", prompt: "merge it"})

      # Claimed by a second runner; set on the row, which is all the chip reads.
      kid_job =
        queued
        |> Ecto.Changeset.change(status: "claimed", runner_name: "Big White")
        |> Slipdock.Repo.update!()

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/outline")

      assert has_element?(
               view,
               "#ol-loop-#{kid.id}[href='/boards/#{sub.id}/cards/#{kid.id}#card-job-#{kid_job.id}']",
               "Big White · merge"
             )

      # Collapsed beneath its parent, it is neither drawn nor asked after.
      view
      |> element("#ol-#{ctx.other.id} button[phx-value-key='card-#{ctx.other.id}']")
      |> render_click()

      refute has_element?(view, "#ol-loop-#{kid.id}")
      assert has_element?(view, "#ol-loop-#{ctx.card.id}")
    end

    test "is left off with the assignee field", ctx do
      page = page_showing(ctx, ~p"/boards/#{ctx.board}/outline", ~w(tags priority))

      assert on_page?(page, "#ol-#{ctx.card.id}")
      refute on_page?(page, "#ol-loop-#{ctx.card.id}")
    end
  end

  describe "CardState.loops/1" do
    test "maps only the cards a claimed or running job holds", ctx do
      assert CardState.loops([]) == %{}

      assert CardState.loops([ctx.card.id, ctx.other.id]) == %{
               ctx.card.id => %{runner: "Mac Studio", kind: "build", job_id: ctx.job.id}
             }

      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: 0})
      assert CardState.loops([ctx.card.id, ctx.other.id]) == %{}
    end
  end
end
