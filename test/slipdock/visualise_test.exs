defmodule Slipdock.VisualiseTest do
  # The database reads behind the Visualise page (#2791). The page itself is
  # in test/slipdock_web/live/board_live/visualise_test.exs.
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Visualise}
  alias Slipdock.Boards.Wait

  setup do
    board = board_fixture(%{"name" => "Charts"})
    [backlog, todo, doing, done] = board.columns
    %{board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(:second), -seconds)

  defp stand_in(card, column) do
    Repo.insert!(%Boards.Card{
      title: "stand-in",
      board_id: column.board_id,
      column_id: column.id,
      stand_in_for_id: card.id
    })
  end

  test "card_counts/1 counts live cards per list, never archived or stand-ins", %{
    board: board,
    backlog: backlog,
    doing: doing
  } do
    a = card_fixture(backlog)
    _b = card_fixture(backlog)
    c = card_fixture(doing)
    {:ok, _} = Boards.Cards.archive_card(c)
    stand_in(a, doing)
    _elsewhere = card_fixture(hd(board_fixture().columns))

    assert Visualise.card_counts(board) == %{backlog.id => 2}
  end

  test "archived_counts/2 counts what was archived from each list since then", %{
    board: board,
    done: done,
    doing: doing
  } do
    since = ago(60)
    for _ <- 1..2, do: {:ok, _} = Boards.Cards.archive_card(card_fixture(done))
    {:ok, _} = Boards.Cards.archive_card(card_fixture(doing))

    assert Visualise.archived_counts(board, since) == %{done.id => 2, doing.id => 1}
    assert Visualise.archived_counts(board, DateTime.add(DateTime.utc_now(), 60)) == %{}
  end

  test "done_cards/2: the cards in those lists, and the archived ones completed since", %{
    board: board,
    done: done,
    backlog: backlog
  } do
    tag = tag_fixture(board, "bug")
    here = card_fixture(done)
    {:ok, _} = Boards.Tags.toggle_card_tag(here, tag)

    recent = card_fixture(done)
    {:ok, recent} = Boards.Cards.update_card(recent, %{"completed" => true})
    {:ok, _} = Boards.Cards.archive_card(recent)

    old = card_fixture(done)
    {:ok, old} = Boards.Cards.update_card(old, %{"completed" => true})
    {:ok, _} = Boards.Cards.archive_card(old)

    Repo.update_all(from(c in Boards.Card, where: c.id == ^old.id),
      set: [completed_at: ago(86_400)]
    )

    stand_in(here, done)
    _elsewhere = card_fixture(backlog)

    cards = Visualise.done_cards([done.id], ago(3600))

    assert cards |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([here.id, recent.id])
    assert Enum.find(cards, &(&1.id == here.id)).tags |> Enum.map(& &1.name) == ["bug"]
    assert Visualise.done_cards([], ago(3600)) == []
  end

  test "open_cards/1: open, live cards in those lists, with tags and the open wait", %{
    todo: todo,
    doing: doing,
    backlog: backlog
  } do
    waiting = card_fixture(doing)
    answered = card_fixture(todo)
    done = card_fixture(doing)
    {:ok, _} = Boards.Cards.update_card(done, %{"completed" => true})
    archived = card_fixture(doing)
    {:ok, _} = Boards.Cards.archive_card(archived)
    stand_in(waiting, doing)
    _elsewhere = card_fixture(backlog)

    Repo.insert!(%Wait{card_id: waiting.id, needs: "Which?"})
    Repo.insert!(%Wait{card_id: answered.id, needs: "Old", closed_at: ago(10)})

    cards = Visualise.open_cards([todo.id, doing.id])

    assert cards |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([waiting.id, answered.id])
    assert %Wait{needs: "Which?"} = Enum.find(cards, &(&1.id == waiting.id)).wait
    assert Enum.find(cards, &(&1.id == answered.id)).wait == nil
    assert Enum.all?(cards, &(&1.tags == []))
  end

  test "last_answered_wait/1: the most recently answered wait's open and close times", %{
    board: board,
    doing: doing
  } do
    assert Visualise.last_answered_wait(board) == nil

    card = card_fixture(doing)

    for {opened, closed, reason} <- [
          {500, 400, "answered"},
          {300, 200, "answered"},
          {100, 50, "withdrawn"}
        ] do
      Repo.insert!(%Wait{
        card_id: card.id,
        needs: "q",
        inserted_at: ago(opened),
        closed_at: ago(closed),
        close_reason: reason
      })
    end

    _other =
      Repo.insert!(%Wait{
        card_id: card_fixture(hd(board_fixture().columns)).id,
        needs: "elsewhere",
        closed_at: ago(1),
        close_reason: "answered"
      })

    assert {opened, closed} = Visualise.last_answered_wait(board)
    assert DateTime.diff(closed, opened) == 100
    assert abs(DateTime.diff(DateTime.utc_now(), closed) - 200) <= 2
  end
end
