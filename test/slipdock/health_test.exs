defmodule Slipdock.HealthTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Automations, Boards, Health, Repo}
  alias Slipdock.Automations.Alert
  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Health.{Incident, Pulse, Settings}

  # A detector the test drives: it finds what the process says it finds, and
  # its fix answers what the process says.
  defmodule Probe do
    @behaviour Slipdock.Health.Detector
    def key, do: "probe"
    def label, do: "Probe"
    def defaults, do: %{"minutes" => 15}

    def detect(_ctx, settings),
      do: Process.get(:probe_findings, []) |> tap(fn _ -> send(self(), {:settings, settings}) end)

    def resolve(incident, attempt) do
      send(self(), {:resolve, incident.id, attempt})
      Process.get(:probe_fix, :no_fix)
    end
  end

  # One with no fix at all.
  defmodule Watcher do
    @behaviour Slipdock.Health.Detector
    def key, do: "watcher"
    def label, do: "Watcher"
    def defaults, do: %{}
    def detect(_ctx, _settings), do: Process.get(:watcher_findings, [])
  end

  setup do
    owner = user_fixture()
    board = Boards.get_board!(board_fixture(%{"name" => "Health"}, owner: owner).id)
    [_backlog, doing, _review, _done] = board.columns
    card = card_fixture(doing, %{"title" => "Held up"})
    %{owner: owner, board: board, card: card}
  end

  defp finding(card, state \\ 1) do
    %{
      subject: %{"card" => card && card.id},
      card_id: card && card.id,
      state: state,
      summary: "it is held up",
      data: %{"why" => "test"}
    }
  end

  defp run(board), do: Health.run(board, detectors: [Probe, Watcher])

  defp incidents(board),
    do: Repo.all(from(i in Incident, where: i.board_id == ^board.id, order_by: i.id))

  defp card!(card), do: Repo.get!(Card, card.id)

  defp comments(card) do
    Repo.all(from(c in Comment, where: c.card_id == ^card.id, order_by: c.id, select: c.body))
  end

  describe "fix, try, flag" do
    test "a fix that works marks the incident fixed, with a comment and no flag", %{
      board: board,
      card: card
    } do
      Process.put(:probe_findings, [finding(card)])
      Process.put(:probe_fix, {:fixed, "requeued the job"})

      assert {:ok, %{"opened" => 1, "fixed" => 1, "flagged" => 0}} = run(board)
      assert [%Incident{status: "fixed", attempts: 1} = i] = incidents(board)
      assert_received {:resolve, id, 1} when id == i.id
      assert Enum.map(i.log, & &1["what"]) == ["Found: it is held up", "Fixed: requeued the job"]
      assert [comment] = comments(card)
      assert comment =~ "Fixed: requeued the job"
      refute "stuck" in card!(card).flags
    end

    test "a fix that is only tried is tried up to max_attempts, then flagged", %{
      board: board,
      card: card
    } do
      Process.put(:probe_findings, [finding(card)])
      Process.put(:probe_fix, {:tried, "ran the feed"})

      assert {:ok, %{"tried" => 1}} = run(board)
      assert [%Incident{status: "open", attempts: 1}] = incidents(board)
      assert {:ok, %{"tried" => 1, "opened" => 0}} = run(board)
      assert [%Incident{status: "open", attempts: 2}] = incidents(board)
      refute "stuck" in card!(card).flags

      assert {:ok, %{"flagged" => 1, "tried" => 0}} = run(board)
      assert [%Incident{status: "flagged", attempts: 2} = i] = incidents(board)
      assert i.flagged_at
      assert "stuck" in card!(card).flags

      [tried1, tried2, flagged] = comments(card)
      assert tried1 =~ "Tried (1 of 2): ran the feed"
      assert tried2 =~ "Tried (2 of 2): ran the feed"
      assert flagged =~ "**Health monitor: stuck**"
      assert flagged =~ "Found: it is held up"
      assert flagged =~ "Tried (1 of 2): ran the feed"
      assert flagged =~ "Still stuck after 2 attempts"

      # Flagged stays flagged: no more fixes, comments or flags.
      assert {:ok, %{"flagged" => 0, "tried" => 0}} = run(board)
      assert length(comments(card)) == 3
    end

    test "no fix flags at once; a detector with no resolve/2 too", %{board: board, card: card} do
      other = card_fixture(Enum.at(board.columns, 1), %{"title" => "Other"})
      Process.put(:probe_findings, [finding(card)])
      Process.put(:watcher_findings, [finding(other)])

      assert {:ok, %{"opened" => 2, "flagged" => 2}} = run(board)
      assert Enum.all?(incidents(board), &(&1.status == "flagged" and &1.attempts == 0))
      assert "stuck" in card!(card).flags
      assert "stuck" in card!(other).flags
      assert [body] = comments(other)
      assert body =~ "No safe fix to try."
    end

    test "max_attempts comes from the tree's settings", %{board: board, card: card} do
      {:ok, _} = Settings.put(board.id, Probe, %{"max_attempts" => 1})
      Process.put(:probe_findings, [finding(card)])
      Process.put(:probe_fix, {:tried, "x"})

      run(board)
      assert {:ok, %{"flagged" => 1}} = run(board)
    end

    test "with no card, a flag is a board alert", %{board: board} do
      Process.put(:probe_findings, [finding(nil)])

      assert {:ok, %{"flagged" => 1}} = run(board)
      assert [%Incident{status: "flagged", alert_id: alert_id}] = incidents(board)

      assert %Alert{board_id: board_id, title: title, severity: "warning"} =
               Repo.get!(Alert, alert_id)

      assert board_id == board.id
      assert title == "Stuck (Probe): it is held up"
    end

    test "every subject card of a flagged incident gets the flag", %{board: board, card: card} do
      other = card_fixture(Enum.at(board.columns, 1), %{"title" => "Loop"})

      Process.put(:watcher_findings, [
        %{finding(card) | subject: %{"cards" => [card.id, other.id]}}
      ])

      run(board)
      assert "stuck" in card!(card).flags
      assert "stuck" in card!(other).flags
    end

    test "a fix that raises counts as tried", %{board: board, card: card} do
      Process.put(:probe_findings, [finding(card)])
      Process.put(:probe_fix, :boom)

      defmodule Raiser do
        @behaviour Slipdock.Health.Detector
        def key, do: "raiser"
        def label, do: "Raiser"
        def defaults, do: %{}
        def detect(_ctx, _s), do: Process.get(:probe_findings)
        def resolve(_i, _n), do: raise("no runner")
      end

      assert {:ok, %{"tried" => 1}} = Health.run(board, detectors: [Raiser])
      assert [%Incident{log: [_, %{"what" => what}]}] = incidents(board)
      assert what =~ "the fix failed (no runner)"
    end
  end

  describe "fingerprints" do
    test "the same state never opens twice; a changed state opens a new one", %{
      board: board,
      card: card
    } do
      Process.put(:probe_findings, [finding(card, 1)])
      run(board)
      run(board)
      assert [%Incident{status: "flagged"} = first] = incidents(board)

      Process.put(:probe_findings, [finding(card, 2)])
      assert {:ok, %{"opened" => 1, "cleared" => 1}} = run(board)

      assert [%Incident{id: id, status: "cleared"}, %Incident{status: "flagged"}] =
               incidents(board)

      assert id == first.id
      # The card stays stuck: the new incident flagged it again.
      assert "stuck" in card!(card).flags
    end

    test "an incident clears when its condition goes, and the stuck flag comes off", %{
      board: board,
      card: card
    } do
      Process.put(:probe_findings, [finding(card)])
      run(board)
      assert "stuck" in card!(card).flags

      Process.put(:probe_findings, [])
      assert {:ok, %{"cleared" => 1}} = run(board)
      assert [%Incident{status: "cleared", resolved_at: %DateTime{}}] = incidents(board)
      refute "stuck" in card!(card).flags
      assert List.last(comments(card)) =~ "cleared"
    end

    test "a disabled detector neither finds nor clears", %{board: board, card: card} do
      Process.put(:probe_findings, [finding(card)])
      run(board)
      {:ok, _} = Settings.put(board.id, Probe, %{"enabled" => false})
      Process.put(:probe_findings, [finding(card, 9)])

      assert {:ok, %{"found" => 0, "cleared" => 0}} = run(board)
      assert [%Incident{status: "flagged"}] = incidents(board)
    end

    test "a state that comes back after a fix keeps its attempts", %{board: board, card: card} do
      Process.put(:probe_findings, [finding(card)])
      Process.put(:probe_fix, :fixed)
      run(board)
      run(board)
      assert {:ok, %{"flagged" => 1}} = run(board)
      assert [%{status: "fixed"}, %{status: "fixed"}, %{status: "flagged"}] = incidents(board)
    end

    test "a sub-board's finding is kept on the root board", %{board: board, card: card} do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card, t)
      sub = Boards.get_board!(sub.id)
      sub_card = card_fixture(hd(sub.columns), %{"title" => "Deep"})
      Process.put(:probe_findings, [finding(sub_card)])

      run(sub)
      assert [%Incident{card_id: id}] = incidents(board)
      assert id == sub_card.id
    end
  end

  describe "clearing by hand" do
    test "taking the stuck flag off marks it handled; the same state isn't flagged again", %{
      board: board,
      card: card
    } do
      Process.put(:probe_findings, [finding(card)])
      run(board)
      c = card!(card)
      {:ok, _} = Boards.update_card(c, %{"flags" => List.delete(c.flags, "stuck")})

      assert {:ok, %{"handled" => 1, "opened" => 0, "flagged" => 0}} = run(board)
      assert [%Incident{status: "handled"}] = incidents(board)
      refute "stuck" in card!(card).flags

      # Only a changed state is flagged again.
      Process.put(:probe_findings, [finding(card, 2)])
      assert {:ok, %{"flagged" => 1}} = run(board)
      assert "stuck" in card!(card).flags
    end
  end

  describe "the health_flagged trigger" do
    test "the preset emails a person, with what was found", %{
      board: board,
      card: card,
      owner: owner
    } do
      {:ok, _rule} =
        Automations.create_rule_from_preset(
          board,
          "health_flagged",
          %{"notify" => "email", "email" => owner.email},
          created_by: owner
        )

      Process.put(:probe_findings, [finding(card)])
      run(board)

      assert_email_sent(fn email ->
        assert [{_, to}] = email.to
        assert to == owner.email
        assert email.subject == "Stuck (probe): it is held up"
        assert email.text_body =~ "/boards/#{board.id}/health"
      end)
    end

    test "a detector filter hears only its own detector", %{
      board: board,
      card: card,
      owner: owner
    } do
      {:ok, _rule} =
        Automations.create_rule_from_preset(board, "health_flagged", %{"detector" => "watcher"},
          created_by: owner
        )

      Process.put(:probe_findings, [finding(card)])
      run(board)
      assert Automations.list_alerts(owner) == []

      Process.put(:watcher_findings, [finding(card, 5)])
      run(board)
      assert [alert] = Automations.list_alerts(owner)
      assert alert.title == "Stuck (watcher): it is held up"
    end

    test "the flagged preset hears the stuck flag", %{board: board, card: card, owner: owner} do
      {:ok, _} =
        Automations.create_rule_from_preset(board, "flagged", %{"flag" => "stuck"},
          created_by: owner
        )

      Process.put(:probe_findings, [finding(card)])
      run(board)
      assert [alert] = Automations.list_alerts(owner)
      assert alert.title == "Flagged stuck: Held up"
    end
  end

  describe "settings" do
    test "defaults, the tree's changes, and what is refused", %{board: board} do
      assert Settings.for(Settings.changes(board.id), Probe) ==
               %{"enabled" => true, "max_attempts" => 2, "minutes" => 15}

      assert {:ok, %{"minutes" => 30}} = Settings.put(board.id, Probe, %{"minutes" => "30"})
      assert {:error, "unknown setting: colour"} = Settings.put(board.id, Probe, %{"colour" => 1})

      assert {:error, "minutes must be a whole number above 0"} =
               Settings.put(board.id, Probe, %{"minutes" => 0})

      assert {:error, "enabled must be true or false"} =
               Settings.put(board.id, Probe, %{"enabled" => "x"})

      # Back to the default keeps nothing.
      assert {:ok, _} = Settings.put(board.id, Probe, %{"minutes" => 15})
      assert Settings.changes(board.id) == %{}
    end

    test "the detector reads the tree's thresholds", %{board: board} do
      {:ok, _} = Settings.put(board.id, Probe, %{"minutes" => 45})
      run(board)
      assert_received {:settings, %{"minutes" => 45}}
    end
  end

  describe "the clock" do
    test "manual in tests" do
      assert Health.tick() == :manual
    end

    test "runs when due, records its pulse, and waits for the interval", %{
      board: board,
      owner: owner
    } do
      Slipdock.Config.override(:health, interval_minutes: 5)

      {:ok, _} =
        Automations.create_rule_from_preset(board, "health_flagged", %{}, created_by: owner)

      assert board.id in Enum.map(Health.watched_boards(), & &1.id)

      now = ~U[2026-11-05 12:00:00Z]
      Pulse.beat("monitor", DateTime.add(now, -6, :minute))
      assert Health.tick(now) == :ran
      assert Pulse.last("monitor") == now
      assert Health.tick(DateTime.add(now, 4, :minute)) == :not_due
      assert Health.tick(DateTime.add(now, 5, :minute)) == :ran
    end

    test "a board with no runners or rules isn't watched", %{board: board} do
      refute board.id in Enum.map(Health.watched_boards(), & &1.id)
    end

    test "every detector under Slipdock.Health.Detectors is found" do
      assert Enum.all?(Health.detectors(), &function_exported?(&1, :detect, 2))
    end
  end
end
