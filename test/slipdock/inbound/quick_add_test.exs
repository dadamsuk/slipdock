defmodule Slipdock.Inbound.QuickAddTest do
  @moduledoc """
  Email to a personal `add-…` address (#1248), end to end through
  `Slipdock.Inbound.receive_message/1`: the subject read by Quick Add, the
  body and files from the mail, and the bounces.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Inbound, Repo, Settings, TestConfig}
  alias Slipdock.Boards.{Attachment, Card, CardMove}
  alias Slipdock.Inbound.{QuickAdd, Tokens}

  @domain "in.example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    TestConfig.own_uploads_dir()
    user = user_fixture()
    plan = board_fixture(%{"name" => "Plan"}, owner: user)
    errands = board_fixture(%{"name" => "Errands"}, owner: user)
    doing = Enum.find(errands.columns, &(&1.name == "In Progress"))

    {:ok, user} =
      Accounts.update_quick_add(user, %{
        "quick_add_board_id" => errands.id,
        "quick_add_column_id" => doing.id,
        "quick_add_ai" => false
      })

    {:ok, address} = Tokens.address(user, nil, :add)
    %{user: user, plan: plan, errands: errands, doing: doing, address: address}
  end

  defp mail(from, to, subject, body_part) do
    "ARC-Authentication-Results: i=1; mx.cloudflare.net; dkim=pass header.d=example.com;\r\n" <>
      " dmarc=pass header.from=example.com\r\n" <>
      "From: Sender <#{from}>\r\nTo: #{to}\r\nSubject: #{subject}\r\n" <>
      "Message-ID: <#{System.unique_integer([:positive])}@example.com>\r\n" <>
      "MIME-Version: 1.0\r\n" <> body_part
  end

  defp text(body), do: "Content-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n"

  defp with_file(body, name, data) do
    b = "b#{System.unique_integer([:positive])}"

    "Content-Type: multipart/mixed; boundary=#{b}\r\n\r\n--#{b}\r\n" <>
      text(body) <>
      "\r\n--#{b}\r\nContent-Type: text/plain; name=\"#{name}\"\r\n" <>
      "Content-Disposition: attachment; filename=\"#{name}\"\r\n\r\n#{data}\r\n--#{b}--\r\n"
  end

  defp deliver(ctx, subject, body \\ text("")) do
    Inbound.receive_message(%{
      raw: mail(ctx.user.email, ctx.address, subject, body),
      envelope_to: ctx.address,
      envelope_from: nil
    })
  end

  defp card!(email), do: Repo.get!(Card, email.card_id) |> Repo.preload([:column, :attachments])

  test "the subject's syntax is read; the card goes to the Quick Add default", ctx do
    assert {:accepted, email} =
             deliver(ctx, "Fwd: Renew the cert due: 2026-11-02 #high", text("Expires soon."))

    card = card!(email)
    assert email.kind == "add" and email.user_id == ctx.user.id
    assert card.title == "Renew the cert"
    assert card.priority == "high"
    assert card.due_date == ~D[2026-11-02]
    assert card.board_id == ctx.errands.id
    assert card.column_id == ctx.doing.id
    assert card.description =~ "Expires soon."

    move = Repo.get_by!(CardMove, card_id: card.id, kind: "created")
    assert {move.user_id, move.via} == {ctx.user.id, "email"}
  end

  test "a list named with # on the default board", ctx do
    assert {:accepted, email} = deliver(ctx, "Buy stamps #todo")
    card = card!(email)
    assert card.board_id == ctx.errands.id
    assert card.column.name == "To Do"
  end

  test "[Board] picks the board, by name or code, on its ready list", ctx do
    assert {:accepted, email} = deliver(ctx, "[plan] Write the launch post")
    card = card!(email)
    assert card.board_id == ctx.plan.id
    assert card.title == "Write the launch post"
    assert card.column.name == "To Do"

    assert {:accepted, email} = deliver(ctx, "[#{String.upcase(ctx.plan.code)}] Second")
    assert card!(email).board_id == ctx.plan.id
  end

  test "[Board] with a #list reads the list on that board", ctx do
    assert {:accepted, email} = deliver(ctx, "[Plan] Draft it #in-progress")
    card = card!(email)
    assert {card.board_id, card.column.name} == {ctx.plan.id, "In Progress"}
  end

  test "a board that can't be found bounces with the boards there are", ctx do
    assert {:rejected, reason, email} = deliver(ctx, "[Nowhere] Lost")

    assert reason =~ "There's no board called “Nowhere” that you can add to."
    assert reason =~ "Boards you can add to:"
    assert reason =~ "Plan" and reason =~ "Errands"
    assert email.user_id == ctx.user.id
    assert Repo.aggregate(Card, :count) == 0
  end

  test "a board somebody else owns, not shared, isn't reachable", ctx do
    stranger = user_fixture("stranger@example.com")
    board_fixture(%{"name" => "Secret"}, owner: stranger)

    assert {:rejected, reason, _} = deliver(ctx, "[Secret] Peek")
    assert reason =~ "no board called “Secret”"
    refute reason =~ "Secret,"
  end

  test "a board the model names that doesn't exist bounces too", ctx do
    {:ok, user} = Accounts.update_quick_add(ctx.user, %{"quick_add_ai" => true})
    Slipdock.AIStub.reply_with(%{"title" => "Fix it", "board" => "Garden shed"})

    assert {:rejected, reason, _} =
             deliver(%{ctx | user: user}, "fix it on the garden shed board")

    assert reason =~ "no board called “Garden shed”"
  end

  test "the model's board, when it exists, is used", ctx do
    {:ok, user} = Accounts.update_quick_add(ctx.user, %{"quick_add_ai" => true})
    Slipdock.AIStub.reply_with(%{"title" => "Fix it", "board" => "Plan", "priority" => "low"})

    assert {:accepted, email} = deliver(%{ctx | user: user}, "fix it on plan, not urgent")
    card = card!(email)
    assert {card.board_id, card.title, card.priority} == {ctx.plan.id, "Fix it", "low"}
  end

  test "attachments are uploaded", ctx do
    assert {:accepted, email} = deliver(ctx, "Notes", with_file("See file", "notes.txt", "hello"))
    assert [%Attachment{filename: "notes.txt"}] = card!(email).attachments
  end

  test "an empty subject is (no subject)", ctx do
    assert {:accepted, email} = deliver(ctx, "", text("body"))
    assert card!(email).title == "(no subject)"
  end

  test "a board token's add- address is refused", ctx do
    {:ok, card_address} = Tokens.address(ctx.user, ctx.plan, :card)
    as_add = String.replace(card_address, "card-", "add-")

    assert {:rejected, "No such address here.", _} =
             Inbound.receive_message(%{
               raw: mail(ctx.user.email, as_add, "x", text("x")),
               envelope_to: as_add,
               envelope_from: nil
             })
  end

  test "mail from another address bounces", ctx do
    assert {:rejected, reason, _} =
             Inbound.receive_message(%{
               raw: mail("someone@example.com", ctx.address, "x", text("x")),
               envelope_to: ctx.address,
               envelope_from: nil
             })

    assert reason =~ "has to come from the address of the account"
  end

  test "a full account bounces in plain words", ctx do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => "admin@example.com",
        "item_limit_enabled" => true,
        "item_limit" => 1
      })

    card_fixture(hd(ctx.plan.columns), %{"title" => "Already here"})

    assert {:rejected, reason, _} = deliver(ctx, "One more")
    assert reason =~ "is full, so no card was made"
  end

  test "somebody with no board to write to is told so" do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    loner = user_fixture("loner@example.com")
    {:ok, address} = Tokens.address(loner, nil, :add)

    assert {:rejected, reason, _} =
             Inbound.receive_message(%{
               raw: mail(loner.email, address, "Hello", text("x")),
               envelope_to: address,
               envelope_from: nil
             })

    assert reason =~ "board"
  end

  describe "split_board/1" do
    test "a leading [Board], and the rest" do
      assert QuickAdd.split_board("[Ops] Renew the cert") == {"Ops", "Renew the cert"}
      assert QuickAdd.split_board("  [ Ops ]   x") == {"Ops", "x"}
      assert QuickAdd.split_board("[Ops]") == {"Ops", "(no subject)"}
      assert QuickAdd.split_board("Renew [Ops]") == {nil, "Renew [Ops]"}
      assert QuickAdd.split_board("Plain") == {nil, "Plain"}
    end
  end
end
