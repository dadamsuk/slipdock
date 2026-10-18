defmodule Slipdock.Gardener.Checks.DuplicateCardsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.Boards
  alias Slipdock.Gardener
  alias Slipdock.Gardener.Checks.DuplicateCards
  alias Slipdock.Search.{Embedding, Vector}

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo, _doing, _done] = board.columns
    %{owner: owner, board: board, todo: todo}
  end

  # A card whose stored vector points `degrees` round from the x axis: two
  # cards' similarity is the cosine of the angle between them.
  defp card_at(column, degrees, attrs \\ %{}, model \\ nil) do
    card = card_fixture(column, attrs)
    r = degrees * :math.pi() / 180
    vector = Vector.pack([:math.cos(r), :math.sin(r)])
    Repo.delete_all(from(e in Embedding, where: e.card_id == ^card.id))

    Repo.insert!(%Embedding{
      kind: "card",
      source_id: card.id,
      section: "",
      body: card.title,
      content_hash: "stub",
      model: model || Slipdock.AI.Embeddings.model(),
      dimensions: 2,
      vector: vector,
      card_id: card.id,
      board_id: card.board_id
    })

    card
  end

  test "two open cards that read alike are a pair, the loser for the person to pick", %{
    board: board,
    todo: todo
  } do
    a = card_at(todo, 0, %{"title" => "Fix login"})
    b = card_at(todo, 10, %{"title" => "Login is broken"})

    assert [finding] = find(DuplicateCards, board)
    assert finding.subject == %{"cards" => [a.id, b.id]}

    assert finding.explanation =~
             "“Fix login” (##{a.id}) and “Login is broken” (##{b.id}) read alike"

    assert finding.explanation =~ "similarity 0.98"

    assert [
             %{"op" => "link_duplicate", "card" => "pick", "other" => "keep"},
             %{"op" => "archive", "card" => "pick"}
           ] = finding.proposal
  end

  test "the threshold: below it is not a pair, at it is", %{board: board, todo: todo} do
    card_at(todo, 0)
    card_at(todo, 30)
    # cos 30° ≈ 0.866
    assert find(DuplicateCards, board) == []
    assert [_] = find(DuplicateCards, board, settings: %{"similarity" => 0.86})
    assert find(DuplicateCards, board, settings: %{"similarity" => 0.87}) == []
  end

  test "pairs already linked, archived and completed cards are skipped", %{
    board: board,
    todo: todo
  } do
    a = card_at(todo, 0)
    b = card_at(todo, 1)
    {:ok, _} = Boards.add_link(b, a, "relates")
    archived = card_at(todo, 2)
    {:ok, _} = Boards.archive_card(archived)
    card_at(todo, 3, %{"completed" => true})

    assert find(DuplicateCards, board) == []
  end

  test "vectors from another model are not compared", %{board: board, todo: todo} do
    card_at(todo, 0)
    card_at(todo, 1, %{}, "some/older-model")
    assert find(DuplicateCards, board) == []
  end

  test "the cap: only the most recently updated cards are looked at", %{board: board, todo: todo} do
    old = card_at(todo, 0)
    age(old, 10)
    a = card_at(todo, 1)
    b = card_at(todo, 2)

    assert length(find(DuplicateCards, board)) == 3

    assert [%{subject: %{"cards" => pair}}] =
             find(DuplicateCards, board, settings: %{"max_cards" => 2})

    assert pair == [a.id, b.id]
  end

  test "applying links them and archives the one not kept", %{
    board: board,
    todo: todo,
    owner: owner
  } do
    a = card_at(todo, 0)
    b = card_at(todo, 5)
    {:ok, _} = Gardener.run(board, only: ["duplicate_cards"])
    [s] = Gardener.list_open(board)

    assert {:error, "say which card to keep: one of #" <> _} = Gardener.apply(s, owner)

    {:ok, applied} = Gardener.apply(s, owner, keep: a.id)
    assert Repo.reload!(b).archived_at
    refute Repo.reload!(a).archived_at

    assert [%{kind: "duplicates", to_id: to}] =
             Repo.all(from(l in Boards.CardLink, where: l.from_id == ^b.id))

    assert to == a.id

    {:ok, _} = Gardener.undo(applied, owner)
    refute Repo.reload!(b).archived_at
    assert Repo.all(from(l in Boards.CardLink, where: l.from_id == ^b.id)) == []
  end

  test "a dismissed pair stays dismissed after either card is edited", %{
    board: board,
    todo: todo,
    owner: owner
  } do
    a = card_at(todo, 0)
    card_at(todo, 5)
    {:ok, _} = Gardener.run(board, only: ["duplicate_cards"])
    [s] = Gardener.list_open(board)
    {:ok, _} = Gardener.dismiss(s, owner)

    {:ok, _} = Boards.update_card(Boards.get_card!(a.id), %{"description" => "edited"})
    {:ok, run} = Gardener.run(board, only: ["duplicate_cards"])
    assert run.counts["new"] == 0
  end
end
