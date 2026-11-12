defmodule Slipdock.NotShippedTest do
  @moduledoc """
  Merged, not shipped (#2819): `Slipdock.Deployments.NotShipped` finds the
  merged cards no succeeded deploy names after the board's minutes, the
  watch check raises one warning alert a card and clears it when a deploy
  covers the card, and the scheduler's tick runs it on a board with
  delivery metrics on whether or not its overseer is.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Boards, Deployments, Overseer, Repo}
  alias Slipdock.Automations.Alert
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Deployments.NotShipped
  alias Slipdock.Overseer.{Condition, Settings, Watch}

  @now ~U[2026-11-11 21:01:00Z]
  @since ~U[2026-11-11 12:00:00Z]
  @sha "1a634c6aa0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5"

  setup do
    owner = user_fixture("not-shipped-owner@example.com")
    board = board_fixture(%{"name" => "Delivering", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})

    Repo.update_all(from(b in Board, where: b.id == ^board.id),
      set: [delivery_metrics_since: @since]
    )

    [_backlog, _todo, _doing, done] = board.columns
    %{owner: owner, board: Repo.get!(Board, board.id), done: done}
  end

  # A card accepted and merged as `sha`, `minutes` before @now.
  defp merged(list, minutes, attrs \\ []) do
    card = card_fixture(list, %{"title" => Keyword.get(attrs, :title, "Merged")})

    set =
      Keyword.merge(
        [
          completed: true,
          completed_at: DateTime.add(@now, -minutes * 60),
          verify_state: "accepted",
          merge_sha: @sha
        ],
        Keyword.delete(attrs, :title)
      )

    Repo.update_all(from(c in Card, where: c.id == ^card.id), set: set)
    Repo.get!(Card, card.id)
  end

  defp deploy!(board, card, attrs \\ %{}) do
    sha = :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)

    {:ok, d} =
      Deployments.start(
        board,
        Map.merge(
          %{
            environment: "production",
            sha: sha,
            status: "succeeded",
            started_at: @now,
            finished_at: @now,
            commits: [%{"sha" => sha, "subject" => "feat ##{card.id}"}]
          },
          attrs
        )
      )

    d
  end

  defp sub_board!(card) do
    {:ok, template} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(card, template)
    Boards.get_board!(sub.id)
  end

  defp tree(board), do: NotShipped.in_tree(board, [board.id], @now)
  defp fresh(board), do: Repo.get!(Board, board.id)

  defp conditions(board),
    do: board.id |> Watch.open_conditions() |> Enum.filter(&(&1.check == "not_shipped"))

  describe "which cards" do
    test "a card merged longer ago than the board's minutes, with no deploy", ctx do
      card = merged(ctx.done, 45)

      assert [line] = tree(ctx.board)
      assert line.card_id == card.id
      assert line.sha == @sha
      assert line.seconds == 45 * 60
      assert line.minutes == 20

      assert %{text: "Merged 1a634c6 · not shipped after 45m", sha: @sha, seconds: 2700} =
               NotShipped.for_card(card, @now)
    end

    test "not inside the board's minutes, and the setting moves the line", ctx do
      card = merged(ctx.done, 19)
      assert tree(ctx.board) == []
      assert NotShipped.for_card(card, @now) == nil

      # Exactly N minutes is late.
      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [completed_at: DateTime.add(@now, -20 * 60)]
      )

      assert [_] = tree(ctx.board)

      {:ok, board} = Boards.update_board(ctx.board, %{"not_shipped_minutes" => 60})
      assert tree(board) == []
      {:ok, board} = Boards.update_board(board, %{"not_shipped_minutes" => 5})
      assert [%{minutes: 5}] = tree(board)
    end

    test "0 minutes turns it off, and the setting keeps to 0..10080", ctx do
      card = merged(ctx.done, 45)
      {:ok, board} = Boards.update_board(ctx.board, %{"not_shipped_minutes" => 0})
      assert tree(board) == []
      assert NotShipped.for_card(card, @now) == nil

      assert {:error, changeset} = Boards.update_board(board, %{"not_shipped_minutes" => -1})
      assert %{not_shipped_minutes: [_]} = errors_on(changeset)
      assert {:error, _} = Boards.update_board(board, %{"not_shipped_minutes" => 10_081})
      assert {:ok, _} = Boards.update_board(board, %{"not_shipped_minutes" => 10_080})
    end

    test "a succeeded deploy naming the card covers it; a failed or started one doesn't", ctx do
      card = merged(ctx.done, 45)

      deploy!(ctx.board, card, %{status: "failed"})
      deploy!(ctx.board, card, %{status: "started", finished_at: nil})
      assert [_] = tree(ctx.board)

      # A deploy that names another card covers nothing of this one.
      other = card_fixture(ctx.done, %{"title" => "Other"})
      deploy!(ctx.board, other)
      assert [_] = tree(ctx.board)

      deploy!(ctx.board, card)
      assert tree(ctx.board) == []
      assert NotShipped.for_card(card, @now) == nil
    end

    test "a card merged before delivery metrics were on never counts", ctx do
      # Merged an hour before the board started recording deploys.
      merged(ctx.done, 45, completed_at: DateTime.add(@since, -3600))
      # And one merged at that very second: only later ones count.
      merged(ctx.done, 45, completed_at: @since)
      assert tree(ctx.board) == []

      late = merged(ctx.done, 45, completed_at: DateTime.add(@since, 1))
      assert [%{card_id: id}] = tree(ctx.board)
      assert id == late.id
    end

    test "turning delivery metrics on starts the count; off forgets it; a save between keeps it",
         ctx do
      card = merged(ctx.done, 45)
      {:ok, off} = Boards.update_board(ctx.board, %{"delivery_metrics" => false})
      assert off.delivery_metrics_since == nil
      assert tree(off) == []
      assert NotShipped.for_card(card, @now) == nil

      {:ok, on} = Boards.update_board(off, %{"delivery_metrics" => true})
      assert DateTime.diff(DateTime.utc_now(), on.delivery_metrics_since) in 0..5
      # The card merged before it was turned back on: it stays quiet.
      assert NotShipped.in_tree(on, [on.id], DateTime.add(DateTime.utc_now(), 3600)) == []

      # Saving the settings again with the switch still on moves nothing.
      Repo.update_all(from(b in Board, where: b.id == ^on.id),
        set: [delivery_metrics_since: @since]
      )

      {:ok, saved} = Boards.update_board(fresh(on), %{"delivery_metrics" => true, "name" => "X"})
      assert saved.delivery_metrics_since == @since
    end

    test "metrics on with nothing to count from is never watched", ctx do
      merged(ctx.done, 45)

      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [delivery_metrics_since: nil]
      )

      assert tree(fresh(ctx.board)) == []
    end

    test "what counts as merged", ctx do
      # Done, never accepted: no verified merge.
      merged(ctx.done, 45, verify_state: nil)
      # Accepted, still open.
      merged(ctx.done, 45, completed: false)
      # Accepted with no commit at all (a no-code card).
      merged(ctx.done, 45, merge_sha: nil)
      # Archived: the way out for a card that will never ship.
      merged(ctx.done, 45, archived_at: @now)
      # A stand-in marks where a card went into a sprint: the card ships, not it.
      real = card_fixture(ctx.done, %{"title" => "Real"})
      merged(ctx.done, 45, stand_in_for_id: real.id)
      assert tree(ctx.board) == []

      # Ship by push: the commit it was accepted at.
      pushed = merged(ctx.done, 45, merge_sha: nil, verify_commit: "abcdef1234567890")
      assert [%{card_id: id, sha: "abcdef1234567890"}] = tree(ctx.board)
      assert id == pushed.id
      assert NotShipped.for_card(pushed, @now).text == "Merged abcdef1 · not shipped after 45m"

      # The same card on a board that ships by pull request has not merged.
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [ship_via: "pull_request", verify_work: true]
      )

      assert tree(fresh(ctx.board)) == []
      assert NotShipped.for_card(pushed, @now) == nil
    end

    test "ship by push: an acceptance that gave only evidence counts its evidence commit", ctx do
      card =
        merged(ctx.done, 45, merge_sha: nil, verify_commit: nil, evidence_commit: "0f690f1f99")

      assert [%{card_id: id, sha: "0f690f1f99"}] = tree(ctx.board)
      assert id == card.id
      assert NotShipped.for_card(card, @now).text == "Merged 0f690f1 · not shipped after 45m"
    end

    test "a board set to pull requests that doesn't verify work ships by push", ctx do
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [ship_via: "pull_request", verify_work: false]
      )

      card = merged(ctx.done, 45, merge_sha: nil, verify_commit: "abcdef1234567890")
      assert [%{card_id: id, sha: "abcdef1234567890"}] = tree(fresh(ctx.board))
      assert id == card.id
      assert NotShipped.for_card(card, @now).text == "Merged abcdef1 · not shipped after 45m"
    end

    test "a deploy on a tree board whose delivery metrics are off since covers nothing", ctx do
      epic = card_fixture(ctx.done, %{"title" => "Epic"})
      sub = sub_board!(epic)
      {:ok, sub} = Boards.update_board(sub, %{"delivery_metrics" => true})
      card = merged(ctx.done, 45)

      deploy!(sub, card)
      assert [_] = Deployments.shipped(card)
      assert tree(ctx.board) == []

      Repo.update_all(from(b in Board, where: b.id == ^sub.id), set: [delivery_metrics: false])

      assert Deployments.shipped(card) == []
      assert [%{card_id: id}] = tree(ctx.board)
      assert id == card.id
      assert %{text: "Merged 1a634c6 · not shipped after 45m"} = NotShipped.for_card(card, @now)
    end

    test "an epic ships through its subcards, and a subcard counts on the root's tree", ctx do
      epic = merged(ctx.done, 45, title: "Epic")
      sub = sub_board!(epic)
      child = merged(hd(sub.columns), 30, title: "Child")

      assert [%{card_id: id}] = NotShipped.in_tree(ctx.board, [ctx.board.id, sub.id], @now)
      assert id == child.id
      assert NotShipped.for_card(epic, @now) == nil
      assert %{text: "Merged 1a634c6 · not shipped after 30m"} = NotShipped.for_card(child, @now)
    end

    test "a tree with delivery metrics off everywhere is not watched", ctx do
      plain = board_fixture(%{"name" => "Plain", "code" => unique_code()}, owner: ctx.owner)
      card = merged(List.last(plain.columns), 45)
      plain = fresh(plain)

      assert NotShipped.delivery_board(plain, [plain.id]) == nil
      assert NotShipped.in_tree(plain, [plain.id], @now) == []
      assert NotShipped.for_card(card, @now) == nil
    end
  end

  describe "the watch" do
    test "fires once: a condition, one warning alert on the root and an email; a covering deploy clears both",
         ctx do
      card = merged(ctx.done, 45, title: "Went nowhere")
      settings = Overseer.settings(ctx.board)

      result = Watch.run(ctx.board, settings, @now, checks: Watch.always())
      assert [fired] = result.fired
      assert fired.check == "not_shipped"
      assert fired.subject == "card:#{card.id}"
      assert fired.card_id == card.id
      assert fired.severity == "warning"
      assert fired.title == "##{card.id} “Went nowhere” merged, not shipped"
      assert fired.why =~ "Merged as 1a634c6 at 11 Nov 20:16 UTC"
      assert fired.why =~ "20m later no succeeded deploy names it"
      assert fired.todo =~ "run the deploy again"

      alert = Repo.get!(Alert, fired.alert_id)
      assert alert.board_id == ctx.board.id
      assert alert.card_id == card.id
      assert alert.severity == "warning"
      assert alert.title =~ "merged, not shipped"
      assert_email_sent(fn email -> assert email.subject =~ "merged, not shipped" end)

      # Seen again a minute later: nothing new, and the words hold still.
      again = Watch.run(ctx.board, settings, DateTime.add(@now, 60), checks: Watch.always())
      assert again.fired == []
      assert [kept] = again.open
      assert kept.id == fired.id
      assert Repo.aggregate(from(a in Alert, where: a.board_id == ^ctx.board.id), :count) == 1
      refute_email_sent()

      deploy!(ctx.board, card)
      cleared = Watch.run(ctx.board, settings, DateTime.add(@now, 120), checks: Watch.always())
      assert [%{id: id}] = cleared.cleared
      assert id == fired.id
      assert conditions(ctx.board) == []
      refute Repo.get(Alert, alert.id)
      assert Repo.get!(Condition, fired.id).cleared_at
    end

    test "inside the board's minutes nothing fires", ctx do
      merged(ctx.done, 10)
      result = Watch.run(ctx.board, Overseer.settings(ctx.board), @now, checks: Watch.always())
      assert result.fired == []
      assert Repo.aggregate(from(a in Alert, where: a.board_id == ^ctx.board.id), :count) == 0
    end

    test "run alone, it leaves the other checks' conditions and watched_at as they were", ctx do
      {:ok, settings} = Overseer.put_settings(ctx.board, %{"enabled" => false})

      {1, _} =
        Repo.insert_all(Condition, [
          %{
            board_id: ctx.board.id,
            check: "slow",
            subject: "card:1",
            severity: "warning",
            title: "Slow",
            why: "w",
            todo: "t",
            opened_at: @now,
            inserted_at: @now,
            updated_at: @now
          }
        ])

      result = Watch.run(ctx.board, settings, @now, checks: Watch.always())
      assert result.cleared == []
      assert [%{check: "slow"}] = Watch.open_conditions(ctx.board.id)
      assert Repo.get!(Settings, settings.id).watched_at == nil

      # A full run is the overseer's: it clears what it no longer finds.
      full = Watch.run(ctx.board, settings, @now)
      assert [%{check: "slow"}] = full.cleared
      assert Repo.get!(Settings, settings.id).watched_at == @now
    end

    test "a full run with settings never saved fires too, and stamps nothing", ctx do
      card = merged(ctx.done, 45)
      refute Repo.get_by(Settings, board_id: ctx.board.id)

      result = Watch.run(ctx.board, Overseer.settings(ctx.board), @now)
      assert [%{check: "not_shipped", card_id: id}] = result.fired
      assert id == card.id
      refute Repo.get_by(Settings, board_id: ctx.board.id)
    end

    test "it is one of the overseer's checks, and the only one that always runs" do
      assert "not_shipped" in Watch.check_keys()
      assert Watch.always() == [Slipdock.Overseer.Checks.NotShipped]
      assert Slipdock.Overseer.Checks.NotShipped.label() == "Merged, not shipped"
    end
  end

  describe "the scheduler's tick" do
    test "the scheduler runs the overseer's tick each minute" do
      assert {"Overseer", fun} =
               List.keyfind(Slipdock.Automations.Scheduler.jobs(), "Overseer", 0)

      assert fun == (&Slipdock.Overseer.tick/0)
    end

    test "fires with the overseer off, and with no overseer settings at all", ctx do
      card = merged(ctx.done, 45)
      refute Repo.get_by(Settings, board_id: ctx.board.id)

      Overseer.tick(@now)
      assert [%{card_id: id, alert_id: alert_id}] = conditions(ctx.board)
      assert id == card.id
      assert Repo.get!(Alert, alert_id).severity == "warning"

      # Off, with a settings row: still watched, and still once.
      {:ok, _} = Overseer.put_settings(ctx.board, %{"enabled" => false})
      Overseer.tick(DateTime.add(@now, 60))
      assert [_] = conditions(ctx.board)
      assert Repo.aggregate(from(a in Alert, where: a.board_id == ^ctx.board.id), :count) == 1

      deploy!(ctx.board, card)
      Overseer.tick(DateTime.add(@now, 120))
      assert conditions(ctx.board) == []
      refute Repo.get(Alert, alert_id)
    end

    test "with the overseer on it fires once, from the full watch", ctx do
      {:ok, settings} = Overseer.put_settings(ctx.board, %{"enabled" => true})

      Repo.update_all(from(s in Settings, where: s.id == ^settings.id),
        set: [next_run_at: DateTime.add(DateTime.utc_now(), 86_400)]
      )

      card = merged(ctx.done, 45)
      Overseer.tick(@now)
      assert [%{card_id: id}] = conditions(ctx.board)
      assert id == card.id
      assert Repo.aggregate(from(a in Alert, where: a.card_id == ^card.id), :count) == 1
      assert Repo.get!(Settings, settings.id).watched_at == @now
    end

    test "a subcard's condition and alert go to the root board", ctx do
      epic = card_fixture(ctx.done, %{"title" => "Epic"})
      sub = sub_board!(epic)
      child = merged(hd(sub.columns), 30)

      Overseer.tick(@now)
      assert [%{card_id: id, board_id: board_id, alert_id: alert_id}] = conditions(ctx.board)
      assert id == child.id
      assert board_id == ctx.board.id
      assert Repo.get!(Alert, alert_id).board_id == ctx.board.id
    end

    test "with the overseer off it runs this check alone: other conditions stay, watched_at unset",
         ctx do
      {:ok, settings} = Overseer.put_settings(ctx.board, %{"enabled" => false})

      # Another check's condition, which a full watch would clear (card:1 is nothing).
      {1, _} =
        Repo.insert_all(Condition, [
          %{
            board_id: ctx.board.id,
            check: "slow",
            subject: "card:1",
            severity: "warning",
            title: "Slow",
            why: "w",
            todo: "t",
            opened_at: @now,
            inserted_at: @now,
            updated_at: @now
          }
        ])

      card = merged(ctx.done, 45)
      Overseer.tick(@now)

      open = Watch.open_conditions(ctx.board.id)
      assert open |> Enum.map(& &1.check) |> Enum.sort() == ["not_shipped", "slow"]
      assert [%{card_id: id}] = conditions(ctx.board)
      assert id == card.id
      assert Repo.get!(Settings, settings.id).watched_at == nil
    end

    test "an archived root whose sub-board has delivery metrics on is left alone", ctx do
      {:ok, root} = Boards.update_board(ctx.board, %{"delivery_metrics" => false})
      epic = card_fixture(ctx.done, %{"title" => "Epic"})
      sub = sub_board!(epic)
      {:ok, sub} = Boards.update_board(sub, %{"delivery_metrics" => true})

      Repo.update_all(from(b in Board, where: b.id == ^sub.id),
        set: [delivery_metrics_since: @since]
      )

      child = merged(hd(sub.columns), 45)
      # Live, the tree would fire for it.
      assert [%{card_id: id}] = NotShipped.in_tree(fresh(root), [root.id, sub.id], @now)
      assert id == child.id

      Repo.update_all(from(b in Board, where: b.id == ^root.id), set: [archived_at: @now])
      Overseer.tick(@now)

      assert conditions(root) == []
      assert Repo.aggregate(from(a in Alert, where: a.card_id == ^child.id), :count) == 0
    end

    test "a board with delivery metrics off, or archived, is left alone", ctx do
      plain = board_fixture(%{"name" => "Plain", "code" => unique_code()}, owner: ctx.owner)
      merged(List.last(plain.columns), 45)

      merged(ctx.done, 45)
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id), set: [archived_at: @now])

      Overseer.tick(@now)
      assert conditions(plain) == []
      assert conditions(ctx.board) == []

      assert Repo.aggregate(
               from(a in Alert, where: a.board_id in ^[plain.id, ctx.board.id]),
               :count
             ) == 0
    end
  end
end
