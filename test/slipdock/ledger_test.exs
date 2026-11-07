defmodule Slipdock.LedgerTest do
  @moduledoc """
  The ledger (#1948, `Slipdock.Ledger`): what shipped on a tree since a time,
  on hand-built fixtures. The default window and `since` in each form, each
  kind of event (completed, accepted, merged by job or by hand, deployed),
  the acceptor kinds and the audit's verdict, evidence, `should` rules,
  lead time, an epic's rollup, the day grouping, and that it writes nothing.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Ledger, Repo, Verified}
  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Deployments.Deployment
  alias Slipdock.Runners.Job

  @now ~U[2026-11-07 12:00:00Z]

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Ledger"}, owner: user)
    [_backlog, todo, _doing, done] = board.columns
    %{user: user, board: board, todo: todo, done: done}
  end

  defp at(hours_ago), do: DateTime.add(@now, -round(hours_ago * 3600), :second)

  defp usec(at), do: DateTime.add(at, 0, :microsecond)

  defp set!(card, fields) do
    Repo.update_all(from(c in Card, where: c.id == ^card.id), set: fields)
    Repo.get!(Card, card.id)
  end

  defp completed!(column, hours_ago, attrs \\ %{}) do
    column |> card_fixture(attrs) |> set!(completed: true, completed_at: at(hours_ago))
  end

  defp ledger!(board, opts \\ []) do
    {:ok, ledger} = Ledger.since(board, Keyword.merge([now: @now, timezone: "Etc/UTC"], opts))
    ledger
  end

  defp items(ledger), do: Enum.flat_map(ledger.days, & &1.items)
  defp ids(ledger), do: ledger |> items() |> Enum.map(& &1.card.id)
  defp item(ledger, card), do: Enum.find(items(ledger), &(&1.card.id == card.id))

  describe "the window" do
    test "defaults to 07:00 yesterday in the board's timezone" do
      assert Ledger.default_since(@now, "Etc/UTC") == ~U[2026-11-06 07:00:00Z]
      # 07:00 in New York in November is 12:00 UTC.
      assert Ledger.default_since(@now, "America/New_York") == ~U[2026-11-06 12:00:00Z]
      # Just after midnight local time, "yesterday" is still the day before.
      assert Ledger.default_since(~U[2026-11-07 00:30:00Z], "Etc/UTC") ==
               ~U[2026-11-06 07:00:00Z]
    end

    test "the default leaves out what finished before 07:00 yesterday", %{
      board: board,
      done: done
    } do
      inside = completed!(done, 28)
      outside = completed!(done, 30)

      ledger = ledger!(board)
      assert ledger.since == ~U[2026-11-06 07:00:00Z]
      assert ledger.until == @now
      assert inside.id in ids(ledger)
      refute outside.id in ids(ledger)
    end

    test "uses the board owner's timezone when none is given", %{user: user, board: board} do
      Repo.update_all(from(u in Slipdock.Accounts.User, where: u.id == ^user.id),
        set: [timezone: "America/New_York"]
      )

      {:ok, ledger} = Ledger.since(board, now: @now)
      assert ledger.timezone == "America/New_York"
      assert ledger.since == ~U[2026-11-06 12:00:00Z]
    end

    test "since takes days, a date, an ISO time or a DateTime", %{board: board, done: done} do
      card = completed!(done, 24 * 5)

      refute card.id in ids(ledger!(board, since: "3"))
      assert card.id in ids(ledger!(board, since: "7"))
      assert card.id in ids(ledger!(board, since: 7))
      assert ledger!(board, since: 7).since == ~U[2026-10-31 12:00:00Z]
      assert ledger!(board, since: "2026-11-01").since == ~U[2026-11-01 00:00:00Z]
      assert card.id in ids(ledger!(board, since: "2026-11-01"))
      refute card.id in ids(ledger!(board, since: "2026-11-03T00:00:00Z"))
      assert ledger!(board, since: ~U[2026-11-02 10:00:00Z]).since == ~U[2026-11-02 10:00:00Z]
      # A blank since is the default window.
      assert ledger!(board, since: "").since == ~U[2026-11-06 07:00:00Z]
    end

    test "refuses a since it can't read", %{board: board} do
      for bad <- ["yesterday", "-3", "2026-13-40", %{}] do
        assert {:error, message} = Ledger.since(board, now: @now, since: bad)
        assert message =~ "since is a date"
      end
    end

    test "an empty board has an empty ledger", %{board: board} do
      assert %{count: 0, days: []} = ledger!(board)
    end
  end

  describe "events" do
    test "a completion, an acceptance, a merge job and a deploy each put a card on it",
         %{board: board, todo: todo, done: done} do
      completed = completed!(done, 2)

      accepted =
        todo
        |> card_fixture()
        |> set!(
          verify_state: "merging",
          verify_at: at(3),
          verify_by: %{"kind" => "agent", "agent" => "verifier"}
        )

      merged = completed!(done, 30)

      Repo.insert!(%Job{
        card_id: merged.id,
        pool: "dev",
        kind: Verified.merge_kind(),
        prompt: "merge",
        status: "done",
        board_id: board.id,
        root_board_id: board.id,
        finished_at: at(4)
      })

      deployed = completed!(done, 40)

      Repo.insert!(%Deployment{
        board_id: board.id,
        environment: "production",
        sha: "abc1234",
        status: "succeeded",
        started_at: usec(at(5)),
        finished_at: usec(at(5)),
        card_ids: [deployed.id]
      })

      ledger = ledger!(board)
      assert ledger.count == 4
      assert item(ledger, completed).events == ["completed"]
      assert item(ledger, accepted).events == ["accepted"]
      assert item(ledger, merged).events == ["merged"]
      assert item(ledger, deployed).events == ["deployed"]

      assert item(ledger, deployed).deploys == [
               %{environment: "production", sha: "abc1234", at: at(5)}
             ]

      # Newest first.
      assert ids(ledger) == [completed.id, accepted.id, merged.id, deployed.id]
    end

    test "a card a person marked merged counts as merged at its completion",
         %{board: board, done: done} do
      card = done |> completed!(1) |> set!(merge_sha: "def5678")
      assert item(ledger!(board), card).events == ["completed", "merged"]
      assert item(ledger!(board), card).merge_sha == "def5678"
    end

    test "a failed deploy, a failed merge and a rejection don't count",
         %{board: board, todo: todo} do
      card = card_fixture(todo)
      set!(card, verify_state: "rejected", verify_at: at(1), verify_by: %{"kind" => "agent"})

      Repo.insert!(%Job{
        card_id: card.id,
        pool: "dev",
        kind: Verified.merge_kind(),
        prompt: "merge",
        status: "failed",
        board_id: board.id,
        root_board_id: board.id,
        finished_at: at(1)
      })

      Repo.insert!(%Deployment{
        board_id: board.id,
        environment: "production",
        sha: "abc1234",
        status: "failed",
        started_at: usec(at(1)),
        finished_at: usec(at(1)),
        card_ids: [card.id]
      })

      assert ledger!(board).count == 0
    end

    test "a card with several events is one line, at its latest", %{board: board, done: done} do
      card =
        done
        |> completed!(6)
        |> set!(
          verify_state: "accepted",
          verify_at: at(6),
          verify_by: %{"kind" => "human", "user_id" => nil}
        )

      Repo.insert!(%Deployment{
        board_id: board.id,
        environment: "production",
        sha: "abc1234",
        status: "succeeded",
        started_at: usec(at(1)),
        finished_at: usec(at(1)),
        card_ids: [card.id]
      })

      ledger = ledger!(board)
      assert ledger.count == 1
      assert %{events: ["completed", "accepted", "deployed"], at: at} = item(ledger, card)
      assert at == at(1)
    end

    test "stand-ins are left out", %{board: board, done: done} do
      real = completed!(done, 1)
      stand_in = done |> completed!(1) |> set!(stand_in_for_id: real.id)

      assert ids(ledger!(board)) == [real.id]
      refute stand_in.id in ids(ledger!(board))
    end
  end

  describe "a line" do
    test "names the acceptor: a person, an agent or a runner", %{
      board: board,
      user: user,
      done: done
    } do
      person =
        done
        |> completed!(1)
        |> set!(
          verify_state: "accepted",
          verify_at: at(1),
          verify_by: %{"kind" => "human", "user_id" => user.id, "via" => "web"}
        )

      agent =
        done
        |> completed!(2)
        |> set!(
          verify_state: "accepted",
          verify_at: at(2),
          verify_by: %{"kind" => "agent", "agent" => "verifier", "via" => "cli"}
        )

      runner =
        done
        |> completed!(3)
        |> set!(
          verify_state: "accepted",
          verify_at: at(3),
          verify_by: %{"kind" => "agent", "agent" => "Mac", "via" => "runner"}
        )

      unverified = completed!(done, 4)

      ledger = ledger!(board)

      assert item(ledger, person).accepted_by == %{
               kind: "person",
               name: Slipdock.Accounts.User.display_name(user)
             }

      assert item(ledger, agent).accepted_by == %{kind: "agent", name: "agent “verifier”"}
      assert item(ledger, runner).accepted_by == %{kind: "agent", name: "runner Mac"}
      assert item(ledger, unverified).accepted_by == nil
    end

    test "carries the last audit's verdict", %{board: board, done: done} do
      agreed = completed!(done, 1)
      disputed = completed!(done, 2)
      plain = completed!(done, 3)

      comment = fn card, body, hours ->
        Repo.insert!(%Comment{card_id: card.id, body: body, inserted_at: at(hours)})
      end

      comment.(agreed, "**Audit: agrees** with the acceptance, by runner X.", 1)
      comment.(disputed, "**Audit: agrees** with the acceptance, by runner X.", 2)
      comment.(disputed, "**Audit: disagrees** with the acceptance, by runner Y.", 1)

      ledger = ledger!(board)
      assert item(ledger, agreed).audit == %{verdict: "agrees", at: at(1)}
      assert item(ledger, disputed).audit.verdict == "disagrees"
      assert item(ledger, plain).audit == nil
    end

    test "carries the evidence's first line, the broken should rules and the PR",
         %{board: board, done: done} do
      card =
        done
        |> completed!(1)
        |> set!(
          evidence: "\n  Built the ledger; tests pass.\nSecond line",
          evidence_commit: "abc1234",
          evidence_pr: "https://github.com/example/repo/pull/7",
          verify_checks: %{
            "rules" => [
              %{
                "id" => "UX-4",
                "result" => "broken",
                "severity" => "should",
                "note" => "a toast"
              },
              %{"id" => "ARCH-1", "result" => "ok", "severity" => "must"},
              %{"id" => "UX-9", "result" => "broken", "severity" => "must"}
            ]
          }
        )

      line = item(ledger!(board), card)
      assert line.evidence == "Built the ledger; tests pass."
      assert line.evidence_commit == "abc1234"
      assert line.pr == "https://github.com/example/repo/pull/7"
      assert line.should_broken == [%{id: "UX-4", note: "a toast"}]
    end

    test "evidence is cut to 200 characters, and blank evidence is nil" do
      assert Ledger.first_line(String.duplicate("x", 300)) == String.duplicate("x", 200)
      assert Ledger.first_line("  \n \n") == nil
      assert Ledger.first_line(nil) == nil
      assert Ledger.should_broken(nil) == []
    end

    test "carries the lead time by phase, only phases with time in them",
         %{board: board, done: done} do
      card = completed!(done, 1)
      line = item(ledger!(board), card)

      assert line.lead_time.ends == :completed
      assert is_integer(line.lead_time.seconds)
      assert Enum.all?(line.lead_time.phases, fn {_phase, s} -> s > 0 end)
      assert Map.keys(line.lead_time.phases) -- Slipdock.LeadTime.phases() == []
    end
  end

  test "an epic's line rolls up its subcards, which have lines of their own",
       %{board: board, done: done} do
    epic = completed!(done, 1, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    [first | _] = sub.columns

    shipped = completed!(first, 2)
    _older = completed!(first, 24 * 10)
    _open = card_fixture(first)

    ledger = ledger!(board)
    assert item(ledger, epic).subcards == %{total: 3, done: 2, on_ledger: 1}
    assert item(ledger, shipped).subcards == nil
    assert item(ledger, shipped).card.board_id == sub.id
  end

  test "groups by day in the timezone, newest day first", %{board: board, done: done} do
    today = completed!(done, 1)
    yesterday = completed!(done, 14)

    ledger = ledger!(board, since: 2)

    assert [%{date: ~D[2026-11-07], items: [a]}, %{date: ~D[2026-11-06], items: [b]}] =
             ledger.days

    assert {a.card.id, b.card.id} == {today.id, yesterday.id}

    # 22:00 UTC on the 6th is 07:00 on the 7th in Tokyo.
    assert [%{date: ~D[2026-11-07], items: [_, _]}] =
             ledger!(board, since: 2, timezone: "Asia/Tokyo").days
  end

  test "reads only: nothing is written", %{board: board, done: done} do
    card = completed!(done, 1)
    before = Repo.get!(Card, card.id)
    counts = fn -> {Repo.aggregate(Card, :count), Repo.aggregate(Comment, :count)} end
    was = counts.()

    _ = ledger!(board)
    assert counts.() == was
    assert Repo.get!(Card, card.id).updated_at == before.updated_at
  end
end
