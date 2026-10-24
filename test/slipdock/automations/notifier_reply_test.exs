defmodule Slipdock.Automations.NotifierReplyTest do
  @moduledoc """
  Emails about a card carry a reply address and thread per card (#1257):
  `Notifier.deliver/4` with `card:`, and the callers that pass one.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Automations, Boards, TestConfig}
  alias Slipdock.Automations.Notifier
  alias Slipdock.Inbound.ReplyToken

  @domain "in.example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    colleague = user_fixture("colleague@example.com")
    share_fixture(board, colleague, "comment")
    card = card_fixture(hd(board.columns), %{"title" => "Fix the gate"})
    %{owner: owner, board: board, colleague: colleague, card: card}
  end

  defp token_of({_, "reply-" <> rest}), do: rest |> String.split("@") |> hd()

  test "one copy per recipient, each with its own signed Reply-To, thread and footer", ctx do
    assert :ok =
             Notifier.deliver([ctx.owner.email, ctx.colleague.email], "S", "Body", card: ctx.card)

    for person <- [ctx.owner, ctx.colleague] do
      assert_email_sent(fn email ->
        assert email.to == [{"", person.email}]
        assert {:ok, card, user} = ReplyToken.verify(token_of(email.reply_to))
        assert {card.id, user.id} == {ctx.card.id, person.id}

        root = "<card-#{ctx.card.id}@#{@domain}>"
        assert email.headers["In-Reply-To"] == root
        assert email.headers["References"] == root
        assert email.headers["Message-ID"] =~ ~r/^<card-#{ctx.card.id}\.\d+\.\d+@#{@domain}>$/
        assert email.text_body =~ ~r/Body\n\n-- \nReply to this email to comment on the card.\n$/
      end)
    end
  end

  test "every copy gets a Message-ID of its own", ctx do
    {h1, _} = Notifier.reply_headers(ctx.card, ctx.owner.email)
    {h2, _} = Notifier.reply_headers(ctx.card, ctx.owner.email)
    refute List.keyfind(h1, "Message-ID", 0) == List.keyfind(h2, "Message-ID", 0)
  end

  test "an address with no account, or one that can't comment, threads but gets no Reply-To",
       ctx do
    reader = user_fixture("reader@example.com")
    share_fixture(ctx.board, reader, "read")

    for address <- ["nobody@example.com", reader.email] do
      {headers, footer} = Notifier.reply_headers(ctx.card, address)
      assert footer == nil
      refute List.keyfind(headers, "Reply-To", 0)
      assert List.keyfind(headers, "References", 0)
    end

    assert :ok = Notifier.deliver(["nobody@example.com"], "S", "Body", card: ctx.card)

    assert_email_sent(fn email ->
      assert email.reply_to == nil
      assert email.text_body == "Body"
    end)
  end

  test "footer: replaces the line", ctx do
    assert :ok =
             Notifier.deliver([ctx.owner.email], "S", "B", card: ctx.card, footer: "Answer me.")

    assert_email_sent(fn email -> assert email.text_body =~ "-- \nAnswer me.\n" end)
  end

  test "with inbound mail off, or no card, it is one plain email as before", ctx do
    assert :ok = Notifier.deliver([ctx.owner.email, ctx.colleague.email], "S", "B")

    assert_email_sent(fn email ->
      assert length(email.to) == 2
      assert email.reply_to == nil
      assert email.headers == %{}
    end)

    TestConfig.put(:inbound, domain: nil, secrets: [])
    assert :ok = Notifier.deliver([ctx.owner.email], "S", "B", card: ctx.card)
    assert_email_sent(fn email -> assert email.reply_to == nil and email.text_body == "B" end)
  end

  test "a page passed as card: gets no reply address", ctx do
    page = page_fixture(ctx.board)
    assert :ok = Notifier.deliver([ctx.owner.email], "S", "B", card: page)
    assert_email_sent(fn email -> assert email.reply_to == nil end)
  end

  test "invalid recipients are still refused" do
    assert {:error, "no recipient"} = Notifier.deliver([], "S", "B", card: nil)
    assert {:error, "no valid recipient in nope"} = Notifier.deliver(["nope"], "S", "B")
  end

  describe "the callers" do
    test "a mention email can be replied to", ctx do
      {:ok, _} = Boards.add_comment(ctx.card, "@colleague have a look", by: ctx.owner)

      assert_email_sent(fn email ->
        assert email.subject =~ "mentioned you"
        assert {:ok, _, user} = ReplyToken.verify(token_of(email.reply_to))
        assert user.id == ctx.colleague.id
      end)
    end

    test "an automation's email on a card can be replied to", ctx do
      {:ok, _} =
        Automations.create_rule(%{
          "name" => "Tell them",
          "board_id" => ctx.board.id,
          "spec" => %{
            "trigger" => %{"type" => "card_created"},
            "actions" => [%{"type" => "email", "to" => ctx.colleague.email}]
          }
        })

      card_fixture(hd(ctx.board.columns), %{"title" => "New one"})

      assert_email_sent(fn email ->
        assert email.to == [{"", ctx.colleague.email}]
        assert {:ok, card, _} = ReplyToken.verify(token_of(email.reply_to))
        assert card.title == "New one"
      end)
    end

    test "notify_assignee can be replied to", ctx do
      {:ok, _} =
        Automations.create_rule(%{
          "name" => "Ping",
          "board_id" => ctx.board.id,
          "spec" => %{
            "trigger" => %{"type" => "card_created"},
            "actions" => [%{"type" => "notify_assignee"}]
          }
        })

      card_fixture(hd(ctx.board.columns), %{
        "title" => "Assigned",
        "assignee_id" => ctx.owner.id
      })

      assert_email_sent(fn email ->
        assert {:ok, card, user} = ReplyToken.verify(token_of(email.reply_to))
        assert {card.title, user.id} == {"Assigned", ctx.owner.id}
      end)
    end
  end
end
