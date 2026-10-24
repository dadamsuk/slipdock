defmodule Slipdock.Inbound.WaitReplyTest do
  @moduledoc """
  Replying to a wait email answers the wait (#1259): the email itself, how a
  reply is read as an answer, and the replies that can't be.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Actor, Boards, Inbound, Repo, TestConfig}
  alias Slipdock.Boards.{Comment, Wait}
  alias Slipdock.Inbound.{ReplyToken, WaitReply}

  @domain "in.example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    dee = user_fixture("dee@example.com")
    share_fixture(board, dee, "write")
    card = card_fixture(hd(board.columns), %{"title" => "Pick a region"})
    %{owner: owner, board: board, dee: dee, card: card}
  end

  defp open(ctx, attrs) do
    {:ok, wait} =
      Boards.open_wait(ctx.card, Actor.web(ctx.owner), Map.put(attrs, :on_user_id, ctx.dee.id))

    wait
  end

  defp reply(ctx, person, body) do
    to = ReplyToken.address(ctx.card, person)
    domain = person.email |> String.split("@") |> List.last()

    raw =
      "ARC-Authentication-Results: i=1; mx.cloudflare.net; dmarc=pass header.from=#{domain}\r\n" <>
        "From: #{person.email}\r\nTo: #{to}\r\nSubject: Re: waiting\r\n" <>
        "Message-ID: <#{System.unique_integer([:positive])}@x>\r\nMIME-Version: 1.0\r\n" <>
        "Content-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n" <>
        "\r\nOn Sat, 24 Oct 2026 at 13:00, Slipdock <noreply@example.com> wrote:\r\n> Waiting on you\r\n"

    Inbound.receive_message(%{raw: raw, envelope_to: to, envelope_from: nil})
  end

  defp wait!(wait), do: Repo.get!(Wait, wait.id)

  defp comments(card),
    do: Repo.all(from(c in Comment, where: c.card_id == ^card.id, order_by: c.id, select: c.body))

  describe "the wait email" do
    test "goes to the person waited on, with the choices and how to answer by reply", ctx do
      open(ctx, %{needs: "Which region?", choices: ["EU", "US"]})

      assert_email_sent(fn email ->
        assert email.to == [{"", ctx.dee.email}]
        assert email.subject =~ "is waiting on you: “Pick a region”"
        assert email.text_body =~ "Which region?"
        assert email.text_body =~ "Choices:\n1. EU\n2. US"
        assert email.text_body =~ "/cards/#{ctx.card.id}"
        assert email.text_body =~ "start with a choice's number or its text"
        assert {:ok, _, user} = email.reply_to |> elem(1) |> token() |> ReplyToken.verify()
        assert user.id == ctx.dee.id
      end)
    end

    test "a series is listed, and the footer asks for a paragraph each", ctx do
      open(ctx, %{needs: "Two things", questions: ["Region?", "Seats?"]})

      assert_email_sent(fn email ->
        assert email.text_body =~ "1. Region?\n2. Seats?"
        assert email.text_body =~ "one paragraph per question, in order"
      end)
    end

    test "with inbound mail off it still goes, without the reply line", ctx do
      TestConfig.put(:inbound, domain: nil, secrets: [])
      open(ctx, %{needs: "Which region?"})

      assert_email_sent(fn email ->
        assert email.reply_to == nil
        refute email.text_body =~ "Reply to this email"
        true
      end)
    end

    test "nobody is emailed for a wait on anyone, or on the asker", ctx do
      {:ok, w} = Boards.open_wait(ctx.card, Actor.web(ctx.owner), %{needs: "Anyone?"})
      {:ok, _} = Boards.answer_wait(w, Actor.web(ctx.owner), %{answer: "x"})

      {:ok, _} =
        Boards.open_wait(ctx.card, Actor.web(ctx.owner), %{needs: "Me?", on_user_id: ctx.owner.id})

      refute_email_sent()
    end
  end

  describe "a reply from the person waited on answers it" do
    test "a choice's number", ctx do
      wait = open(ctx, %{needs: "Which region?", choices: ["EU", "US"]})
      assert {:accepted, email} = reply(ctx, ctx.dee, "2")

      closed = wait!(wait)

      assert {closed.close_reason, closed.choice, closed.closed_by_id} ==
               {"answered", 2, ctx.dee.id}

      assert List.last(comments(ctx.card)) =~ "Answered “Which region?”: US"
      assert email.comment_id
    end

    test "a choice's text, any case, with words after it", ctx do
      wait = open(ctx, %{needs: "Which region?", choices: ["EU", "US"]})
      assert {:accepted, _} = reply(ctx, ctx.dee, "eu\nCloser to the customers.")

      closed = wait!(wait)
      assert {closed.choice, closed.answer} == {1, "Closer to the customers."}
    end

    test "anything else is a free-text answer", ctx do
      wait = open(ctx, %{needs: "Which region?", choices: ["EU", "US"]})
      assert {:accepted, _} = reply(ctx, ctx.dee, "Neither, use APAC.")
      closed = wait!(wait)
      assert {closed.choice, closed.answer} == {nil, "Neither, use APAC."}
    end

    test "several questions, a paragraph each", ctx do
      wait = open(ctx, %{needs: "Two things", questions: ["Region?", "Seats?"]})
      assert {:accepted, _} = reply(ctx, ctx.dee, "EU\n\n40 seats")
      assert wait!(wait).answers == ["EU", "40 seats"]
    end

    test "files with an answer are linked in a comment after it", ctx do
      TestConfig.own_uploads_dir()
      wait = open(ctx, %{needs: "Send the log"})
      to = ReplyToken.address(ctx.card, ctx.dee)
      domain = ctx.dee.email |> String.split("@") |> List.last()
      b = "b1"

      raw =
        "ARC-Authentication-Results: i=1; mx.cloudflare.net; dmarc=pass header.from=#{domain}\r\n" <>
          "From: #{ctx.dee.email}\r\nTo: #{to}\r\nSubject: Re\r\nMessage-ID: <f@x>\r\nMIME-Version: 1.0\r\n" <>
          "Content-Type: multipart/mixed; boundary=#{b}\r\n\r\n--#{b}\r\nContent-Type: text/plain\r\n\r\nHere.\r\n" <>
          "--#{b}\r\nContent-Type: text/plain; name=\"log.txt\"\r\nContent-Disposition: attachment; filename=\"log.txt\"\r\n\r\nx\r\n--#{b}--\r\n"

      assert {:accepted, _} =
               Inbound.receive_message(%{raw: raw, envelope_to: to, envelope_from: nil})

      assert wait!(wait).answer == "Here."
      assert List.last(comments(ctx.card)) =~ "[log.txt]"
    end
  end

  describe "a reply that can't answer it" do
    test "more paragraphs than questions: a comment, and the wait stays open", ctx do
      wait = open(ctx, %{needs: "Two things", questions: ["Region?", "Seats?"]})
      assert {:accepted, _} = reply(ctx, ctx.dee, "EU\n\n40\n\nAlso, hi")

      assert Wait.open?(wait!(wait))
      [said, why] = ctx.card |> comments() |> Enum.take(-2)
      assert said =~ "Also, hi"

      assert why =~
               "**Not taken as the answer** to “Two things”: it has 3 paragraphs for 2 questions"

      assert why =~ "The wait is still open."
    end

    test "from somebody the wait isn't on: just a comment", ctx do
      wait = open(ctx, %{needs: "Which region?", choices: ["EU", "US"]})
      assert {:accepted, _} = reply(ctx, ctx.owner, "1")
      assert Wait.open?(wait!(wait))
      assert List.last(comments(ctx.card)) == "1"
    end

    test "nothing but the quote bounces, and the wait stays open", ctx do
      wait = open(ctx, %{needs: "Which region?"})
      assert {:rejected, reason, _} = reply(ctx, ctx.dee, "")
      assert reason =~ "nothing to add"
      assert Wait.open?(wait!(wait))
    end
  end

  describe "attrs/2" do
    test "reads replies as answer_wait takes them" do
      single = %Wait{needs: "Q", choices: [], questions: []}
      choices = %Wait{needs: "Q", choices: ["Ship it", "Hold"], questions: []}
      series = %Wait{needs: "Q", choices: [], questions: ["A?", "B?", "C?"]}

      assert WaitReply.attrs(single, " 2 ") == {:ok, %{answer: "2"}}
      assert WaitReply.attrs(choices, "2.") == {:ok, %{choice: 2}}
      assert WaitReply.attrs(choices, "SHIP IT") == {:ok, %{choice: 1}}
      assert WaitReply.attrs(choices, "3") == {:ok, %{answer: "3"}}
      assert WaitReply.attrs(choices, "Ship it now") == {:ok, %{answer: "Ship it now"}}
      assert WaitReply.attrs(series, "a\n\nb") == {:ok, %{answers: ["a", "b"]}}
      assert {:error, _} = WaitReply.attrs(series, "a\n\nb\n\nc\n\nd")
      assert {:error, "the reply was empty"} = WaitReply.attrs(single, "  ")
    end
  end

  defp token("reply-" <> rest), do: rest |> String.split("@") |> hd()
end
