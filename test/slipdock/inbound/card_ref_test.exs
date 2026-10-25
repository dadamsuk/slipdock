defmodule Slipdock.Inbound.CardRefTest do
  @moduledoc """
  `[#42] …` to a board's card address (#1272): the mail is a comment on card
  42 rather than a new card, end to end through
  `Slipdock.Inbound.receive_message/1`, when the card is on that board or a
  sub-board beneath it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Inbound, Repo, TestConfig}
  alias Slipdock.Boards.{Attachment, Card, Comment}
  alias Slipdock.Inbound.{Cards, Tokens}

  @domain "in.example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    TestConfig.own_uploads_dir()
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Fix the gate"})
    {:ok, address} = Tokens.address(user, board, :card)
    %{user: user, board: board, card: card, address: address}
  end

  defp mail(from, to, subject, body, attachment) do
    head =
      "ARC-Authentication-Results: i=1; mx.cloudflare.net; dmarc=pass header.from=example.com\r\n" <>
        "From: Sender <#{from}>\r\nTo: #{to}\r\nSubject: #{subject}\r\n" <>
        "Message-ID: <#{System.unique_integer([:positive])}@example.com>\r\nMIME-Version: 1.0\r\n"

    case attachment do
      nil ->
        head <> "Content-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n"

      {name, data} ->
        head <>
          "Content-Type: multipart/mixed; boundary=b\r\n\r\n" <>
          "--b\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n" <>
          "--b\r\nContent-Type: text/plain; name=#{name}\r\n" <>
          "Content-Disposition: attachment; filename=#{name}\r\n\r\n#{data}\r\n--b--\r\n"
    end
  end

  defp send_to(ctx, subject, body, opts \\ []) do
    Inbound.receive_message(%{
      raw: mail(opts[:from] || ctx.user.email, ctx.address, subject, body, opts[:attachment]),
      envelope_to: ctx.address,
      envelope_from: nil
    })
  end

  defp comments(card),
    do: Repo.all(from(c in Comment, where: c.card_id == ^card.id, order_by: c.id))

  defp cards, do: Repo.aggregate(Card, :count)

  describe "card_ref/1" do
    test "a leading [#id], after any Re: or Fwd:" do
      assert Cards.card_ref("[#42] Done") == 42
      assert Cards.card_ref("[ #42 ] Done") == 42
      assert Cards.card_ref("  [#42]") == 42
      assert Cards.card_ref("Re: [#42] Done") == 42
      assert Cards.card_ref("Fwd: RE: [#7] Invoice") == 7
    end

    test "anything else is a title" do
      assert Cards.card_ref("Invoice #1234") == nil
      assert Cards.card_ref("About [#42]") == nil
      assert Cards.card_ref("[42] Done") == nil
      assert Cards.card_ref("[#] Done") == nil
      assert Cards.card_ref("[#4x] Done") == nil
      assert Cards.card_ref("[Website] Renew") == nil
      assert Cards.card_ref("") == nil
      assert Cards.card_ref(nil) == nil
    end

    test "an id too long for a card is not a reference" do
      assert Cards.card_ref("[#" <> String.duplicate("9", 19) <> "] x") == nil
      assert Cards.card_ref("[#" <> String.duplicate("9", 18) <> "] x") == 999_999_999_999_999_999
    end
  end

  describe "[#id] to the card address" do
    test "is a comment on that card, by the sender, and makes no card", ctx do
      before = cards()
      assert {:accepted, email} = send_to(ctx, "[##{ctx.card.id}] Fixed", "Hinge replaced.")

      [comment] = comments(ctx.card)
      assert comment.body == "Hinge replaced."
      assert comment.user_id == ctx.user.id
      assert email.comment_id == comment.id
      assert email.kind == "card"
      assert is_nil(email.card_id)
      assert cards() == before
    end

    test "quoted history and the signature are taken off", ctx do
      body = "Done.\r\n\r\n-- \r\nSender\r\n\r\nOn Mon, someone wrote:\r\n> the old text"
      assert {:accepted, _} = send_to(ctx, "Re: [##{ctx.card.id}] Fixed", body)
      assert [%Comment{body: "Done."}] = comments(ctx.card)
    end

    test "files go on the card, linked from the comment", ctx do
      assert {:accepted, _} =
               send_to(ctx, "[##{ctx.card.id}] Photo", "Here.", attachment: {"note.txt", "hi"})

      assert [%Attachment{filename: "note.txt"}] =
               Repo.all(from(a in Attachment, where: a.card_id == ^ctx.card.id))

      [comment] = comments(ctx.card)
      assert comment.body =~ "Here."
      assert comment.body =~ "[note.txt]("
    end

    test "a card on a sub-board beneath the board", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.card, t)
      sub = Boards.get_board!(sub.id)
      task = card_fixture(hd(sub.columns), %{"title" => "Hinge"})

      assert {:accepted, _} = send_to(ctx, "[##{task.id}] Ordered", "Arrives Tuesday.")
      assert [%Comment{body: "Arrives Tuesday."}] = comments(task)
    end

    test "answers the card's wait on the sender", ctx do
      {:ok, _} =
        Boards.open_wait(ctx.card, Actor.web(ctx.user), %{
          needs: "Which hinge?",
          on_user_id: ctx.user.id
        })

      assert {:accepted, _} = send_to(ctx, "[##{ctx.card.id}] Hinge", "The brass one.")
      assert Boards.current_wait(Repo.reload!(ctx.card)) == nil
    end

    test "#id elsewhere in the subject still makes a new card", ctx do
      before = cards()
      assert {:accepted, email} = send_to(ctx, "Invoice ##{ctx.card.id}", "Pay it.")
      assert email.card_id
      assert cards() == before + 1
      assert comments(ctx.card) == []
    end
  end

  describe "[#id] bounces" do
    test "for a card on another board, saying no more than for none at all", ctx do
      other = board_fixture(%{"name" => "Secret plans"}, owner: user_fixture("o@example.com"))
      theirs = card_fixture(hd(other.columns), %{"title" => "Hidden"})

      assert {:rejected, reason, _} = send_to(ctx, "[##{theirs.id}] Hi", "x")
      assert reason == "Card ##{theirs.id} isn't on this board."
      assert comments(theirs) == []

      assert {:rejected, "Card #999999999 isn't on this board.", _} =
               send_to(ctx, "[#999999999] Hi", "x")
    end

    test "for a card on the board above, from a sub-board's address", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.card, t)
      {:ok, sub_address} = Tokens.address(ctx.user, Boards.get_board!(sub.id), :card)

      assert {:rejected, reason, _} =
               send_to(%{ctx | address: sub_address}, "[##{ctx.card.id}] Up", "x")

      assert reason == "Card ##{ctx.card.id} isn't on this board."
    end

    test "for an archived card", ctx do
      {:ok, _} = Boards.archive_card(ctx.card)
      assert {:rejected, reason, _} = send_to(ctx, "[##{ctx.card.id}] Late", "x")
      assert reason =~ "is archived"
      assert comments(ctx.card) == []
    end

    test "with nothing to add", ctx do
      assert {:rejected, reason, _} = send_to(ctx, "[##{ctx.card.id}] Empty", "")
      assert reason =~ "nothing to add"
      assert comments(ctx.card) == []
    end

    test "from somebody else, before the card is looked at", ctx do
      assert {:rejected, reason, _} =
               send_to(ctx, "[##{ctx.card.id}] Hi", "x", from: "intruder@example.com")

      assert reason =~ "has to come from the address of the account"
      assert comments(ctx.card) == []
    end
  end
end
