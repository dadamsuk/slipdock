defmodule Slipdock.Inbound.RepliesTest do
  @moduledoc """
  Replies to notification emails (#1258), end to end through
  `Slipdock.Inbound.receive_message/1` with the real dispatcher: the signed
  address checked, the sender trusted, and the comment, its files and who
  it tells. Real client replies come from `test/fixtures/inbound`.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Inbound, Repo, TestConfig}
  alias Slipdock.Boards.{Attachment, Comment}
  alias Slipdock.Inbound.ReplyToken

  @domain "in.example.com"
  @fixtures "test/fixtures/inbound"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    TestConfig.own_uploads_dir()
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Fix the gate"})
    %{user: user, board: board, card: card, address: ReplyToken.address(card, user)}
  end

  # A fixture as it would arrive for `user`: Cloudflare's results on top,
  # DMARC passing for the sender's domain, and From/To/Message-ID rewritten.
  defp arrive(raw, from, to, opts \\ []) do
    domain = from |> String.split("@") |> List.last()
    {head, body} = split(raw)

    head =
      head
      |> String.replace(~r/^From:.*$/mi, "From: Someone <#{from}>", global: false)
      |> String.replace(~r/^To:.*$/mi, "To: #{to}", global: false)
      |> String.replace(
        ~r/^Message-I[dD]:.*$/mi,
        "Message-ID: <#{System.unique_integer([:positive])}@x>",
        global: false
      )

    auth =
      if Keyword.get(opts, :auth, true),
        do:
          "ARC-Authentication-Results: i=1; mx.cloudflare.net; dmarc=pass header.from=#{domain}\r\n",
        else: ""

    auth <> head <> body
  end

  defp split(raw) do
    {at, _} = :binary.match(raw, ["\r\n\r\n", "\n\n"])
    {binary_part(raw, 0, at), binary_part(raw, at, byte_size(raw) - at)}
  end

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp plain(body) do
    "Subject: Re: Fix the gate\r\nMessage-ID: <m@x>\r\nFrom: x@x\r\nTo: y@y\r\n" <>
      "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n"
  end

  defp deliver(raw, to),
    do: Inbound.receive_message(%{raw: raw, envelope_to: to, envelope_from: nil})

  defp comments(card),
    do: Repo.all(from(c in Comment, where: c.card_id == ^card.id, order_by: c.id))

  describe "a reply from a real client becomes a clean comment, as the person" do
    test "Gmail, plain text", ctx do
      raw = fixture("gmail_reply.eml") |> arrive(ctx.user.email, ctx.address)
      assert {:accepted, email} = deliver(raw, ctx.address)

      [comment] = comments(ctx.card)
      assert comment.body == "Sounds good — ship it. Ünïcödé survives 8bit."
      assert comment.user_id == ctx.user.id
      assert email.comment_id == comment.id and email.kind == "reply"
      assert Inbound.created_path(Repo.preload(email, comment: :card)) =~ "/cards/#{ctx.card.id}"
    end

    test "Gmail, HTML only: the signature and quote are gone", ctx do
      raw = fixture("gmail_reply_html.eml") |> arrive(ctx.user.email, ctx.address)
      assert {:accepted, _} = deliver(raw, ctx.address)
      [comment] = comments(ctx.card)
      assert comment.body =~ "Merci, c'est fait."
      refute comment.body =~ "Product"
      refute comment.body =~ "A card was updated"
    end

    test "Outlook", ctx do
      raw = fixture("outlook_reply.eml") |> arrive(ctx.user.email, ctx.address)
      assert {:accepted, _} = deliver(raw, ctx.address)
      [comment] = comments(ctx.card)
      assert comment.body == "Agreed, let's do it Monday."
    end

    test "Apple Mail", ctx do
      raw = fixture("apple_reply.eml") |> arrive(ctx.user.email, ctx.address)
      assert {:accepted, _} = deliver(raw, ctx.address)
      [comment] = comments(ctx.card)
      assert comment.body =~ "Yes, both are paid."
      refute comment.body =~ "A card was updated"
    end

    test "the address is case-insensitive, and a +tag is ignored", ctx do
      ["reply-" <> token, host] = String.split(ctx.address, "@")
      to = "REPLY-#{String.upcase(token)}+x@#{host}"
      assert {:accepted, _} = deliver(arrive(plain("Fine by me."), ctx.user.email, to), to)
      assert [%{body: "Fine by me."}] = comments(ctx.card)
    end
  end

  describe "bounced" do
    test "a forged address", ctx do
      to = "reply-#{String.duplicate("a", 37)}@#{@domain}"

      assert {:rejected, "No such address here.", _} =
               deliver(arrive(plain("Hi"), ctx.user.email, to), to)

      assert comments(ctx.card) == []
    end

    test "an address signed for someone else, sent from my address", ctx do
      other = user_fixture("other@example.com")
      Slipdock.Access.grant(ctx.board, other, "write", ctx.user)
      to = ReplyToken.address(ctx.card, other)

      assert {:rejected, reason, _} = deliver(arrive(plain("Hi"), ctx.user.email, to), to)
      assert reason =~ "has to come from the address of the account"
      assert comments(ctx.card) == []
    end

    test "a stale address", ctx do
      token = ReplyToken.sign(ctx.card, ctx.user, Date.add(Date.utc_today(), -400))
      to = "reply-#{token}@#{@domain}"
      assert {:rejected, reason, _} = deliver(arrive(plain("Hi"), ctx.user.email, to), to)
      assert reason =~ "expired"
    end

    test "a card since archived", ctx do
      {:ok, _} =
        ctx.card |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update()

      assert {:rejected, reason, _} =
               deliver(arrive(plain("Hi"), ctx.user.email, ctx.address), ctx.address)

      assert reason =~ "deleted or archived"
    end

    test "a person who can no longer comment", ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")
      to = "reply-#{ReplyToken.sign(ctx.card, reader)}@#{@domain}"
      assert {:rejected, reason, _} = deliver(arrive(plain("Hi"), reader.email, to), to)
      assert reason =~ "no longer comment"
    end

    test "unauthenticated mail", ctx do
      raw = arrive(plain("Hi"), ctx.user.email, ctx.address, auth: false)
      assert {:rejected, reason, _} = deliver(raw, ctx.address)
      assert reason =~ "neither DMARC nor DKIM"
    end

    test "a reply that is nothing but the quote", ctx do
      body =
        "\nOn Sat, 24 Oct 2026 at 13:00, Slipdock <noreply@example.com> wrote:\n> A card was updated.\n"

      assert {:rejected, reason, _} =
               deliver(arrive(plain(body), ctx.user.email, ctx.address), ctx.address)

      assert reason =~ "nothing to add"
      assert comments(ctx.card) == []
    end
  end

  test "automatic replies are dropped, not bounced", ctx do
    raw = fixture("auto_reply.eml") |> arrive(ctx.user.email, ctx.address)
    assert {:dropped, _, _} = deliver(raw, ctx.address)
    assert comments(ctx.card) == []
  end

  test "a repeated delivery adds one comment", ctx do
    raw = arrive(plain("Once."), ctx.user.email, ctx.address)
    assert {:accepted, _} = deliver(raw, ctx.address)
    assert {:duplicate, _} = deliver(raw, ctx.address)
    assert length(comments(ctx.card)) == 1
  end

  describe "files" do
    defp with_file(body, name, data) do
      b = "b#{System.unique_integer([:positive])}"

      "Subject: Re: x\r\nMessage-ID: <m@x>\r\nFrom: x@x\r\nTo: y@y\r\nMIME-Version: 1.0\r\n" <>
        "Content-Type: multipart/mixed; boundary=#{b}\r\n\r\n" <>
        "--#{b}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n" <>
        "--#{b}\r\nContent-Type: text/plain; name=\"#{name}\"\r\nContent-Transfer-Encoding: base64\r\n" <>
        "Content-Disposition: attachment; filename=\"#{name}\"\r\n\r\n#{Base.encode64(data)}\r\n--#{b}--\r\n"
    end

    test "go to the card, and the comment links to them", ctx do
      raw = with_file("Log attached.", "log.txt", "line 1") |> arrive(ctx.user.email, ctx.address)
      assert {:accepted, _} = deliver(raw, ctx.address)

      [attachment] = Repo.all(from(a in Attachment, where: a.card_id == ^ctx.card.id))
      assert attachment.filename == "log.txt"
      [comment] = comments(ctx.card)
      assert comment.body =~ "Log attached."
      assert comment.body =~ "[log.txt](#{Slipdock.Boards.attachment_url(attachment)})"
    end

    test "a reply that is only a file is still a comment", ctx do
      raw = with_file("", "log.txt", "line 1") |> arrive(ctx.user.email, ctx.address)
      assert {:accepted, _} = deliver(raw, ctx.address)
      [comment] = comments(ctx.card)
      assert comment.body =~ "**Attached:**\n- [log.txt]"
    end
  end

  test "mentions in a reply tell the person mentioned, never the sender", ctx do
    {:ok, priya} =
      Slipdock.Accounts.get_or_create_user_by_email(fixture_email("priya@example.com"))

    share_fixture(ctx.board, priya, "write")
    handle = priya.email |> String.split("@") |> hd()

    raw = arrive(plain("@#{handle} can you check? cc me"), ctx.user.email, ctx.address)
    assert {:accepted, _} = deliver(raw, ctx.address)

    assert_email_sent(fn email ->
      assert email.to == [{"", priya.email}]
      assert email.subject =~ "mentioned you"
    end)

    sender = ctx.user.email
    refute_received {:email, %{to: [{_, ^sender}]}}
  end
end
