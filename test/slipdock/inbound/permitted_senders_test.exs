defmodule Slipdock.Inbound.PermittedSendersTest do
  @moduledoc """
  A board's permitted senders (#1289): other addresses its card addresses
  take mail from, as the address's owner, saying who sent it. Set on the
  board, checked by `Slipdock.Inbound.Trust`, end to end through
  `Slipdock.Inbound.receive_message/1`.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Inbound, Repo, TestConfig}
  alias Slipdock.Boards.{Board, Card, Comment}
  alias Slipdock.Inbound.{Message, Tokens, Trust}

  @domain "in.example.com"
  @pass "i=1; mx.cloudflare.net; dmarc=pass header.from=example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Fix the gate"})

    {:ok, board} =
      Boards.update_board(board, %{"inbound_senders" => "Ann@Example.com, bob@example.com"})

    {:ok, address} = Tokens.address(user, board, :card)
    %{user: user, board: board, card: card, address: address}
  end

  describe "the board's list" do
    test "a string splits on commas, semicolons and whitespace, lower-cased, each once", ctx do
      assert ctx.board.inbound_senders == ["ann@example.com", "bob@example.com"]

      {:ok, board} =
        Boards.update_board(ctx.board, %{
          "inbound_senders" => " c@example.com;\n D@example.com  c@example.com\r\n"
        })

      assert board.inbound_senders == ["c@example.com", "d@example.com"]
    end

    test "a list is taken as it is, and \"\" or [] clears it", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{inbound_senders: ["E@example.com", ""]})
      assert board.inbound_senders == ["e@example.com"]

      {:ok, board} = Boards.update_board(board, %{"inbound_senders" => ""})
      assert board.inbound_senders == []

      {:ok, board} = Boards.update_board(ctx.board, %{"inbound_senders" => []})
      assert board.inbound_senders == []
    end

    test "left alone when not given", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"name" => "Renamed"})
      assert board.inbound_senders == ["ann@example.com", "bob@example.com"]
    end

    test "refuses what isn't an address, naming it, and keeps the old list", ctx do
      assert {:error, cs} =
               Boards.update_board(ctx.board, %{"inbound_senders" => "ok@example.com, nope"})

      assert %{inbound_senders: ["aren't email addresses: nope"]} = errors_on(cs)

      assert Boards.get_board!(ctx.board.id).inbound_senders == [
               "ann@example.com",
               "bob@example.com"
             ]
    end

    test "at most the limit", ctx do
      many = fn n -> Enum.map_join(1..n, ",", &"p#{&1}@example.com") end
      limit = Board.inbound_senders_limit()

      assert {:error, cs} =
               Boards.update_board(ctx.board, %{"inbound_senders" => many.(limit + 1)})

      assert %{inbound_senders: ["can be at most 50 addresses"]} = errors_on(cs)
      assert {:ok, _} = Boards.update_board(ctx.board, %{"inbound_senders" => many.(limit)})
    end

    test "permitted_sender?/2 compares in any case", ctx do
      assert Board.permitted_sender?(ctx.board, " ANN@example.com")
      refute Board.permitted_sender?(ctx.board, "carol@example.com")
      refute Board.permitted_sender?(ctx.board, nil)
      refute Board.permitted_sender?(%Board{inbound_senders: []}, "ann@example.com")
    end
  end

  describe "Trust.check/3" do
    defp message(from, auth \\ [{"arc-authentication-results", @pass}]),
      do: %Message{from: from, authentication_results: auth}

    test "a listed sender may mail the board's card addresses", ctx do
      assert Trust.check(message("ann@example.com"), ctx.user, {:cards, ctx.board}) == :ok
      assert Trust.check(message(ctx.user.email), ctx.user, {:cards, ctx.board}) == :ok
    end

    test "but not its page addresses, nor a card's reply address", ctx do
      assert {:reject, "Mail to this address has to come from the address of the account" <> rest} =
               Trust.check(message("ann@example.com"), ctx.user, {:board, ctx.board})

      refute rest =~ "allowed"

      assert {:reject, _} = Trust.check(message("ann@example.com"), ctx.user, {:card, ctx.card})
    end

    test "anybody else is told the board's owner can allow them", ctx do
      assert {:reject, reason} =
               Trust.check(message("carol@example.com"), ctx.user, {:cards, ctx.board})

      assert reason =~ "or from one the board's owner has allowed"
    end

    test "a listed sender still has to pass DMARC or DKIM", ctx do
      assert {:reject, "We couldn't confirm" <> _} =
               Trust.check(message("ann@example.com", []), ctx.user, {:cards, ctx.board})
    end

    test "and the address's owner still has to be able to write to the board", ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")

      assert {:reject, "You can no longer add to this board."} =
               Trust.check(message("ann@example.com"), reader, {:cards, ctx.board})
    end
  end

  defp mail(from, to, subject, body) do
    "ARC-Authentication-Results: #{@pass}\r\n" <>
      "From: Ann Smith <#{from}>\r\nTo: #{to}\r\nSubject: #{subject}\r\n" <>
      "Message-ID: <#{System.unique_integer([:positive])}@example.com>\r\nMIME-Version: 1.0\r\n" <>
      "Content-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n"
  end

  defp send_to(address, from, subject, body) do
    Inbound.receive_message(%{
      raw: mail(from, address, subject, body),
      envelope_to: address,
      envelope_from: nil
    })
  end

  defp comments(card),
    do: Repo.all(from(c in Comment, where: c.card_id == ^card.id, order_by: c.id))

  describe "mail from a permitted sender" do
    test "makes a card as the address's owner, saying who sent it", ctx do
      assert {:accepted, email} = send_to(ctx.address, "ann@example.com", "Gate", "It sticks.")

      card = Repo.get!(Card, email.card_id)
      assert card.title == "Gate"
      assert card.description == "*Sent by Ann Smith <ann@example.com>.*\n\nIt sticks."
      assert email.user_id == ctx.user.id
    end

    test "the owner's own mail says nothing about who sent it", ctx do
      assert {:accepted, email} = send_to(ctx.address, ctx.user.email, "Gate", "It sticks.")
      assert Repo.get!(Card, email.card_id).description == "It sticks."
    end

    test "[#id] comments on the card, saying who sent it", ctx do
      assert {:accepted, _} =
               send_to(ctx.address, "ann@example.com", "[##{ctx.card.id}] Fixed", "Done.")

      assert [%Comment{body: body, user_id: user_id}] = comments(ctx.card)
      assert body == "*Sent by Ann Smith <ann@example.com>.*\n\nDone."
      assert user_id == ctx.user.id
    end

    test "never answers a wait on the address's owner", ctx do
      {:ok, _} =
        Boards.open_wait(ctx.card, Actor.web(ctx.user), %{
          needs: "Which hinge?",
          on_user_id: ctx.user.id
        })

      assert {:accepted, _} =
               send_to(ctx.address, "ann@example.com", "[##{ctx.card.id}] Hinge", "Brass.")

      assert Boards.current_wait(Repo.reload!(ctx.card))

      assert %Comment{body: "*Sent by Ann Smith <ann@example.com>.*\n\nBrass."} =
               List.last(comments(ctx.card))
    end

    test "to the board's page address bounces", ctx do
      {:ok, page} = Tokens.address(ctx.user, ctx.board, :page)

      assert {:rejected, reason, _email} = send_to(page, "ann@example.com", "Notes", "Hello.")
      assert reason =~ "has to come from the address of the account"
    end

    test "after it is taken off the list bounces", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"inbound_senders" => "bob@example.com"})

      assert {:rejected, reason, _email} =
               send_to(ctx.address, "ann@example.com", "Gate", "It sticks.")

      assert reason =~ "one the board's owner has allowed"
    end

    test "is only for that board", ctx do
      other = board_fixture(%{}, owner: ctx.user)
      {:ok, address} = Tokens.address(ctx.user, other, :card)

      assert {:rejected, _, _} = send_to(address, "ann@example.com", "Gate", "It sticks.")
    end
  end
end
