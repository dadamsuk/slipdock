defmodule Slipdock.Inbound.TokensTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Repo, TestConfig}
  alias Slipdock.Inbound.{Token, Tokens}

  @domain "in.example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s3cret"])
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    %{user: user, board: board}
  end

  defp local(address), do: address |> String.split("@") |> hd()

  describe "address/3" do
    test "card and page addresses share one token for the board", %{user: user, board: board} do
      {:ok, card} = Tokens.address(user, board, :card)
      {:ok, page} = Tokens.address(user, board, :page)

      assert [_, token] = Regex.run(~r/^card-([a-z2-7]{26})@in\.example\.com$/, card)
      assert page == "page-#{token}@#{@domain}"
      assert String.length(local(card)) <= 64
    end

    test "asking again gives the same address, from one row", %{user: user, board: board} do
      {:ok, first} = Tokens.address(user, board, :card)
      {:ok, again} = Tokens.address(user, board, :card)

      assert first == again
      assert Repo.aggregate(from(t in Token, where: t.user_id == ^user.id), :count) == 1
    end

    test "the token is stored hashed and encrypted, never in plain", %{user: user, board: board} do
      {:ok, address} = Tokens.address(user, board, :card)
      "card-" <> token = local(address)
      row = Repo.get_by!(Token, user_id: user.id, board_id: board.id)

      assert row.token_hash == :crypto.hash(:sha256, token)
      refute row.token_encrypted =~ token
    end

    test "each person has their own token for a board", %{user: user, board: board} do
      other = user_fixture("other@example.com")
      share_fixture(board, other)

      {:ok, mine} = Tokens.address(user, board, :card)
      {:ok, theirs} = Tokens.address(other, board, :card)
      assert mine != theirs
    end

    test "the personal address is add-, with no board", %{user: user, board: board} do
      {:ok, add} = Tokens.address(user, nil, :add)
      {:ok, card} = Tokens.address(user, board, :card)

      assert add =~ ~r/^add-[a-z2-7]{26}@in\.example\.com$/

      assert local(add) |> String.trim_leading("add-") !=
               local(card) |> String.trim_leading("card-")
    end

    test "a reader gets no address for the board", %{board: board} do
      reader = user_fixture("reader@example.com")
      share_fixture(board, reader, "read")

      assert Tokens.address(reader, board, :card) == {:error, :forbidden}
      assert Repo.aggregate(Token, :count) == 0
    end

    test "kinds that don't fit the target are refused", %{user: user, board: board} do
      assert Tokens.address(user, board, :add) == {:error, :wrong_kind}
      assert Tokens.address(user, nil, :card) == {:error, :wrong_kind}
      assert Tokens.address(user, nil, :page) == {:error, :wrong_kind}
    end

    test "nothing while inbound is off", %{user: user, board: board} do
      TestConfig.put(:inbound, [])

      assert Tokens.address(user, board, :card) == {:error, :disabled}
      assert Tokens.address(user, nil, :add) == {:error, :disabled}
      assert Tokens.rotate(user, board) == {:error, :disabled}
    end

    test "a token that can no longer be decrypted is replaced", %{user: user, board: board} do
      {:ok, old} = Tokens.address(user, board, :card)

      Repo.update_all(from(t in Token, where: t.user_id == ^user.id),
        set: [token_encrypted: "garbage"]
      )

      {:ok, new} = Tokens.address(user, board, :card)
      assert new != old
      assert Tokens.resolve(local(old)) == {:error, :revoked}
      assert {:ok, {:card, _, _}} = Tokens.resolve(local(new))
    end
  end

  describe "addresses/2" do
    test "a board's card and page addresses, or the personal one", %{user: user, board: board} do
      assert {:ok, %{card: "card-" <> _, page: "page-" <> _}} = Tokens.addresses(user, board)
      assert {:ok, %{add: "add-" <> _} = personal} = Tokens.addresses(user, nil)
      assert map_size(personal) == 1
    end
  end

  describe "resolve/1" do
    test "a card, page or add address resolves to its person and board",
         %{user: user, board: board} do
      {:ok, card} = Tokens.address(user, board, :card)
      {:ok, page} = Tokens.address(user, board, :page)
      {:ok, add} = Tokens.address(user, nil, :add)

      assert {:ok, {:card, %{id: uid}, %{id: bid}}} = Tokens.resolve(local(card))
      assert {uid, bid} == {user.id, board.id}
      assert {:ok, {:page, %{id: ^uid}, %{id: ^bid}}} = Tokens.resolve(page)
      assert {:ok, {:add, %{id: ^uid}, nil}} = Tokens.resolve(local(add))
    end

    test "case and a +tag don't matter", %{user: user, board: board} do
      {:ok, card} = Tokens.address(user, board, :card)
      tagged = String.upcase(local(card)) <> "+invoices"

      assert {:ok, {:card, _, _}} = Tokens.resolve(tagged)
    end

    test "an unknown token, or no inbound address at all", %{} do
      assert Tokens.resolve("card-" <> String.duplicate("a", 26)) == {:error, :unknown}
      assert Tokens.resolve("hello") == {:error, :malformed}
      assert Tokens.resolve("reply-abc") == {:error, :malformed}
      assert Tokens.resolve("") == {:error, :malformed}
    end

    test "the wrong prefix for the token", %{user: user, board: board} do
      {:ok, card} = Tokens.address(user, board, :card)
      {:ok, add} = Tokens.address(user, nil, :add)

      assert Tokens.resolve(String.replace(local(card), "card-", "add-")) == {:error, :wrong_kind}
      assert Tokens.resolve(String.replace(local(add), "add-", "card-")) == {:error, :wrong_kind}
      assert Tokens.resolve(String.replace(local(add), "add-", "page-")) == {:error, :wrong_kind}
    end

    test "a disabled account's addresses stop working", %{board: board} do
      other = user_fixture("leaver@example.com")
      share_fixture(board, other)
      {:ok, card} = Tokens.address(other, board, :card)
      {:ok, _} = Accounts.disable(other)

      assert Tokens.resolve(local(card)) == {:error, :inactive}
    end

    test "an archived board's address bounces", %{user: user, board: board} do
      {:ok, card} = Tokens.address(user, board, :card)
      {:ok, _} = Boards.archive_board(board)

      assert Tokens.resolve(local(card)) == {:error, :archived}
    end
  end

  describe "rotate/2" do
    test "the old address stops resolving, the new one works", %{user: user, board: board} do
      {:ok, %{card: old_card, page: old_page}} = Tokens.addresses(user, board)
      {:ok, %{card: new_card, page: new_page}} = Tokens.rotate(user, board)

      assert new_card != old_card and new_page != old_page
      assert Tokens.resolve(local(old_card)) == {:error, :revoked}
      assert Tokens.resolve(local(old_page)) == {:error, :revoked}
      assert {:ok, {:card, _, _}} = Tokens.resolve(local(new_card))
      assert {:ok, ^new_card} = Tokens.address(user, board, :card)

      old = Repo.one!(from(t in Token, where: not is_nil(t.revoked_at)))
      assert old.rotated_at
    end

    test "rotating the personal address leaves board addresses alone",
         %{user: user, board: board} do
      {:ok, card} = Tokens.address(user, board, :card)
      {:ok, %{add: old}} = Tokens.addresses(user, nil)
      {:ok, %{add: new}} = Tokens.rotate(user, nil)

      assert new != old
      assert Tokens.resolve(local(old)) == {:error, :revoked}
      assert {:ok, {:card, _, _}} = Tokens.resolve(local(card))
    end

    test "rotating before any address exists just makes one", %{user: user, board: board} do
      assert {:ok, %{card: card}} = Tokens.rotate(user, board)
      assert {:ok, ^card} = Tokens.address(user, board, :card)
    end

    test "somebody who can't write the board can't rotate it", %{board: board} do
      reader = user_fixture("reader2@example.com")
      share_fixture(board, reader, "read")

      assert Tokens.rotate(reader, board) == {:error, :forbidden}
    end
  end

  describe "revoke/2" do
    test "the address stops working; asking again makes a new one",
         %{user: user, board: board} do
      {:ok, old} = Tokens.address(user, board, :card)
      assert Tokens.revoke(user, board) == :ok

      assert Tokens.resolve(local(old)) == {:error, :revoked}
      assert {:ok, new} = Tokens.address(user, board, :card)
      assert new != old
    end
  end

  describe "when the board goes, or the share does" do
    test "deleting the board deletes its tokens", %{user: user, board: board} do
      {:ok, card} = Tokens.address(user, board, :card)
      {:ok, _} = Tokens.address(user, nil, :add)
      {:ok, _} = Boards.delete_board(board)

      assert Tokens.resolve(local(card)) == {:error, :unknown}
      assert [%Token{board_id: nil}] = Repo.all(Token)
    end

    test "taking a share back revokes that person's token", %{user: user, board: board} do
      other = user_fixture("shared@example.com")
      share_fixture(board, other)
      {:ok, theirs} = Tokens.address(other, board, :card)
      {:ok, mine} = Tokens.address(user, board, :card)

      [grant] = Access.list_grants(board)
      {:ok, _} = Access.revoke(grant)

      assert Tokens.resolve(local(theirs)) == {:error, :revoked}
      assert {:ok, {:card, _, _}} = Tokens.resolve(local(mine))
    end

    test "write access lost some other way is caught when mail arrives",
         %{board: board} do
      other = user_fixture("downgraded@example.com")
      share_fixture(board, other)
      {:ok, theirs} = Tokens.address(other, board, :card)
      # Down to read, by granting again: no revoke, so nothing pruned yet.
      share_fixture(board, other, "read")

      assert Tokens.resolve(local(theirs)) == {:error, :forbidden}
      assert Tokens.resolve(local(theirs)) == {:error, :revoked}
    end
  end
end
