defmodule SlipdockWeb.CardGlanceLiveTest do
  @moduledoc """
  The block under a card's title (#2022): the status row (health, the
  latest step, when, who), then the next step on an open card or the
  outcome on a finished one, the shipped lines with their time, then the
  note, folded past a few lines, with the byline last. A finished card
  shows no "next:" and folds the handoff written before it finished away;
  reopening brings the handoff back. The runner's transcript and exit
  lines aren't prose.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Deployments, Repo, StepStatus, Timezones}
  alias Slipdock.Boards.{Card, Handoff}

  @done_at ~U[2026-11-06 14:32:00Z]
  @shipped_at ~U[2026-11-06 15:10:00.000000Z]

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    card = card_fixture(hd(board.columns), %{"title" => "Half done"})
    %{board: board, card: card, owner: owner}
  end

  defp open(conn, ctx), do: live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

  defp leave(ctx, next, body, at \\ nil, job_id \\ nil) do
    {:ok, h} =
      Boards.Handoffs.leave_handoff(ctx.card, nil, %{
        next_step: next,
        body: body,
        via: "runner",
        job_id: job_id
      })

    if at, do: Repo.update_all(from(x in Handoff, where: x.id == ^h.id), set: [inserted_at: at])
    h
  end

  defp finish!(ctx) do
    Repo.update_all(from(c in Card, where: c.id == ^ctx.card.id),
      set: [
        completed: true,
        completed_at: @done_at,
        verify_state: "accepted",
        verify_by: %{"kind" => "agent", "via" => "runner", "agent" => "verifier"},
        evidence_pr: "https://github.com/acme/app/pull/215",
        merge_sha: "def5678aa"
      ]
    )
  end

  defp ship!(ctx) do
    sha = "b7de6ef" <> String.duplicate("0", 33)

    {:ok, _} =
      Deployments.start(ctx.board, %{
        "environment" => "production",
        "sha" => sha,
        "status" => "succeeded",
        "started_at" => @shipped_at,
        "finished_at" => @shipped_at,
        "commits" => [%{"sha" => sha, "subject" => "feat ##{ctx.card.id}"}]
      })
  end

  defp at(html, id) do
    {pos, _} = :binary.match(html, ~s(id="#{id}"))
    pos
  end

  defp zone(ctx), do: Timezones.of(ctx.owner)

  test "an open card: status row, next step, shipped line, note, byline, in that order", ctx do
    ship!(ctx)
    StepStatus.post(Repo.get!(Card, ctx.card.id), "Verifying")
    leave(ctx, "Accepting the card will merge it", "- Built the panel\n- Tests pass")

    {:ok, view, html} = open(ctx.conn, ctx)

    assert has_element?(view, "#glance-status", "On track")
    assert has_element?(view, "#glance-step", "Verifying")
    assert has_element?(view, "#glance-step-by", "Slipdock")
    assert has_element?(view, "#handoff-label", "next:")
    assert has_element?(view, "#handoff-next", "Accepting the card will merge it")
    refute has_element?(view, "#card-outcome")
    refute has_element?(view, "#handoff-before-finish")

    shipped = Deployments.time_text(@shipped_at, zone(ctx))
    assert has_element?(view, "#card-shipped", "Shipped to production · b7de6ef · #{shipped}")
    assert shipped =~ ~r/^\d+ Nov \d\d:\d\d$/

    assert at(html, "glance-status") < at(html, "handoff-line")
    assert at(html, "handoff-line") < at(html, "card-shipped")
    assert at(html, "card-shipped") < at(html, "handoff-body")
    assert at(html, "handoff-body") < at(html, "handoff-byline")
  end

  test "a finished card: an outcome and no next step; the old note is folded away", ctx do
    leave(ctx, "Accepting the card will merge it", "Built it.", ~U[2026-11-06 12:00:00Z])
    finish!(ctx)
    StepStatus.post(Repo.get!(Card, ctx.card.id), "Merged")

    {:ok, view, html} = open(ctx.conn, ctx)

    refute html =~ "— next:"
    refute has_element?(view, "#handoff-next")
    done = Deployments.time_text(@done_at, zone(ctx))

    assert has_element?(
             view,
             "#card-outcome",
             "Done #{done} · accepted by runner verifier · merged PR #215 (def5678)"
           )

    assert has_element?(view, "#glance-step", "Merged")

    # The deploy posts its own step, which is then the latest.
    ship!(ctx)
    {:ok, view, html} = open(ctx.conn, ctx)
    assert has_element?(view, "#glance-step", "Shipped to production")
    assert has_element?(view, "#card-shipped", "Shipped to production")

    assert has_element?(
             view,
             "#handoff-before-finish summary",
             "Last note before it finished · a runner"
           )

    assert has_element?(view, "#handoff-before-finish", "Accepting the card will merge it")
    assert at(html, "card-outcome") < at(html, "card-shipped")
    assert at(html, "card-shipped") < at(html, "handoff-before-finish")
  end

  test "a note left after it finished is what is still to do", ctx do
    finish!(ctx)

    {:ok, _} =
      Boards.Handoffs.leave_handoff(ctx.card, ctx.owner, %{
        next_step: "Reinstall the CLI",
        via: "ui"
      })

    {:ok, view, _} = open(ctx.conn, ctx)
    assert has_element?(view, "#card-outcome", "Done")
    assert has_element?(view, "#handoff-label", "still to do:")
    assert has_element?(view, "#handoff-next", "Reinstall the CLI")
    refute has_element?(view, "#handoff-before-finish")
  end

  test "reopening brings the handoff panel back", ctx do
    leave(ctx, "Accepting the card will merge it", nil, ~U[2026-11-06 12:00:00Z])
    finish!(ctx)
    StepStatus.post(Repo.get!(Card, ctx.card.id), "Merged")

    {:ok, _} =
      Boards.Cards.update_card(Repo.get!(Card, ctx.card.id), %{"completed" => false},
        actor: Actor.web(ctx.owner)
      )

    {:ok, view, _} = open(ctx.conn, ctx)
    refute has_element?(view, "#card-outcome")
    refute has_element?(view, "#handoff-before-finish")
    assert has_element?(view, "#handoff-label", "next:")
    assert has_element?(view, "#handoff-next", "Accepting the card will merge it")
    assert has_element?(view, "#glance-step", "Reopened")
  end

  test "the runner's transcript and exit lines are not prose, and a long note folds", ctx do
    body =
      Enum.map_join(1..6, "\n", &"- point #{&1}") <>
        "\n\nslipdock-runner: sending the transcript /tmp/x.jsonl as the job's live log\n\n" <>
        "Job #747 on verifier ended done (exit 0)."

    {:ok, job} = Slipdock.Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "x"})
    leave(ctx, "Carry on", body, nil, job.id)
    {:ok, view, _} = open(ctx.conn, ctx)

    body_html = view |> element("#handoff-body") |> render()
    assert body_html =~ "point 6"
    refute body_html =~ "sending the transcript"
    refute body_html =~ "ended done"
    assert has_element?(view, "#handoff-byline", "job ##{job.id}")
    assert has_element?(view, "#handoff-more-toggle", "Show more")
    assert body_html =~ "max-h-"
  end

  test "a short note doesn't fold", ctx do
    leave(ctx, "Carry on", "One line.")
    {:ok, view, _} = open(ctx.conn, ctx)
    refute has_element?(view, "#handoff-more-toggle")
  end

  test "a person's status names them", ctx do
    {:ok, _} =
      Boards.StatusUpdates.add_status_update(ctx.card, ctx.owner, %{
        "health" => "at_risk",
        "body" => "Slow"
      })

    {:ok, view, _} = open(ctx.conn, ctx)
    assert has_element?(view, "#glance-status", "At risk")
    assert has_element?(view, "#glance-step", "Slow")
    refute has_element?(view, "#glance-step-by", "Slipdock")
  end
end
