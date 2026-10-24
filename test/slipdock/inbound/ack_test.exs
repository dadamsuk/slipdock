defmodule Slipdock.Inbound.AckTest do
  @moduledoc """
  The acknowledgement email (#1249): off by default, one short email with
  the link when on, never for automatic mail, never twice for one message.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Accounts, Inbound, Repo, TestConfig}
  alias Slipdock.Inbound.{Ack, Email, Tokens}

  @domain "in.example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    user = user_fixture()
    board = board_fixture(%{"name" => "Plan"}, owner: user)
    {:ok, address} = Tokens.address(user, board, :card)
    %{user: user, board: board, address: address}
  end

  defp mail(ctx, opts \\ []) do
    "ARC-Authentication-Results: i=1; mx.cloudflare.net; dkim=pass header.d=example.com;\r\n" <>
      " dmarc=pass header.from=example.com\r\n" <>
      "From: Sender <#{Keyword.get(opts, :from, ctx.user.email)}>\r\nTo: #{ctx.address}\r\n" <>
      "Subject: #{Keyword.get(opts, :subject, "Fix the gate")}\r\n" <>
      "Message-ID: #{Keyword.get(opts, :id, "<#{System.unique_integer([:positive])}@example.com>")}\r\n" <>
      Keyword.get(opts, :headers, "") <> "\r\nThe latch sticks.\r\n"
  end

  defp deliver(ctx, raw, to \\ nil),
    do: Inbound.receive_message(%{raw: raw, envelope_to: to || ctx.address, envelope_from: nil})

  defp ack_on(ctx) do
    {:ok, user} = Accounts.update_inbound(ctx.user, %{"inbound_ack" => true})
    %{ctx | user: user}
  end

  test "off by default: the card is made and nothing is sent", ctx do
    refute ctx.user.inbound_ack
    assert {:accepted, _} = deliver(ctx, mail(ctx))
    assert_no_email_sent()
  end

  test "on: one short email back with the link", ctx do
    ctx = ack_on(ctx)
    raw = mail(ctx, id: "<orig-1@example.com>")

    assert {:accepted, email} = deliver(ctx, raw)

    assert_email_sent(fn sent ->
      assert sent.to == [{ctx.user.name || ctx.user.email, ctx.user.email}]
      assert sent.subject == "Added: Fix the gate"
      assert sent.text_body =~ "Your email made a card on Plan:"
      assert sent.text_body =~ "/boards/#{ctx.board.id}/cards/#{email.card_id}"
      assert sent.headers["Auto-Submitted"] == "auto-replied"
      assert sent.headers["In-Reply-To"] == "<orig-1@example.com>"
    end)

    assert Repo.get!(Email, email.id).acked_at
  end

  test "a repeated delivery of the same message sends nothing more", ctx do
    ctx = ack_on(ctx)
    raw = mail(ctx, id: "<twice@example.com>")

    assert {:accepted, email} = deliver(ctx, raw)
    assert_email_sent(subject: "Added: Fix the gate")

    assert {:duplicate, _} = deliver(ctx, raw)
    assert_no_email_sent()
    # And a second try at the same row, as a racing delivery would make.
    assert Ack.maybe_send(Repo.get!(Email, email.id)) == :skipped
    assert_no_email_sent()
  end

  test "never in answer to automatic mail", ctx do
    ctx = ack_on(ctx)
    raw = mail(ctx, headers: "Auto-Submitted: auto-replied\r\n")

    assert {:dropped, _, _} = deliver(ctx, raw)
    assert_no_email_sent()
  end

  test "never for a bounce", ctx do
    ctx = ack_on(ctx)

    assert {:rejected, _, _} = deliver(ctx, mail(ctx, from: "stranger@example.com"))
    assert_no_email_sent()
  end

  test "a personal address's card is acknowledged too", ctx do
    ctx = ack_on(ctx)
    {:ok, user} = Accounts.update_quick_add(ctx.user, %{"quick_add_ai" => false})
    {:ok, add} = Tokens.address(user, nil, :add)

    assert {:accepted, _} =
             deliver(
               %{ctx | address: add},
               mail(%{ctx | address: add}, subject: "Buy stamps"),
               add
             )

    assert_email_sent(subject: "Added: Buy stamps")
  end

  test "a send that fails doesn't undo the card", ctx do
    ctx = ack_on(ctx)
    test_pid = self()

    TestConfig.put(:inbound_ack_mailer, fn message ->
      send(test_pid, {:tried, message.subject})
      {:error, :boom}
    end)

    assert {:accepted, email} = deliver(ctx, mail(ctx))
    assert_received {:tried, "Added: Fix the gate"}
    assert email.card_id
    assert Repo.get!(Email, email.id).acked_at

    TestConfig.put(:inbound_ack_mailer, fn _ -> raise "smtp exploded" end)
    assert {:accepted, email} = deliver(ctx, mail(ctx))
    assert email.card_id
  end
end
