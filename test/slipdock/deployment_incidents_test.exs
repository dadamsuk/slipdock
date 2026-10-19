defmodule Slipdock.DeploymentIncidentsTest do
  @moduledoc """
  Failed changes, time to restore and rework (#1134,
  `Slipdock.Deployments.Incidents`): each failure signal on its own and
  together (counted once), the hotfix window's boundary, both restore
  paths, a renamed incident tag, and linking a card to a deploy.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments, Repo}
  alias Slipdock.Boards.Card
  alias Slipdock.Deployments.Incidents

  @t0 ~U[2026-10-01 12:00:00.000000Z]

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Ops"}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    [_backlog, todo | _] = board.columns
    %{user: user, board: board, todo: todo}
  end

  defp at(hours), do: DateTime.add(@t0, round(hours * 3600), :second)

  # A deploy recorded already finished, `hours` after t0.
  defp deploy!(board, hours, attrs \\ %{}) do
    sha = :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)

    {:ok, d} =
      Deployments.start(
        board,
        Map.merge(
          %{
            environment: "production",
            sha: sha,
            status: "succeeded",
            started_at: at(hours),
            finished_at: at(hours + 0.1)
          },
          attrs
        )
      )

    d
  end

  defp incident!(board, todo, tag_name \\ "incident") do
    tag = Boards.find_tag(board, tag_name) |> then(fn {:ok, t} -> t end)
    card = card_fixture(todo, %{"title" => "Outage #{System.unique_integer([:positive])}"})
    {:ok, card} = Boards.toggle_card_tag(card, tag)
    card
  end

  defp tag!(board, name), do: tag_fixture(board, name)

  defp fix_commit(card), do: [%{"sha" => "abcdef1234", "subject" => "fix: outage ##{card.id}"}]

  defp failures(board), do: Incidents.failures(board, Deployments.list(board))

  test "the incident tag is incident unless the board says otherwise", %{board: board} do
    assert Incidents.tag(board) == "incident"
    {:ok, board} = Boards.update_board(board, %{"incident_tag" => "Outage"})
    assert Incidents.tag(board) == "Outage"
    {:ok, board} = Boards.update_board(board, %{"incident_tag" => "INCIDENT"})
    assert board.incident_tag == nil
    assert {:error, _} = Boards.update_board(board, %{"hotfix_window_hours" => -1})
  end

  test "a good deploy followed by a good one is not a failed change", %{board: board} do
    deploy!(board, 0)
    deploy!(board, 1)
    assert failures(board) == %{}
  end

  test "a deploy that ended failed", %{board: board} do
    d = deploy!(board, 0, %{status: "failed"})
    assert failures(board) == %{d.id => [:failed]}
  end

  test "a deploy followed by a rollback", %{board: board} do
    bad = deploy!(board, 0)
    back = deploy!(board, 1, %{rollback: true})
    assert failures(board) == %{bad.id => [:rolled_back]}
    refute Map.has_key?(failures(board), back.id)
  end

  test "a rollback in another environment doesn't count", %{board: board} do
    deploy!(board, 0)
    deploy!(board, 1, %{environment: "staging", rollback: true})
    assert failures(board) == %{}
  end

  test "an incident card linked to a deploy", %{board: board, todo: todo} do
    d = deploy!(board, 0)
    card = card_fixture(todo, %{"title" => "It broke"})
    assert {:ok, _} = Incidents.link(card, d.id)
    assert failures(board) == %{d.id => [:incident]}

    # Linked counts as an incident even without the tag.
    assert [%{id: id, deployment_id: did}] = Incidents.cards(board)
    assert {id, did} == {card.id, d.id}

    assert {:ok, _} = Incidents.link(Repo.get!(Card, card.id), nil)
    assert failures(board) == %{}
  end

  test "a deploy from another tree can't be linked", %{user: user, todo: todo} do
    other = board_fixture(%{"name" => "Theirs"}, owner: user)
    {:ok, other} = Boards.update_board(other, %{"delivery_metrics" => true})
    theirs = deploy!(other, 0)
    card = card_fixture(todo, %{"title" => "Mine"})

    assert Incidents.link(card, theirs.id) == {:error, :not_found}
    assert Incidents.link(card, "nope") == {:error, :not_found}
    assert Repo.get!(Card, card.id).caused_by_deployment_id == nil
  end

  test "a hotfix inside the window; the boundary counts, a minute past doesn't", %{
    board: board,
    todo: todo
  } do
    tag!(board, "incident")
    card = incident!(board, todo)

    # Hotfix exactly 24h after the first deploy finished.
    first = deploy!(board, 0)
    _fix = deploy!(board, 24.1, %{commits: fix_commit(card)})
    assert failures(board) == %{first.id => [:hotfix]}

    # Another pair, the fix a minute past the window.
    late = deploy!(board, 100)
    _fix2 = deploy!(board, 100.1 + 24 + 1 / 60, %{commits: fix_commit(card)})
    refute Map.has_key?(failures(board), late.id)
  end

  test "a narrower window from the board", %{board: board, todo: todo} do
    tag!(board, "incident")
    card = incident!(board, todo)
    {:ok, board} = Boards.update_board(board, %{"hotfix_window_hours" => 2})
    first = deploy!(board, 0)
    deploy!(board, 3, %{commits: fix_commit(card)})
    assert failures(board) == %{}
    refute Map.has_key?(failures(board), first.id)
  end

  test "every signal at once is still one failed change", %{board: board, todo: todo} do
    tag!(board, "incident")
    card = incident!(board, todo)
    d = deploy!(board, 0, %{status: "failed"})
    {:ok, _} = Incidents.link(card, d.id)
    deploy!(board, 1, %{rollback: true})

    assert %{} = f = failures(board)
    assert Map.keys(f) == [d.id]
    assert Enum.sort(f[d.id]) == Enum.sort([:failed, :rolled_back, :incident])
  end

  test "rework is a deploy whose commits name an incident card", %{board: board, todo: todo} do
    tag!(board, "incident")
    card = incident!(board, todo)
    plain = card_fixture(todo, %{"title" => "Feature"})
    ids = MapSet.new(Incidents.cards(board), & &1.id)

    fix = deploy!(board, 0, %{commits: fix_commit(card)})
    feature = deploy!(board, 1, %{commits: [%{"sha" => "abcdef9", "subject" => "##{plain.id}"}]})

    assert Incidents.rework?(fix, ids)
    refute Incidents.rework?(feature, ids)
  end

  test "a renamed incident tag: the new one counts, the old doesn't", %{board: board, todo: todo} do
    tag!(board, "incident")
    tag!(board, "outage")
    old = incident!(board, todo, "incident")
    new = incident!(board, todo, "outage")
    {:ok, board} = Boards.update_board(board, %{"incident_tag" => "Outage"})

    assert Enum.map(Incidents.cards(board), & &1.id) == [new.id]
    refute old.id in Enum.map(Incidents.cards(board), & &1.id)
  end

  test "time to restore from an incident card: created to completed", %{board: board, todo: todo} do
    tag!(board, "incident")
    card = incident!(board, todo)
    _open = incident!(board, todo)

    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: [inserted_at: at(0), completed: true, completed_at: DateTime.truncate(at(3), :second)]
    )

    assert [%{kind: :incident, id: id, seconds: 10_800}] = Incidents.restores(board, [])
    assert id == card.id
  end

  test "time to restore from a failed deploy: to the next good one in its environment", %{
    board: board
  } do
    failed = deploy!(board, 0, %{status: "failed"})
    deploy!(board, 0.5, %{environment: "staging"})
    deploy!(board, 1, %{status: "failed"})
    deploy!(board, 2)
    _unrestored = deploy!(board, 5, %{status: "failed"})

    restores = Incidents.restores(board, Deployments.list(board))
    assert [first, second] = Enum.sort_by(restores, & &1.from, DateTime)
    assert first.id == failed.id
    assert first.kind == :deploy
    # finished at 0.1h, restored by the deploy finishing at 2.1h.
    assert first.seconds == 2 * 3600
    assert second.seconds == 3600
  end

  test "a failed deploy with an incident linked is restored through the incident", %{
    board: board,
    todo: todo
  } do
    d = deploy!(board, 0, %{status: "failed"})
    deploy!(board, 1)
    card = card_fixture(todo, %{"title" => "Linked"})
    {:ok, _} = Incidents.link(card, d.id)

    assert Incidents.restores(board, Deployments.list(board)) == []
  end
end
