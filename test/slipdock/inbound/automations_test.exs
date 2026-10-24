defmodule Slipdock.Inbound.AutomationsTest do
  @moduledoc """
  Rules that act on what mail brings in (#1275), end to end through
  `Slipdock.Inbound.receive_message/1`: `card_emailed` for a card made at a
  board's card address or a personal `add-…` address, and `page_emailed`
  for a page made or added to at a page or folder address.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Automations, Boards, Inbound, Repo, TestConfig}
  alias Slipdock.Automations.Rule
  alias Slipdock.Boards.{Activity, Card}
  alias Slipdock.Inbound.Tokens
  alias Slipdock.Wiki.{Folders, Page}

  @domain "in.example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    TestConfig.own_uploads_dir()
    user = user_fixture()
    board = board_fixture(%{"name" => "Mailbag"}, owner: user)
    %{user: user, board: board}
  end

  defp mail(from, to, subject, body) do
    "ARC-Authentication-Results: i=1; mx.cloudflare.net; dkim=pass header.d=example.com;\r\n" <>
      " dmarc=pass header.from=example.com\r\n" <>
      "From: Sender <#{from}>\r\nTo: #{to}\r\nSubject: #{subject}\r\n" <>
      "Message-ID: <#{System.unique_integer([:positive])}@example.com>\r\n" <>
      "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n"
  end

  defp send_to(ctx, address, subject, body \\ "Hello.") do
    Inbound.receive_message(%{
      raw: mail(ctx.user.email, address, subject, body),
      envelope_to: address,
      envelope_from: nil
    })
  end

  defp address(ctx, kind, target \\ :board) do
    target = if target == :board, do: ctx.board, else: target
    {:ok, address} = Tokens.address(ctx.user, target, kind)
    address
  end

  defp rule(board, trigger, actions, conditions \\ []) do
    rule_fixture(board, %{
      "trigger" => trigger,
      "conditions" => conditions,
      "actions" => actions
    })
  end

  defp card!(email), do: Repo.get!(Card, email.card_id)
  defp page!(email), do: Page |> Repo.get!(email.page_id) |> Repo.preload(:tags)
  defp runs(rule), do: Repo.get!(Rule, rule.id).run_count

  describe "card_emailed" do
    test "flags a card that arrives at the board's card address", ctx do
      rule(ctx.board, %{"type" => "card_emailed"}, [
        %{"type" => "add_flags", "flags" => ["review"]}
      ])

      assert {:accepted, email} = send_to(ctx, address(ctx, :card), "Invoice query")
      assert card!(email).flags == ["review"]
    end

    test "sees the description and the mail's sender and subject", ctx do
      rule(
        ctx.board,
        %{"type" => "card_emailed"},
        [%{"type" => "comment", "body" => "From {{email.from}}: {{email.subject}}"}],
        [%{"field" => "description", "op" => "contains", "value" => "urgent"}]
      )

      assert {:accepted, email} =
               send_to(ctx, address(ctx, :card), "Fwd: Server down", "This is urgent.")

      card = email |> card!() |> Repo.preload(:comments)
      assert [comment] = card.comments
      assert comment.body == "From #{ctx.user.email}: Fwd: Server down"
    end

    test "a condition that fails leaves the card alone", ctx do
      rule(
        ctx.board,
        %{"type" => "card_emailed"},
        [%{"type" => "add_flags", "flags" => ["review"]}],
        [%{"field" => "description", "op" => "contains", "value" => "urgent"}]
      )

      assert {:accepted, email} = send_to(ctx, address(ctx, :card), "Hi", "Nothing pressing.")
      assert card!(email).flags == []
    end

    test "a card made by hand, or by mail but in another list, sets nothing off", ctx do
      [todo | _] = ctx.board.columns

      rule =
        rule(ctx.board, %{"type" => "card_emailed", "column" => "Done"}, [
          %{"type" => "add_flags", "flags" => ["review"]}
        ])

      {:ok, by_hand} = Boards.create_card(todo, %{"title" => "Typed in"})
      assert Repo.get!(Card, by_hand.id).flags == []

      assert {:accepted, email} = send_to(ctx, address(ctx, :card), "Lands in To Do")
      assert card!(email).flags == []
      assert runs(rule) == 0
    end

    test "fires for mail to a personal add- address, on the board it lands on", ctx do
      [todo | _] = ctx.board.columns

      {:ok, user} =
        Accounts.update_quick_add(ctx.user, %{
          "quick_add_board_id" => ctx.board.id,
          "quick_add_column_id" => todo.id,
          "quick_add_ai" => false
        })

      ctx = %{ctx | user: user}

      rule(ctx.board, %{"type" => "card_emailed"}, [
        %{"type" => "add_flags", "flags" => ["review"]}
      ])

      {:ok, add} = Tokens.address(user, nil, :add)
      assert {:accepted, email} = send_to(ctx, add, "Buy stamps")
      assert card!(email).flags == ["review"]
    end

    test "a rule that fails doesn't bounce the mail", ctx do
      rule =
        rule(ctx.board, %{"type" => "card_emailed"}, [
          %{"type" => "move_card", "column" => "No such list"}
        ])

      assert {:accepted, email} = send_to(ctx, address(ctx, :card), "Still made")
      assert card!(email).title == "Still made"
      assert Repo.get!(Rule, rule.id).last_error =~ "no list called"
    end
  end

  describe "page_emailed" do
    test "flags, tags and prioritises a page that mail makes", ctx do
      tag_fixture(ctx.board, "inbox")

      rule(ctx.board, %{"type" => "page_emailed"}, [
        %{"type" => "add_flags", "flags" => ["review"]},
        %{"type" => "add_tags", "tags" => ["inbox"]},
        %{"type" => "set_priority", "priority" => "high"}
      ])

      assert {:accepted, email} = send_to(ctx, address(ctx, :page), "Meeting notes")
      page = page!(email)
      assert page.flags == ["review"]
      assert page.priority == "high"
      assert Enum.map(page.tags, & &1.name) == ["inbox"]
    end

    test "how: added fires for a + Title append, not for a new page", ctx do
      rule =
        rule(ctx.board, %{"type" => "page_emailed", "how" => "added"}, [
          %{"type" => "add_flags", "flags" => ["review"]}
        ])

      assert {:accepted, made} = send_to(ctx, address(ctx, :page), "Journal")
      assert page!(made).flags == []
      assert runs(rule) == 0

      assert {:accepted, added} = send_to(ctx, address(ctx, :page), "+ Journal", "Day two.")
      assert added.page_id == made.page_id
      assert page!(added).flags == ["review"]
    end

    test "how: new skips an append", ctx do
      {:accepted, _} = send_to(ctx, address(ctx, :page), "Journal")

      rule =
        rule(ctx.board, %{"type" => "page_emailed", "how" => "new"}, [
          %{"type" => "add_flags", "flags" => ["review"]}
        ])

      assert {:accepted, _} = send_to(ctx, address(ctx, :page), "+ Journal", "More.")
      assert runs(rule) == 0
    end

    test "folder: only pages filed in that folder, by path", ctx do
      rule(ctx.board, %{"type" => "page_emailed", "folder" => "notes/calls/"}, [
        %{"type" => "add_flags", "flags" => ["review"]}
      ])

      assert {:accepted, inbox} = send_to(ctx, address(ctx, :page), "Loose note")
      assert page!(inbox).flags == []

      assert {:accepted, filed} = send_to(ctx, address(ctx, :page), "[Notes/Calls] With Sam")
      assert page!(filed).flags == ["review"]
    end

    test "fires for a folder's own address", ctx do
      {:ok, folder} = Folders.create(ctx.board, %{"name" => "Clippings"})
      folder = Repo.preload(folder, :board)

      rule(ctx.board, %{"type" => "page_emailed", "folder" => "Clippings"}, [
        %{"type" => "add_flags", "flags" => ["review"]}
      ])

      assert {:accepted, email} = send_to(ctx, address(ctx, :page, folder), "An article")
      assert page!(email).flags == ["review"]
    end

    test "alerts and logs with the page's placeholders", ctx do
      rule(ctx.board, %{"type" => "page_emailed"}, [
        %{"type" => "alert", "title" => "{{page.code}} {{page.title}} in {{page.folder}}"},
        %{"type" => "log", "message" => "{{page.url}} from {{email.from}}"}
      ])

      assert {:accepted, email} = send_to(ctx, address(ctx, :page), "Spec draft")
      page = page!(email)

      assert [alert] = Automations.list_alerts(ctx.user)
      assert alert.title == "#{page.code} Spec draft in Inbox"
      assert alert.card_id == nil

      logged =
        Repo.all(
          from a in Activity,
            where: a.board_id == ^ctx.board.id and a.kind == "automation",
            select: a.message
        )

      assert "#{Automations.Runner.base_url()}/boards/#{ctx.board.id}/wiki/#{page.slug} from #{ctx.user.email}" in logged
    end

    test "a webhook is sent the page and the mail, with no card", ctx do
      test = self()

      Req.Test.stub(Slipdock.Automations.Notifier, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:callback, body})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      rule(ctx.board, %{"type" => "page_emailed"}, [
        %{"type" => "add_flags", "flags" => ["review"]},
        %{"type" => "webhook", "url" => "https://example.com/hooks/pages"}
      ])

      assert {:accepted, email} = send_to(ctx, address(ctx, :page), "Clipped", "Body text.")
      page = page!(email)

      assert_received {:callback, body}
      payload = Jason.decode!(body)
      assert payload["event"] == "page_emailed"
      assert payload["card"] == nil
      assert payload["email"] == %{"from" => ctx.user.email, "subject" => "Clipped"}

      assert %{"id" => id, "code" => code, "title" => "Clipped", "folder" => "Inbox"} =
               payload["page"]

      assert {id, code} == {page.id, page.code}
      # The webhook saw the page as the action before it left it.
      assert payload["page"]["flags"] == ["review"]
    end

    test "a card rule doesn't fire for a page, nor a page rule for a card", ctx do
      card_rule =
        rule(ctx.board, %{"type" => "card_emailed"}, [%{"type" => "log", "message" => "c"}])

      page_rule =
        rule(ctx.board, %{"type" => "page_emailed"}, [%{"type" => "log", "message" => "p"}])

      {:accepted, _} = send_to(ctx, address(ctx, :page), "A page")
      assert {runs(card_rule), runs(page_rule)} == {0, 1}

      {:accepted, _} = send_to(ctx, address(ctx, :card), "A card")
      assert {runs(card_rule), runs(page_rule)} == {1, 1}
    end
  end
end
