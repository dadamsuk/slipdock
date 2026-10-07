defmodule Slipdock.VisibleUsersTest do
  @moduledoc """
  Who each person may see. The point of `shared_only` is that two customers
  sharing one server never learn of each other, so most of these are about what
  is *not* in the list.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Settings}

  defp directory(mode) do
    {:ok, _} = Settings.update(%{"user_directory" => mode})
    :ok
  end

  defp emails(users), do: users |> Enum.map(& &1.email) |> Enum.sort()

  setup do
    alice = user_fixture("alice@example.com")
    bob = user_fixture("bob@example.com")
    stranger = user_fixture("stranger@example.com")
    board = board_fixture(%{"name" => "Alice's board"}, owner: alice)
    %{alice: alice, bob: bob, stranger: stranger, board: board}
  end

  describe "instance mode" do
    test "shows everybody, as it always did", %{alice: alice} do
      directory(:instance)

      assert emails(Access.visible_users(alice)) ==
               [
                 fixture_email("alice@example.com"),
                 fixture_email("bob@example.com"),
                 fixture_email("stranger@example.com")
               ]
    end
  end

  describe "shared_only mode" do
    setup do
      directory(:shared_only)
      :ok
    end

    test "on your own, you see only yourself", %{alice: alice} do
      assert emails(Access.visible_users(alice)) == [fixture_email("alice@example.com")]
    end

    test "sharing a board makes the two of you visible to each other", %{
      alice: alice,
      bob: bob,
      stranger: stranger,
      board: board
    } do
      {:ok, _} = Access.grant(board, bob, "read", alice)

      assert emails(Access.visible_users(alice)) == [
               fixture_email("alice@example.com"),
               fixture_email("bob@example.com")
             ]

      assert emails(Access.visible_users(bob)) == [
               fixture_email("alice@example.com"),
               fixture_email("bob@example.com")
             ]

      # And the person who shares nothing with either of them sees neither.
      assert emails(Access.visible_users(stranger)) == [fixture_email("stranger@example.com")]
    end

    test "two guests on one board can see each other", %{
      alice: alice,
      bob: bob,
      stranger: stranger,
      board: board
    } do
      {:ok, _} = Access.grant(board, bob, "read", alice)
      {:ok, _} = Access.grant(board, stranger, "read", alice)

      # They share a board, so they are colleagues as far as this is concerned.
      assert fixture_email("stranger@example.com") in emails(Access.visible_users(bob))
    end

    test "revoking takes it away again", %{alice: alice, bob: bob, board: board} do
      {:ok, grant} = Access.grant(board, bob, "read", alice)
      assert length(Access.visible_users(alice)) == 2

      {:ok, _} = Access.revoke(grant)
      assert emails(Access.visible_users(alice)) == [fixture_email("alice@example.com")]
      assert emails(Access.visible_users(bob)) == [fixture_email("bob@example.com")]
    end

    test "a card shared on its own is enough", %{alice: alice, bob: bob, board: board} do
      card = card_fixture(hd(board.columns), %{"title" => "Just this one"})
      {:ok, _} = Access.grant(card, bob, "read", alice)

      assert fixture_email("bob@example.com") in emails(Access.visible_users(alice))
      assert fixture_email("alice@example.com") in emails(Access.visible_users(bob))
    end

    test "a group puts everybody in it in the same room", %{
      alice: alice,
      bob: bob,
      stranger: stranger
    } do
      {:ok, group} = Accounts.create_group(alice, %{"name" => "The team"})
      {:ok, _} = Accounts.add_group_member(group, bob.email)

      assert emails(Access.visible_users(alice)) == [
               fixture_email("alice@example.com"),
               fixture_email("bob@example.com")
             ]

      assert emails(Access.visible_users(bob)) == [
               fixture_email("alice@example.com"),
               fixture_email("bob@example.com")
             ]

      assert emails(Access.visible_users(stranger)) == [fixture_email("stranger@example.com")]
    end

    test "nobody is visible to nobody" do
      assert Access.visible_users(nil) == []
    end

    test "you are always in your own list", %{stranger: stranger} do
      # A picker you cannot assign yourself in is broken.
      assert emails(Access.visible_users(stranger)) == [fixture_email("stranger@example.com")]
    end
  end
end
