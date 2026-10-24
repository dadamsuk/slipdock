defmodule Slipdock.Inbound.CardsTest do
  @moduledoc """
  Email to a board's card address (#1247), end to end through
  `Slipdock.Inbound.receive_message/1` with the real dispatcher: the address
  resolved, the sender trusted, and the card, its files and its creator.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Inbound, Repo, Settings, TestConfig}
  alias Slipdock.Boards.{Attachment, Card, CardMove, Comment}
  alias Slipdock.Inbound.{Cards, Message, Tokens}

  @domain "in.example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    TestConfig.own_uploads_dir()
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    {:ok, address} = Tokens.address(user, board, :card)
    %{user: user, board: board, address: address}
  end

  # A message as Cloudflare hands it on: its own authentication results on
  # top, DMARC passing for the sender's domain.
  defp mail(from, to, subject, body_part, extra_headers \\ "") do
    "ARC-Authentication-Results: i=1; mx.cloudflare.net; dkim=pass header.d=example.com;\r\n" <>
      " dmarc=pass header.from=example.com\r\n" <>
      "From: Sender <#{from}>\r\nTo: #{to}\r\n" <>
      if(subject, do: "Subject: #{subject}\r\n", else: "") <>
      "Message-ID: <#{System.unique_integer([:positive])}@example.com>\r\n" <>
      extra_headers <> "MIME-Version: 1.0\r\n" <> body_part
  end

  defp text(body), do: "Content-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n"

  defp multipart(parts) do
    boundary = "b#{System.unique_integer([:positive])}"

    "Content-Type: multipart/mixed; boundary=#{boundary}\r\n\r\n" <>
      Enum.map_join(parts, "", &"--#{boundary}\r\n#{&1}\r\n") <> "--#{boundary}--\r\n"
  end

  defp file(name, type, data, headers \\ "") do
    "Content-Type: #{type}; name=\"#{name}\"\r\nContent-Transfer-Encoding: base64\r\n" <>
      "Content-Disposition: attachment; filename=\"#{name}\"\r\n" <>
      headers <> "\r\n" <> Base.encode64(data) <> "\r\n"
  end

  defp deliver(raw, to),
    do: Inbound.receive_message(%{raw: raw, envelope_to: to, envelope_from: nil})

  defp card!(email), do: Repo.get!(Card, email.card_id) |> Repo.preload([:column, :attachments])

  describe "a message to the card address" do
    test "becomes a card on the ready list, as the address's owner", ctx do
      raw =
        mail(
          ctx.user.email,
          ctx.address,
          "Re: Fwd: Fix the gate",
          text("The latch sticks.\n\nThanks")
        )

      assert {:accepted, email} = deliver(raw, ctx.address)
      card = card!(email)

      assert card.board_id == ctx.board.id
      assert card.title == "Fix the gate"
      assert card.description =~ "The latch sticks."
      assert card.column.id == SlipdockWeb.APIGuide.list_roles(ctx.board.columns).ready.id
      assert email.user_id == ctx.user.id and email.kind == "card"

      move = Repo.get_by!(CardMove, card_id: card.id, kind: "created")
      assert {move.user_id, move.actor_kind, move.via} == {ctx.user.id, "human", "email"}
    end

    test "no subject is (no subject)", ctx do
      assert {:accepted, email} =
               deliver(mail(ctx.user.email, ctx.address, nil, text("hi")), ctx.address)

      assert card!(email).title == "(no subject)"
    end

    test "attachments are uploaded to the card", ctx do
      raw =
        mail(
          ctx.user.email,
          ctx.address,
          "Invoice",
          multipart([text("Attached."), file("invoice.pdf", "application/pdf", "%PDF-1.4 hello")])
        )

      assert {:accepted, email} = deliver(raw, ctx.address)

      assert [%Attachment{filename: "invoice.pdf", content_type: "application/pdf"} = a] =
               card!(email).attachments

      assert File.read!(Boards.attachment_path(a)) == "%PDF-1.4 hello"
    end

    test "an inline cid: image is uploaded and shown in the description", ctx do
      png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>
      boundary = "rel#{System.unique_integer([:positive])}"

      related =
        "Content-Type: multipart/related; boundary=#{boundary}\r\n\r\n" <>
          "--#{boundary}\r\nContent-Type: text/html; charset=utf-8\r\n\r\n" <>
          "<p>See this:</p><img src=\"cid:shot1@example.com\" alt=\"shot\">\r\n" <>
          "--#{boundary}\r\nContent-Type: image/png; name=\"shot.png\"\r\n" <>
          "Content-Transfer-Encoding: base64\r\nContent-ID: <shot1@example.com>\r\n" <>
          "Content-Disposition: inline; filename=\"shot.png\"\r\n\r\n" <>
          Base.encode64(png) <> "\r\n--#{boundary}--\r\n"

      boundary2 = "alt#{System.unique_integer([:positive])}"

      body =
        "Content-Type: multipart/alternative; boundary=#{boundary2}\r\n\r\n" <>
          "--#{boundary2}\r\nContent-Type: text/plain\r\n\r\nSee this: [image: shot]\r\n" <>
          "--#{boundary2}\r\n" <> related <> "\r\n--#{boundary2}--\r\n"

      assert {:accepted, email} =
               deliver(mail(ctx.user.email, ctx.address, "Screenshot", body), ctx.address)

      card = card!(email)
      assert [%Attachment{filename: "shot.png"} = a] = card.attachments
      assert card.description =~ "See this:"
      assert card.description =~ "](#{Boards.attachment_url(a)})"
    end

    test "a forward keeps the original sender and date at the top", ctx do
      body =
        text("""
        FYI

        ---------- Forwarded message ---------
        From: Dana Client <dana@example.com>
        Date: Mon, 19 Oct 2026 at 09:12
        Subject: Broken checkout
        To: <#{ctx.user.email}>

        The checkout fails on step 2.
        """)

      raw = mail(ctx.user.email, ctx.address, "Fwd: Broken checkout", body)
      assert {:accepted, email} = deliver(raw, ctx.address)
      card = card!(email)

      assert card.title == "Broken checkout"

      assert String.starts_with?(
               card.description,
               "*Forwarded: first sent by Dana Client <dana@example.com> on Mon, 19 Oct 2026 at 09:12.*"
             )

      assert card.description =~ "The checkout fails on step 2."
    end

    test "a forward as an attached message takes the sender from it", ctx do
      inner =
        "From: Dana <dana@example.com>\r\nDate: Tue, 20 Oct 2026 10:00:00 +0000\r\n" <>
          "Subject: Original\r\n\r\nInner body\r\n"

      raw =
        mail(
          ctx.user.email,
          ctx.address,
          "Fwd: Original",
          multipart([
            text("See below"),
            "Content-Type: message/rfc822\r\nContent-Disposition: attachment\r\n\r\n" <> inner
          ])
        )

      assert {:accepted, email} = deliver(raw, ctx.address)
      card = card!(email)

      assert card.description =~
               "*Forwarded: first sent by Dana <dana@example.com> on Tue, 20 Oct 2026 10:00:00 +0000.*"

      assert [%Attachment{content_type: "message/rfc822"}] = card.attachments
    end
  end

  describe "bounces" do
    test "from somebody else's address", ctx do
      raw = mail("stranger@example.com", ctx.address, "Spam", text("buy"))

      assert {:rejected, reason, _} = deliver(raw, ctx.address)
      assert reason =~ "has to come from the address of the account"
      assert Repo.aggregate(Card, :count) == 0
    end

    test "after rotating, the old address bounces and the new one works", ctx do
      {:ok, %{card: new}} = Tokens.rotate(ctx.user, ctx.board)

      assert {:rejected, reason, _} =
               deliver(mail(ctx.user.email, ctx.address, "Old", text("x")), ctx.address)

      assert reason =~ "no longer in use"
      assert {:accepted, _} = deliver(mail(ctx.user.email, new, "New", text("x")), new)
    end

    test "an unknown token, or the personal token on card-", ctx do
      bogus = "card-#{String.duplicate("a", 26)}@#{@domain}"

      assert {:rejected, "No such address here.", _} =
               deliver(mail(ctx.user.email, bogus, "x", text("x")), bogus)

      {:ok, add} = Tokens.address(ctx.user, nil, :add)
      as_card = String.replace(add, "add-", "card-")

      assert {:rejected, "No such address here.", _} =
               deliver(mail(ctx.user.email, as_card, "x", text("x")), as_card)
    end

    test "an archived board", ctx do
      {:ok, _} = Boards.archive_board(ctx.board)

      assert {:rejected, reason, _} =
               deliver(mail(ctx.user.email, ctx.address, "x", text("x")), ctx.address)

      assert reason =~ "archived"
    end

    test "a full account bounces in plain words", ctx do
      {:ok, _} =
        Settings.complete_setup(%{
          "admin_email" => "admin@example.com",
          "item_limit_enabled" => true,
          "item_limit" => 1
        })

      [_, todo | _] = ctx.board.columns
      card_fixture(todo, %{"title" => "Already here"})

      assert {:rejected, reason, email} =
               deliver(mail(ctx.user.email, ctx.address, "One more", text("x")), ctx.address)

      assert reason =~ "is full, so no card was made"
      assert email.user_id == ctx.user.id
      assert Repo.aggregate(Card, :count) == 1
    end
  end

  describe "the storage limit" do
    setup do
      {:ok, _} =
        Settings.complete_setup(%{
          "admin_email" => "admin@example.com",
          "storage_limit_enabled" => true,
          "storage_limit_mb" => 1
        })

      :ok
    end

    test "attachments that don't fit are left off, and a comment names them", ctx do
      big = :binary.copy("x", 1024 * 1024 + 1)

      raw =
        mail(
          ctx.user.email,
          ctx.address,
          "Logs",
          multipart([
            text("Two files."),
            file("small.txt", "text/plain", "tiny"),
            file("huge.log", "text/plain", big)
          ])
        )

      assert {:accepted, email} = deliver(raw, ctx.address)
      card = card!(email)
      assert [%Attachment{filename: "small.txt"}] = card.attachments

      assert [%Comment{body: body, user_id: uid}] =
               Repo.all(from(c in Comment, where: c.card_id == ^card.id))

      assert uid == ctx.user.id
      assert body =~ "**Not attached.**"
      assert body =~ "`huge.log` (1.0 MB): the account's storage is full"
      refute body =~ "small.txt"
    end

    test "a message that is only files, with no room for any, bounces", ctx do
      big = :binary.copy("x", 1024 * 1024 + 1)

      raw =
        mail(
          ctx.user.email,
          ctx.address,
          "Scan",
          multipart([file("scan.pdf", "application/pdf", big)])
        )

      assert {:rejected, reason, _} = deliver(raw, ctx.address)
      assert reason =~ "out of storage"
      assert Repo.aggregate(Card, :count) == 0
    end
  end

  describe "title/1 and forward_line/1" do
    test "reply and forward prefixes in any mix, and the 200-character cap" do
      assert Cards.title("RE: Fwd: FW: AW: Budget") == "Budget"
      assert Cards.title("Re[2]: Budget") == "Budget"
      assert Cards.title("  ") == "(no subject)"
      assert Cards.title("Fwd:") == "(no subject)"
      assert Cards.title("Regarding the plan") == "Regarding the plan"
      assert Cards.title(String.duplicate("a", 250)) |> String.length() == 200
    end

    test "nothing for a message that isn't a forward" do
      {:ok, message} =
        Message.parse("From: a@example.com\r\nSubject: Hello\r\n\r\nFrom: b@example.com\r\n")

      assert Cards.forward_line(message) == nil
    end

    test "a forward whose headers can't be found gets no line" do
      {:ok, message} =
        Message.parse("From: a@example.com\r\nSubject: Fwd: x\r\n\r\njust text\r\n")

      assert Cards.forward_line(message) == nil
    end
  end
end
