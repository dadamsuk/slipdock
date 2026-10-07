defmodule Slipdock.HotPathsTest do
  @moduledoc """
  The batched versions of things that used to run per row — permission checks
  over a list of cards, quota counts over a list of people, the cycle check on
  dependencies — must answer exactly what the one-at-a-time versions do. And an
  import must leave what writing by hand leaves: revisions and backlinks.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Portable, Quota, Wiki}
  alias Slipdock.Wiki.Links

  describe "Access.filter_readable_cards/2" do
    test "keeps exactly the cards card_permission/2 lets the reader read" do
      owner = user_fixture("owner@example.com")
      reader = user_fixture("reader@example.com")

      shared = board_fixture(%{}, owner: owner) |> share_fixture(reader, "read")
      private = board_fixture(%{}, owner: owner)
      own = board_fixture(%{}, owner: reader)

      on_shared = card_fixture(hd(shared.columns), %{"title" => "shared"})
      granted = card_fixture(hd(private.columns), %{"title" => "granted"})
      hidden = card_fixture(hd(private.columns), %{"title" => "hidden"})
      mine = card_fixture(hd(own.columns), %{"title" => "mine"})
      {:ok, _} = Access.grant(granted, reader, "read", owner)

      cards = Enum.map([hidden, mine, on_shared, granted], &Boards.get_card!(&1.id))
      expected = Enum.filter(cards, &Access.can_read?(Access.card_permission(reader, &1)))

      assert Access.filter_readable_cards(reader, cards) == expected
      assert Enum.map(expected, & &1.title) == ["mine", "shared", "granted"]
      assert Access.filter_readable_cards(nil, cards) == []
    end
  end

  describe "Quota.usage/1" do
    test "counts what used/2 counts, for everybody at once" do
      alice = user_fixture("alice@example.com")
      bob = user_fixture("bob@example.com")
      nobody = user_fixture("nobody@example.com")

      board = board_fixture(%{}, owner: alice)
      card = card_fixture(hd(board.columns))
      card_fixture(hd(board.columns))
      template = Boards.list_templates() |> Enum.find(&(&1.name == "Simple"))
      {:ok, sub} = Boards.create_sub_board(card, template)
      card_fixture(hd(Boards.get_board!(sub.id).columns))
      Wiki.create_page(board, %{"title" => "Notes"}, user: alice)
      board_fixture(%{}, owner: bob)

      usage = Quota.usage([alice.id, bob.id, nobody.id])

      for user <- [alice, bob, nobody] do
        assert usage[user.id] == %{
                 items: Quota.used(user, :items),
                 cards: Quota.used(user, :cards),
                 pages: Quota.used(user, :pages),
                 files: Quota.used(user, :files),
                 boards: Quota.used(user, :boards),
                 storage: Quota.used(user, :storage)
               }

        assert Quota.report(user, usage[user.id]) == Quota.report(user)
      end

      assert usage[alice.id].cards == 3
      assert usage[nobody.id].items == 0
    end
  end

  test "a dependency that would close a cycle through a diamond is refused" do
    board = board_fixture()
    [a, b, c, d] = for t <- ~w(A B C D), do: card_fixture(hd(board.columns), %{"title" => t})

    # d blocks b and c, which both block a.
    {:ok, _} = Boards.add_dependency(a, b)
    {:ok, _} = Boards.add_dependency(a, c)
    {:ok, _} = Boards.add_dependency(b, d)
    {:ok, _} = Boards.add_dependency(c, d)

    assert {:error, msg} = Boards.add_dependency(d, a)
    assert msg =~ "circular"
    assert {:ok, _} = Boards.add_dependency(d, card_fixture(hd(board.columns)))
  end

  test "imported pages have a first revision, and their links show as backlinks" do
    owner = user_fixture("owner@example.com")
    importer = user_fixture("importer@example.com")

    board = board_fixture(%{"name" => "Docs"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Points at the doc"})
    {:ok, _} = Boards.add_comment(card, "see [[Target]]")
    {:ok, _} = Wiki.create_page(board, %{"title" => "Target", "body" => "here"}, user: owner)

    {:ok, _} =
      Wiki.create_page(board, %{"title" => "Source", "body" => "[[Target]]"}, user: owner)

    {:ok, report} = Portable.import(importer, owner |> Portable.export() |> Jason.encode!())
    refute Map.has_key?(report, :card_ids)

    copy = Boards.get_board!(hd(report.boards).id)
    {:ok, target} = Wiki.find_page(copy, "Target")
    {:ok, source} = Wiki.find_page(copy, "Source")

    assert [%{author_id: author}] = Wiki.list_revisions(source)
    assert author == importer.id

    backlinks = Links.backlinks(target)
    assert Enum.any?(backlinks, &(&1.page_id == source.id))
    assert Enum.any?(backlinks, &(&1.source_comment_id != nil))
  end
end
