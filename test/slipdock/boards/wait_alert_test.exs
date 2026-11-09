defmodule Slipdock.Boards.WaitAlertTest do
  @moduledoc """
  A wait addressed to me alerts me (#2095, `Slipdock.Boards.WaitAlert`):
  an alert in the header that only I see, and the wait's email, each on by
  default and switchable in account settings. A card past its board's
  rejection limit asks its person through a wait, so it alerts the same
  way. A wait on someone else never alerts me. The alert comes down when
  the wait closes, by any route (#2636).
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Accounts, Actor, Automations, Boards, Repo, Verified}
  alias Slipdock.Automations.Alert
  alias Slipdock.Boards.{Card, WaitAlert}

  setup do
    owner = user_fixture("wa-owner@example.com")
    dana = user_fixture("wa-dana@example.com")
    board = board_fixture(%{"name" => "Alerts", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)
    %{owner: owner, dana: dana, board: board, todo: todo, doing: doing}
  end

  defp agent(user, label \\ nil),
    do: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: user.id, agent: label}

  defp wait_on(card, actor, on) do
    {:ok, wait} =
      Boards.open_wait(card, actor, %{"needs" => "Which region?", "on_user_id" => on.id})

    wait
  end

  defp mine(user), do: Enum.filter(Automations.list_alerts(user), &(&1.user_id == user.id))

  test "a wait on me raises an alert only I see, and emails me", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Deploy"})
    wait_on(card, agent(ctx.dana), ctx.owner)

    assert [alert] = mine(ctx.owner)
    assert alert.title == "Waiting on you: ##{card.id} “Deploy”"
    assert alert.body == "Which region?"
    assert alert.severity == "warning"
    assert alert.card_id == card.id

    # Dana can read the board, but the alert is mine.
    refute Enum.any?(Automations.list_alerts(ctx.dana), &(&1.id == alert.id))

    assert_email_sent(fn email ->
      assert email.to == [{"", ctx.owner.email}]
      assert email.subject =~ "is waiting on you"
    end)
  end

  test "an agent asking under my own token still alerts me: the question is mine", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Region"})
    wait_on(card, agent(ctx.owner), ctx.owner)
    assert [_] = mine(ctx.owner)
  end

  test "asking myself in person alerts nobody", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Note to self"})
    wait_on(card, Actor.web(ctx.owner), ctx.owner)

    assert mine(ctx.owner) == []
    assert_no_email_sent()
  end

  test "a wait on someone else doesn't alert me", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Hers"})
    wait_on(card, agent(ctx.owner), ctx.dana)

    assert mine(ctx.owner) == []
    refute Enum.any?(Automations.list_alerts(ctx.owner), &(&1.card_id == card.id))
    assert [%{card_id: id}] = mine(ctx.dana)
    assert id == card.id
  end

  test "a wait on anyone alerts nobody", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Anyone"})
    {:ok, _} = Boards.open_wait(card, agent(ctx.dana), %{"needs" => "Anyone?"})
    assert Repo.all(from(a in Alert, where: a.card_id == ^card.id)) == []
  end

  test "both are on by default, and each switches off on its own", ctx do
    assert ctx.owner.waiting_alerts
    assert ctx.owner.waiting_emails

    {:ok, _} = Accounts.update_waiting_notice(ctx.owner, %{waiting_alerts: false})
    wait_on(card_fixture(ctx.todo, %{"title" => "Quiet"}), agent(ctx.dana), ctx.owner)
    assert mine(ctx.owner) == []
    assert_email_sent(fn email -> assert email.to == [{"", ctx.owner.email}] end)

    {:ok, _} =
      Accounts.update_waiting_notice(Repo.reload!(ctx.owner), %{
        waiting_alerts: true,
        waiting_emails: false
      })

    wait_on(card_fixture(ctx.todo, %{"title" => "Loud"}), agent(ctx.dana), ctx.owner)
    assert [_] = mine(ctx.owner)
    assert_no_email_sent()
  end

  test "a card of mine hitting the rejection limit alerts me", ctx do
    {:ok, _} =
      Boards.update_board(ctx.board, %{"verify_work" => true, "verify_rejection_limit" => 1})

    card = card_fixture(ctx.doing, %{"title" => "Twice"})

    for _ <- 1..2 do
      {:ok, _} =
        Boards.update_card(
          Repo.get!(Card, card.id),
          %{"completed" => true, "evidence" => "ran it"},
          actor: agent(ctx.owner, "builder")
        )

      {:ok, _} =
        Verified.decide(
          Repo.get!(Card, card.id),
          "reject",
          %{"reason" => "bar 1: missing"},
          agent(ctx.owner, "checker"),
          ctx.owner
        )
    end

    assert Boards.current_wait(Repo.get!(Card, card.id)).purpose == "verify_limit"
    assert [alert] = mine(ctx.owner)
    assert alert.title == "Past the rejection limit: ##{card.id} “Twice”"
    assert mine(ctx.dana) == []
  end

  describe "the alert comes down when its wait closes (#2636)" do
    defp alerted(ctx, title, attrs \\ %{}) do
      card = card_fixture(ctx.todo, %{"title" => title})

      {:ok, wait} =
        Boards.open_wait(
          card,
          agent(ctx.dana),
          Map.merge(%{"needs" => "Which region?", "on_user_id" => ctx.owner.id}, attrs)
        )

      assert [%{card_id: id}] = mine(ctx.owner)
      assert id == card.id
      {Repo.get!(Card, card.id), wait}
    end

    test "answering it", ctx do
      {card, _} = alerted(ctx, "Answered")
      {:ok, _} = Boards.answer_wait(card, Actor.web(ctx.owner), %{"answer" => "eu-west"})
      assert mine(ctx.owner) == []
    end

    test "skipping it", ctx do
      {card, _} = alerted(ctx, "Skipped")
      {:ok, _} = Boards.answer_wait(card, Actor.web(ctx.owner), %{"skip" => true})
      assert mine(ctx.owner) == []
    end

    test "withdrawing it", ctx do
      {card, _} = alerted(ctx, "Withdrawn")
      {:ok, _} = Boards.withdraw_wait(card, agent(ctx.dana))
      assert mine(ctx.owner) == []
    end

    test "taking the waiting flag off, which withdraws it", ctx do
      {card, _} = alerted(ctx, "Unflagged")
      {:ok, _} = Boards.update_card(card, %{"flags" => []}, by: ctx.owner)
      assert Boards.current_wait(card) == nil
      assert mine(ctx.owner) == []
    end

    test "its default standing, the server's own close", ctx do
      {_card, wait} =
        alerted(ctx, "Defaulted", %{
          "question" => "other",
          "choices" => ["Ship", "Hold"],
          "default_choice" => 1
        })

      {:ok, closed} = Boards.default_wait(wait, "4h")
      assert closed.close_reason == "answered"
      assert mine(ctx.owner) == []
    end

    test "completing its card", ctx do
      {card, _} = alerted(ctx, "Completed")
      {:ok, _} = Boards.update_card(card, %{"completed" => true}, by: ctx.owner)
      assert Boards.last_wait(card).close_reason == "card_completed"
      assert mine(ctx.owner) == []
    end

    test "archiving its card", ctx do
      {card, _} = alerted(ctx, "Archived")
      {:ok, _} = Boards.archive_card(card, by: ctx.owner)
      assert Boards.last_wait(card).close_reason == "archived"
      assert mine(ctx.owner) == []
    end

    test "only that card's: a wait open on another card keeps its alert", ctx do
      {card, _} = alerted(ctx, "Closing")
      other = card_fixture(ctx.todo, %{"title" => "Still open"})
      wait_on(other, agent(ctx.dana), ctx.owner)

      {:ok, _} = Boards.answer_wait(card, Actor.web(ctx.owner), %{"answer" => "eu-west"})
      assert [%{card_id: id}] = mine(ctx.owner)
      assert id == other.id
    end

    test "a rule's alert on the card stays up", ctx do
      {card, _} = alerted(ctx, "Ruled")

      {:ok, rule_alert} =
        Automations.raise_alert(%{
          "title" => "Everyone sees this",
          "board_id" => ctx.board.id,
          "card_id" => card.id
        })

      {:ok, _} = Boards.answer_wait(card, Actor.web(ctx.owner), %{"answer" => "eu-west"})
      assert Enum.map(Automations.list_alerts(ctx.owner), & &1.id) == [rule_alert.id]
    end

    test "a later wait on the same card raises an alert that stands", ctx do
      {card, _} = alerted(ctx, "Twice asked")
      {:ok, _} = Boards.answer_wait(card, Actor.web(ctx.owner), %{"answer" => "eu-west"})
      assert mine(ctx.owner) == []

      wait_on(Repo.get!(Card, card.id), agent(ctx.dana), ctx.owner)
      assert [later] = mine(ctx.owner)
      assert later.card_id == card.id
      assert Repo.aggregate(from(a in Alert, where: a.card_id == ^card.id), :count) == 2
    end
  end

  test "the rejection-limit alert comes down when its wait is answered", ctx do
    {:ok, _} =
      Boards.update_board(ctx.board, %{"verify_work" => true, "verify_rejection_limit" => 1})

    card = card_fixture(ctx.doing, %{"title" => "Limit"})

    for _ <- 1..2 do
      {:ok, _} =
        Boards.update_card(
          Repo.get!(Card, card.id),
          %{"completed" => true, "evidence" => "ran it"},
          actor: agent(ctx.owner, "builder")
        )

      {:ok, _} =
        Verified.decide(
          Repo.get!(Card, card.id),
          "reject",
          %{"reason" => "bar 1: missing"},
          agent(ctx.owner, "checker"),
          ctx.owner
        )
    end

    assert [%{title: "Past the rejection limit" <> _}] = mine(ctx.owner)

    {:ok, closed} =
      Boards.answer_wait(Repo.get!(Card, card.id), Actor.web(ctx.owner), %{"choice" => 1})

    assert closed.purpose == "verify_limit"
    assert mine(ctx.owner) == []
  end

  test "a long title is clipped to the alert's limit" do
    card = %Card{id: 1, title: String.duplicate("x", 300)}
    title = WaitAlert.title(%Slipdock.Boards.Wait{}, card)
    assert String.length(title) == 200
    assert String.ends_with?(title, "…")
  end

  test "tell? is false with nobody named", ctx do
    card = card_fixture(ctx.todo)
    refute WaitAlert.tell?(%Slipdock.Boards.Wait{on_user: nil}, card)
  end
end
