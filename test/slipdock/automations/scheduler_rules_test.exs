defmodule Slipdock.Automations.SchedulerRulesTest do
  # A tick runs the periodic jobs and then the scheduled rules, and answers
  # how many rules fired (#2004). Driven through `handle_call(:tick, …)` in
  # the test's own process, so the sandbox needs no sharing.
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Automations.Scheduler

  defp stale_card_rule do
    board = board_fixture(%{"name" => "Launch"})
    [backlog | _] = board.columns

    rule_fixture(board, %{
      "trigger" => %{"type" => "card_stale", "days" => 7, "column" => backlog.name},
      "actions" => [%{"type" => "add_flags", "flags" => ["waiting"]}]
    })

    card = card_fixture(backlog, %{"title" => "Stale"})
    then = DateTime.add(DateTime.utc_now(:second), -10 * 24 * 3600, :second)

    Repo.update_all(from(c in Boards.Card, where: c.id == ^card.id),
      set: [updated_at: then, inserted_at: then]
    )

    card
  end

  test "a tick runs the scheduled rules and answers how many fired" do
    card = stale_card_rule()

    assert {:reply, 1, %{}} = Scheduler.handle_call(:tick, {self(), make_ref()}, %{})
    assert Boards.Cards.get_card!(card.id).flags == ["waiting"]

    # Fired once per occasion: the next tick has nothing to do.
    assert {:reply, 0, %{}} = Scheduler.handle_call(:tick, {self(), make_ref()}, %{})
  end

  test "a tick with no rules due answers 0" do
    assert {:reply, 0, %{}} = Scheduler.handle_call(:tick, {self(), make_ref()}, %{})
  end
end
