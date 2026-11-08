defmodule Slipdock.RecurrenceCleanStartTest do
  # A series' next instance is the work, not the last one's state of it
  # (#2081): what a runner, a verifier or a person left on the previous
  # instance stays there.
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Actor, Automations, Boards, Recurrence, Repo}
  alias Slipdock.Boards.Card
  alias Slipdock.Recurrence.Series

  # 11 Jan 2027 is a Monday; London is on GMT, so local is UTC.
  setup do
    owner = user_fixture()
    {:ok, owner} = Slipdock.Accounts.update_profile(owner, %{"timezone" => "Europe/London"})
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns

    {:ok, tag} = Boards.create_tag(board, %{"name" => "chore", "color" => "sky"})

    card =
      card_fixture(todo, %{
        "title" => "Sweep the code",
        "description" => "Read the diff of the day.",
        "priority" => "high",
        "due_date" => "2027-01-11",
        "bar" => "1. A sweep filed\n2. Nothing left open",
        "paths" => "lib/**,test/**",
        "profile" => "fix"
      })

    {:ok, _} = Boards.set_card_tags(card, [tag])
    {:ok, item} = Boards.add_checklist_item(card, "Read the log")
    {:ok, _} = Boards.toggle_checklist_item(item)
    {:ok, series} = Recurrence.set(card, %{"rule" => "mon", "on_missed" => "stack"}, owner)

    %{owner: owner, board: board, todo: todo, doing: doing, card: card, series: series}
  end

  # The previous instance as a runner leaves it: worked, assigned to the
  # token's owner, flagged, part done, handed off, its bar locked, evidence
  # given, waiting on a person.
  defp worked(ctx) do
    card = Repo.get!(Card, ctx.card.id)

    {:ok, card} =
      Boards.update_card(card, %{
        "assignee_ids" => [ctx.owner.id],
        "flags" => ["review", "flagged", "starred", "stuck", "blocked"],
        "percent_complete" => 60
      })

    {:ok, _} =
      Boards.leave_handoff(card, ctx.owner, %{
        next_step: "Read the rest of the log",
        body: "Half way",
        via: "ui"
      })

    {:ok, _} = Boards.open_wait(card, Actor.web(ctx.owner), %{"needs" => "Which day?"})

    from(c in Card, where: c.id == ^card.id)
    |> Repo.update_all(
      set: [
        bar_locked_at: ~U[2027-01-11 08:00:00Z],
        evidence: "Swept",
        evidence_commit: "abc1234",
        evidence_pr: "https://example.com/pr/1",
        verify_state: "pending",
        agent_assignee_ids: [ctx.owner.id]
      ]
    )

    Boards.get_card!(card.id)
  end

  defp next_instance(ctx) do
    assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 1
    Boards.get_card!(Repo.get!(Series, ctx.series.id).card_id)
  end

  describe "the next instance carries none of the last one's work state" do
    setup ctx do
      previous = worked(ctx)
      # Every piece of state is really on the previous instance.
      assert [_] = previous.assignees
      assert "review" in previous.flags
      assert previous.percent_complete == 60
      assert Boards.current_handoff(previous)
      assert previous.bar_locked_at
      assert previous.evidence_commit == "abc1234"
      assert Boards.current_wait(previous)
      %{previous: previous, new: next_instance(ctx)}
    end

    test "is a new card", %{new: new, previous: previous} do
      assert new.id != previous.id
    end

    test "no assignees", %{new: new} do
      assert new.assignees == []
      assert new.assignee_id == nil
      assert new.agent_assignee_ids == []
    end

    test "no flags, the ones a plain copy keeps included", %{new: new} do
      assert new.flags == []
    end

    test "no percent complete", %{new: new} do
      assert new.percent_complete in [nil, 0]
    end

    test "no handoff", %{new: new} do
      assert Boards.current_handoff(new) == nil
    end

    test "no bar lock", %{new: new} do
      assert new.bar_locked_at == nil
    end

    test "no evidence, and nothing awaiting verification", %{new: new} do
      assert new.evidence == nil
      assert new.evidence_commit == nil
      assert new.evidence_pr == nil
      assert new.verify_state == nil
    end

    test "no waits", %{new: new} do
      assert Boards.current_wait(new) == nil
      assert Boards.list_waits(new) == []
    end

    test "the previous instance keeps its state", %{previous: previous} do
      kept = Boards.get_card!(previous.id)
      assert [_] = kept.assignees
      assert "review" in kept.flags
      assert Boards.current_wait(kept)
    end
  end

  test "it keeps what defines the work", ctx do
    worked(ctx)
    new = next_instance(ctx)

    assert new.title == "Sweep the code"
    assert new.description == "Read the diff of the day."
    assert new.priority == "high"
    assert new.bar == "1. A sweep filed\n2. Nothing left open"
    assert new.paths == ["lib/**", "test/**"]
    assert new.profile == "fix"
    assert Enum.map(new.tags, & &1.name) == ["chore"]
    assert new.due_date == ~D[2027-01-18]
    assert [%{text: "Read the log", done: false}] = new.checklist_items
    assert new.column_id == ctx.todo.id
  end

  test "a feed rule for unassigned cards takes the fresh instance", ctx do
    {:ok, _runner, _} =
      Slipdock.Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})

    rule =
      rule_fixture(
        ctx.board,
        %{
          "trigger" => %{"type" => "list_top", "column" => "To Do", "unassigned" => true},
          "actions" => [%{"type" => "runner", "pool" => "loop"}]
        },
        %{"enabled" => false}
      )

    # A runner worked it and assigned it to itself (its token's owner), then
    # finished it in place.
    card = Repo.get!(Card, ctx.card.id)
    {:ok, card} = Boards.update_card(card, %{"assignee_ids" => [ctx.owner.id]})
    {:ok, _} = Boards.update_card(card, %{"completed" => true})
    assert Automations.next_card(rule) == nil

    new = next_instance(ctx)
    assert Automations.next_card(rule).id == new.id
  end

  describe "copied_from/1" do
    test "names the instance each was copied from", ctx do
      first = Repo.get!(Card, ctx.card.id)
      second = next_instance(ctx)
      assert Recurrence.tick(~U[2027-01-25 07:00:00Z]) == 1
      third = Repo.get!(Card, Repo.get!(Series, ctx.series.id).card_id)

      assert Recurrence.copied_from(first) == nil
      assert Recurrence.copied_from(second).id == first.id
      assert Recurrence.copied_from(third).id == second.id
    end

    test "nil for a card no series made", ctx do
      assert Recurrence.copied_from(card_fixture(ctx.todo)) == nil
    end
  end
end
