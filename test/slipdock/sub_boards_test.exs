defmodule Slipdock.SubBoardsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, Template}

  test "default templates exist and templates validate" do
    names = Boards.list_templates() |> Enum.map(& &1.name)
    assert "Slipdock" in names and "Bug triage" in names and "Roadmap" in names

    assert {:ok, t} =
             Boards.create_template(%{
               "name" => "Sprint",
               "columns" => [%{"name" => "Todo", "wip_limit" => "2", "color" => "sky"}, "Done"]
             })

    assert t.columns == [
             %{"name" => "Todo", "wip_limit" => 2, "color" => "sky", "category" => nil},
             %{"name" => "Done", "wip_limit" => nil, "color" => nil, "category" => nil}
           ]

    assert {:ok, ^t} = Boards.find_template("sprint")

    assert {:error, cs} = Boards.create_template(%{"name" => "Empty", "columns" => []})
    assert {"must have at least one list", _} = cs.errors[:columns]
    assert {:error, cs} = Boards.create_template(%{"name" => "Sprint", "columns" => ["A"]})
    assert {"already exists", _} = cs.errors[:name]

    # Form-style params keyed by index are accepted too.
    assert Template.normalize_columns(%{
             "1" => %{"name" => "B"},
             "0" => %{"name" => "A", "color" => "bogus"}
           }) ==
             [
               %{"name" => "A", "wip_limit" => nil, "color" => nil, "category" => nil},
               %{"name" => "B", "wip_limit" => nil, "color" => nil, "category" => nil}
             ]
  end

  test "boards can be created from a template and saved back as one" do
    {:ok, t} = Boards.find_template("Checklist")

    {:ok, board} =
      Boards.create_board(%{"name" => "From template"}, template: t, owner_id: user_fixture().id)

    board = Boards.get_board!(board.id)
    assert Enum.map(board.columns, & &1.name) == ["Open", "Done"]
    assert board.template_id == t.id

    attrs = Boards.template_attrs_from_board(board)

    assert attrs["columns"] == [
             %{"name" => "Open", "wip_limit" => nil, "color" => nil, "category" => nil},
             %{"name" => "Done", "wip_limit" => nil, "color" => "emerald", "category" => "done"}
           ]
  end

  test "a card gets a sub-board from a template; tags are shared; progress and rename follow" do
    board = board_fixture(%{"name" => "Root"})
    tag = tag_fixture(board, "shared")
    [backlog | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template("Simple")

    assert {:ok, sub} = Boards.create_sub_board(card, t)
    assert sub.parent_card_id == card.id and sub.root_id == board.id and sub.name == "Epic"
    assert {:error, "This card already has subcards."} = Boards.create_sub_board(card, t)

    sub = Boards.get_board!(sub.id)
    assert Enum.map(sub.columns, & &1.name) == ["To Do", "Doing", "Done"]
    assert Enum.map(sub.tags, & &1.id) == [tag.id]
    assert [%{board: %Board{id: root_id}, card: %Card{id: card_id}}] = Boards.ancestry(sub)
    assert root_id == board.id and card_id == card.id
    assert Boards.ancestry(board) == []

    # Tags created on the sub-board land on the root and are visible from both.
    {:ok, new_tag} = Boards.create_tag(sub, %{"name" => "from-sub", "color" => "rose"})
    assert new_tag.board_id == board.id
    assert Enum.map(reload(board).tags, & &1.name) == ["from-sub", "shared"]
    assert {:ok, _} = Boards.find_tag(sub, "shared")

    # Subcards and progress; a nested sub-board works too.
    s1 = card_fixture(hd(sub.columns), %{"title" => "Part 1", "completed" => true})
    _s2 = card_fixture(hd(sub.columns), %{"title" => "Part 2"})
    card = Boards.get_card!(card.id)
    assert Card.subcard_progress(card) == {1, 2}
    assert Enum.map(card.sub_board.cards, & &1.title) == ["Part 1", "Part 2"]
    {:ok, nested} = Boards.create_sub_board(s1, t)
    assert nested.root_id == board.id
    assert length(Boards.ancestry(Boards.get_board!(nested.id))) == 2

    # Only root boards are listed; the sub-board is found by id, roots win by name.
    assert Enum.map(Boards.list_boards(), & &1.id) |> Enum.member?(board.id)
    refute Enum.map(Boards.list_boards(), & &1.id) |> Enum.member?(sub.id)
    {:ok, dup} = Boards.create_board(%{"name" => "Epic"}, owner_id: user_fixture().id)
    assert {:ok, %Board{id: dup_id}} = Boards.find_board("epic")
    assert dup_id == dup.id

    # Renaming the card renames its board.
    {:ok, _} = Boards.update_card(card, %{"title" => "Big epic"})
    assert Boards.get_board!(sub.id).name == "Big epic"

    # Removing the sub-board (or deleting the card) removes everything beneath.
    {:ok, card} = Boards.delete_sub_board(Boards.get_card!(card.id))
    assert is_nil(card.sub_board)
    assert is_nil(Boards.get_board(sub.id)) and is_nil(Boards.get_board(nested.id))
    assert {:error, "This card has no subcards."} = Boards.delete_sub_board(card)

    {:ok, sub} = Boards.create_sub_board(card, t)
    {:ok, _} = Boards.delete_card(card)
    assert is_nil(Boards.get_board(sub.id))
  end
end
