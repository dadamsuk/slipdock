defmodule Slipdock.Gardener.StepsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias Slipdock.Gardener.Steps
  alias Slipdock.Wiki

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    card = card_fixture(todo, %{"title" => "Subject"})
    %{owner: owner, board: board, todo: todo, doing: doing, done: done, card: card}
  end

  defp card(c), do: Boards.get_card!(c.id)

  test "complete, and reopen to undo", %{card: c, owner: u} do
    {:ok, inverse} = Steps.apply_all([%{"op" => "complete", "card" => c.id}], u)
    assert card(c).completed
    assert :ok = Steps.undo_all(inverse, u)
    refute card(c).completed
  end

  test "completing a card already complete has nothing to undo", %{todo: todo, owner: u} do
    c = card_fixture(todo, %{"completed" => true})
    assert {:ok, []} = Steps.apply_all([%{"op" => "complete", "card" => c.id}], u)
  end

  test "move, to the top by default, and back to the same place", %{
    todo: todo,
    done: done,
    owner: u,
    card: c
  } do
    other = card_fixture(done)
    _below = card_fixture(todo)
    {:ok, inverse} = Steps.apply_all([%{"op" => "move", "card" => c.id, "column" => done.id}], u)

    assert card(c).column_id == done.id
    assert [{:card, first} | _] = Boards.active_items(done.id)
    assert first == c.id
    assert {:card, other.id} in Boards.active_items(done.id)

    assert :ok = Steps.undo_all(inverse, u)
    assert card(c).column_id == todo.id
    assert [{:card, ^first} | _] = Boards.active_items(todo.id)
  end

  test "a list on another board is refused", %{card: c, owner: u} do
    elsewhere = board_fixture(%{}, owner: u)

    assert {:error, "that list is on another board"} =
             Steps.apply_all(
               [%{"op" => "move", "card" => c.id, "column" => hd(elsewhere.columns).id}],
               u
             )
  end

  test "archive and restore a card", %{card: c, owner: u} do
    {:ok, inverse} = Steps.apply_all([%{"op" => "archive", "card" => c.id}], u)
    assert Repo.reload!(c).archived_at
    assert :ok = Steps.undo_all(inverse, u)
    refute Repo.reload!(c).archived_at
  end

  test "archive and restore a page; restored by hand refuses", %{board: board, owner: u} do
    page = page_fixture(board, %{}, user: u)
    {:ok, inverse} = Steps.apply_all([%{"op" => "archive", "page" => page.id}], u)
    assert Repo.reload!(page).archived_at

    {:ok, _} = Wiki.unarchive_page(Repo.reload!(page))
    assert {:error, msg} = Steps.undo_all(inverse, u)
    assert msg =~ "has been restored since"
  end

  test "link_duplicate and unlink", %{card: c, todo: todo, owner: u} do
    other = card_fixture(todo)

    {:ok, inverse} =
      Steps.apply_all([%{"op" => "link_duplicate", "card" => c.id, "other" => other.id}], u)

    assert Steps.links_between(c.id, other.id)
    assert :ok = Steps.undo_all(inverse, u)
    refute Steps.links_between(c.id, other.id)
  end

  test "flag and unflag; a flag already set is left alone", %{card: c, owner: u} do
    {:ok, inverse} = Steps.apply_all([%{"op" => "flag", "card" => c.id, "flag" => "review"}], u)
    assert "review" in card(c).flags
    assert {:ok, []} = Steps.apply_all([%{"op" => "flag", "card" => c.id, "flag" => "review"}], u)

    assert :ok = Steps.undo_all(inverse, u)
    refute "review" in card(c).flags
  end

  test "unflagging after the flag was taken off by hand refuses", %{card: c, owner: u} do
    {:ok, inverse} = Steps.apply_all([%{"op" => "flag", "card" => c.id, "flag" => "review"}], u)
    {:ok, _} = Boards.toggle_flag(card(c), "review")
    assert {:error, msg} = Steps.undo_all(inverse, u)
    assert msg =~ "has lost its review flag since"
  end

  test "comment as the person, and take it away", %{card: c, owner: u} do
    {:ok, inverse} =
      Steps.apply_all([%{"op" => "comment", "card" => c.id, "body" => "No next step"}], u)

    assert [comment] = card(c).comments
    assert comment.body == "No next step"
    assert comment.user_id == u.id
    assert :ok = Steps.undo_all(inverse, u)
    assert card(c).comments == []
  end

  test "snooze and wake", %{card: c, owner: u} do
    until = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()
    {:ok, inverse} = Steps.apply_all([%{"op" => "snooze", "card" => c.id, "until" => until}], u)
    assert Repo.reload!(c).snoozed_until
    assert :ok = Steps.undo_all(inverse, u)
    refute Repo.reload!(c).snoozed_until
  end

  test "a snooze in the past is refused with the reason", %{card: c, owner: u} do
    assert {:error, "the snooze must end in the future"} =
             Steps.apply_all([%{"op" => "snooze", "card" => c.id, "until" => "2020-01-01"}], u)
  end

  test "rewrite_link, and set the body back", %{board: board, owner: u} do
    page =
      page_fixture(board, %{"body" => "See [[Runbok]] and [[runbok#Deploy|the deploy]]."},
        user: u
      )

    {:ok, inverse} =
      Steps.apply_all(
        [%{"op" => "rewrite_link", "page" => page.id, "from" => "Runbok", "to" => "Runbook"}],
        u
      )

    assert Repo.reload!(page).body == "See [[Runbook]] and [[Runbook#Deploy|the deploy]]."
    assert :ok = Steps.undo_all(inverse, u)
    assert Repo.reload!(page).body == "See [[Runbok]] and [[runbok#Deploy|the deploy]]."
  end

  test "rewrite_link refuses a page no longer linking there, and an undo after an edit", %{
    board: board,
    owner: u
  } do
    page = page_fixture(board, %{"body" => "[[Runbok]]"}, user: u)
    step = %{"op" => "rewrite_link", "page" => page.id, "from" => "Nope", "to" => "Runbook"}
    assert {:error, msg} = Steps.apply_all([step], u)
    assert msg =~ "no longer links to [[Nope]]"

    {:ok, inverse} = Steps.apply_all([%{step | "from" => "Runbok"}], u)
    {:ok, _} = Wiki.update_page(Repo.reload!(page), %{"body" => "Rewritten"}, user: u)
    assert {:error, msg} = Steps.undo_all(inverse, u)
    assert msg =~ "has been edited since"
    assert Repo.reload!(page).body == "Rewritten"
  end

  test "file_page into a folder and out again", %{board: board, owner: u} do
    page = page_fixture(board, %{}, user: u)
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "notes"})

    {:ok, inverse} =
      Steps.apply_all([%{"op" => "file_page", "page" => page.id, "folder" => folder.id}], u)

    assert Repo.reload!(page).folder_id == folder.id
    assert :ok = Steps.undo_all(inverse, u)
    assert Repo.reload!(page).folder_id == nil
  end

  test "a failing step unwinds the ones before it", %{card: c, owner: u} do
    assert {:error, "card #0 has been deleted"} =
             Steps.apply_all(
               [
                 %{"op" => "complete", "card" => c.id},
                 %{"op" => "flag", "card" => 0, "flag" => "x"}
               ],
               u
             )

    refute card(c).completed
  end

  test "an unknown op is refused", %{owner: u} do
    assert {:error, "unknown step “burn”"} = Steps.apply_all([%{"op" => "burn"}], u)
    assert {:error, "a step needs an op"} = Steps.apply_all([%{}], u)
  end

  describe "picks" do
    test "keep names the survivor and the other is the one acted on" do
      steps = [%{"op" => "archive", "card" => "pick", "from" => [1, 2]}]
      assert {:ok, [%{"op" => "archive", "card" => 2} = step]} = Steps.resolve_picks(steps, "1")
      refute Map.has_key?(step, "from")
      assert Steps.needs_pick?(steps)
      refute Steps.needs_pick?([step])
    end

    test "without a keep, or a keep that isn't a candidate, is refused" do
      steps = [%{"op" => "archive", "card" => "pick", "from" => [1, 2]}]
      assert {:error, "say which card to keep: one of #1, #2"} = Steps.resolve_picks(steps, nil)
      assert {:error, _} = Steps.resolve_picks(steps, 3)
    end
  end

  test "authorize wants write access to every card a step touches", %{
    board: board,
    card: c,
    owner: u
  } do
    reader = user_fixture("steps-reader-#{System.unique_integer([:positive])}@example.com")
    share_fixture(board, reader, "read")
    steps = [%{"op" => "complete", "card" => c.id}]

    assert :ok = Steps.authorize(steps, u)
    assert {:error, :forbidden} = Steps.authorize(steps, reader)
  end

  test "rewrite/3 leaves other links alone" do
    assert Steps.rewrite("[[Runbok]] [[Runbook old]] [[Other]]", "Runbok", "Runbook") ==
             "[[Runbook]] [[Runbook old]] [[Other]]"
  end
end
