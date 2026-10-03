defmodule Slipdock.QuotaTest do
  @moduledoc """
  The free tier's allowance: whose things count, and that every way of making
  one is refused the same. The server-wide ceilings and the trial are in
  `Slipdock.QuotaLimitsTest`; this file turns them off so that the free tier is
  the only thing being measured.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Quota, Settings}

  defp limit(n) do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => n})

    :ok
  end

  # The ceilings are on by default on every install (see `Slipdock.Quota`), and
  # a 250,000-item one would make "no limit" tests read as limited.
  setup do
    {:ok, _} =
      Settings.update(%{
        "board_limit_enabled" => false,
        "item_limit_enabled" => false,
        "storage_limit_enabled" => false
      })

    :ok
  end

  setup do
    alice = user_fixture("alice@example.com")
    board = board_fixture(%{"name" => "Alice's"}, owner: alice)
    %{alice: alice, board: board, column: hd(board.columns)}
  end

  describe "with no limit set" do
    test "the whole mechanism is inert, which is what a self-hosted install wants", %{
      alice: alice,
      column: column
    } do
      assert Quota.limit(alice) == nil
      assert Quota.check(alice) == :ok

      for n <- 1..30, do: {:ok, _} = Boards.create_card(column, %{"title" => "Card #{n}"})
      assert Quota.used(alice) == 30
      assert Quota.check(alice) == :ok
    end
  end

  describe "counting" do
    setup do: limit(5)

    test "cards on boards you own count against you", %{alice: alice, column: column} do
      {:ok, _} = Boards.create_card(column, %{"title" => "One"})
      assert Quota.used(alice) == 1
    end

    test "cards on somebody else's board do not", %{alice: alice} do
      bob = user_fixture("bob@example.com")
      their_board = board_fixture(%{"name" => "Bob's"}, owner: bob)
      {:ok, _} = Boards.create_card(hd(their_board.columns), %{"title" => "Theirs"})

      assert Quota.used(alice) == 0
      assert Quota.used(bob) == 1
    end

    test "a sub-board counts against whoever owns the top of the tree", %{
      alice: alice,
      column: column
    } do
      {:ok, card} = Boards.create_card(column, %{"title" => "Epic"})
      template = hd(Boards.list_templates())
      {:ok, sub} = Boards.create_sub_board(card, template)
      {:ok, _} = Boards.create_card(hd(Boards.get_board!(sub.id).columns), %{"title" => "Task"})

      assert Quota.used(alice) == 2
    end

    test "archiving frees quota, which is the deliberate escape hatch", %{
      alice: alice,
      column: column
    } do
      {:ok, card} = Boards.create_card(column, %{"title" => "One"})
      assert Quota.used(alice) == 1

      {:ok, _} = Boards.archive_card(card)
      assert Quota.used(alice) == 0
    end
  end

  describe "the wall" do
    setup do: limit(2)

    test "the board's owner is who is counted, not the card's creator", %{
      alice: alice,
      board: board,
      column: column
    } do
      guest = user_fixture("guest@example.com")
      {:ok, _} = Access.grant(board, guest, "write", alice)

      {:ok, _} = Boards.create_card(column, %{"title" => "One"})
      {:ok, _} = Boards.create_card(column, %{"title" => "Two"})

      # The guest has no cards of their own, but this board is full — because
      # Alice is the one who would be billed for it.
      assert Quota.used(guest) == 0
      assert {:error, changeset} = Boards.create_card(column, %{"title" => "Three"})
      assert Quota.limit_reached?(changeset)
    end

    test "a guest is not capped on their own board by somebody else's full one", %{
      alice: alice,
      column: column
    } do
      guest = user_fixture("guest@example.com")
      {:ok, _} = Boards.create_card(column, %{"title" => "One"})
      {:ok, _} = Boards.create_card(column, %{"title" => "Two"})

      theirs = board_fixture(%{"name" => "Guest's"}, owner: guest)
      assert {:ok, _} = Boards.create_card(hd(theirs.columns), %{"title" => "Mine"})
      assert Quota.used(alice) == 2
    end

    test "the message says what to do about it", %{column: column} do
      {:ok, _} = Boards.create_card(column, %{"title" => "One"})
      {:ok, _} = Boards.create_card(column, %{"title" => "Two"})
      {:error, changeset} = Boards.create_card(column, %{"title" => "Three"})

      assert %{base: [message]} = errors_on(changeset)
      assert message =~ "archive"
      assert message =~ "subscribe"
    end

    test "archiving one lets the next one through", %{column: column} do
      {:ok, _} = Boards.create_card(column, %{"title" => "One"})
      {:ok, card} = Boards.create_card(column, %{"title" => "Two"})
      assert {:error, _} = Boards.create_card(column, %{"title" => "Three"})

      {:ok, _} = Boards.archive_card(card)
      assert {:ok, _} = Boards.create_card(column, %{"title" => "Three"})
    end
  end

  describe "exemptions" do
    setup do: limit(1)

    test "admins are never capped", %{alice: alice, column: column} do
      {:ok, _} = Boards.create_card(column, %{"title" => "One"})
      assert {:error, _} = Boards.create_card(column, %{"title" => "Two"})

      {:ok, _} = Accounts.promote(alice)
      # Somebody has to be able to fix a server that has filled up.
      assert {:ok, _} = Boards.create_card(column, %{"title" => "Two"})
    end

    test "a per-person override beats the instance's limit", %{alice: alice, column: column} do
      {:ok, _} = Accounts.update_standing(alice, %{"card_limit_override" => 3})

      for n <- 1..3, do: {:ok, _} = Boards.create_card(column, %{"title" => "Card #{n}"})
      assert {:error, _} = Boards.create_card(column, %{"title" => "Four"})
    end
  end

  describe "status and warning" do
    setup do: limit(10)

    test "says where somebody stands", %{alice: alice, column: column} do
      for n <- 1..4, do: {:ok, _} = Boards.create_card(column, %{"title" => "Card #{n}"})

      assert %{used: 4, limit: 10, remaining: 6, limited?: true} = Quota.status(alice)
      refute Quota.warning?(alice)
    end

    test "warns before the wall, not at it", %{alice: alice, column: column} do
      for n <- 1..8, do: {:ok, _} = Boards.create_card(column, %{"title" => "Card #{n}"})
      assert Quota.warning?(alice)
    end

    test "an uncapped person is never warned", %{alice: alice} do
      {:ok, _} = Settings.update(%{"free_card_limit" => nil})
      refute Quota.warning?(alice)
      assert %{limited?: false} = Quota.status(alice)
    end
  end
end
