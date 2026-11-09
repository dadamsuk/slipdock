defmodule Slipdock.NotifyTest do
  @moduledoc """
  Desktop toasts' server side (#2101): a wait opened on a person, a wait
  routed to them and an @mention of them each broadcast on that person's own
  topic (`Slipdock.Notify`), beside the email they already sent. Nobody gets
  one for their own doing, without read access to the card, or when the
  thing isn't about them; a write held back by `Slipdock.Deferred` tells
  nobody until it lets go.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Access, Actor, Boards, Notify, Repo, WaitRoutes}

  setup do
    domain = "#{System.unique_integer([:positive])}.example.com"
    owner = user_fixture("owner@#{domain}")
    board = board_fixture(%{"name" => "Toasts"}, owner: owner)
    {:ok, priya} = Slipdock.Accounts.get_or_create_user_by_email("priya@#{domain}")
    {:ok, priya} = priya |> Ecto.Changeset.change(name: "Priya") |> Repo.update()
    ops = user_fixture("ops@#{domain}")
    for u <- [priya, ops], do: {:ok, _} = Access.grant(board, u, "write", owner)
    stranger = user_fixture("stranger@#{domain}")
    card = card_fixture(Enum.at(board.columns, 1), %{"title" => "Pricing"})
    agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: "builder"}

    for u <- [owner, priya, ops, stranger], do: Notify.subscribe(u)

    %{
      owner: owner,
      board: board,
      priya: priya,
      ops: ops,
      stranger: stranger,
      card: card,
      agent: agent
    }
  end

  # Every toast this test process got, as {user_id, event}.
  defp toasts(acc \\ []) do
    receive do
      {:notify, event} -> toasts([{event.user_id, event} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  test "a person's topic is their own" do
    assert Notify.topic(7) == "notify:user:7"
    assert Notify.topic(%Slipdock.Accounts.User{id: 7}) == "notify:user:7"
  end

  test "send_email: false toasts without the email (a person's Email me off, #2095)", ctx do
    :ok =
      Notify.person(ctx.priya, ctx.card,
        kind: "wait",
        subject: "Waiting on you",
        body: "Which tier first?",
        send_email: false
      )

    assert [{id, %{kind: "wait", title: "Waiting on you"}}] = toasts()
    assert id == ctx.priya.id
    assert_no_email_sent()
  end

  describe "a wait opened on you" do
    test "toasts the person it is on, beside the unchanged email", ctx do
      {:ok, _} =
        Boards.open_wait(ctx.card, ctx.agent, %{
          "needs" => "Which tier first?",
          "on_user_id" => ctx.priya.id
        })

      assert_email_sent(fn email ->
        assert email.to == [{"", ctx.priya.email}]
        assert email.subject =~ "is waiting on you: “Pricing”"
      end)

      assert [{id, event}] = toasts()
      assert id == ctx.priya.id
      assert event.kind == "wait"
      assert event.by_id == ctx.owner.id
      assert event.card_id == ctx.card.id
      assert event.path == "/boards/#{ctx.card.board_id}/cards/#{ctx.card.id}"
      assert event.title =~ "is waiting on you"
      assert event.body == "Pricing: Which tier first?"
      assert "notify-" <> _ = event.id
    end

    test "tells nobody about a wait they opened on themselves in person", ctx do
      {:ok, _} =
        Boards.open_wait(ctx.card, Slipdock.Actor.web(ctx.owner), %{
          "needs" => "Note",
          "on_user_id" => ctx.owner.id
        })

      assert toasts() == []
      refute_email_sent()
    end

    test "tells them about one their agent asks under their token: the question is theirs (#2095)",
         ctx do
      {:ok, _} =
        Boards.open_wait(ctx.card, ctx.agent, %{"needs" => "Note", "on_user_id" => ctx.owner.id})

      owner_id = ctx.owner.id
      assert [{^owner_id, %{kind: "wait", by_id: nil}}] = toasts()
      assert_email_sent(fn email -> assert email.to == [{"", ctx.owner.email}] end)
    end

    test "with their Email me off, toasts them and sends no email (#2606)", ctx do
      {:ok, priya} =
        Slipdock.Accounts.update_waiting_notice(ctx.priya, %{waiting_emails: false})

      {:ok, _} =
        Boards.open_wait(ctx.card, ctx.agent, %{"needs" => "Tier?", "on_user_id" => priya.id})

      priya_id = priya.id
      owner_id = ctx.owner.id
      assert [{^priya_id, %{kind: "wait", by_id: ^owner_id}}] = toasts()
      assert_no_email_sent()
    end

    test "with their Email me off, their agent's question under their token still toasts (#2606)",
         ctx do
      {:ok, owner} =
        Slipdock.Accounts.update_waiting_notice(ctx.owner, %{waiting_emails: false})

      {:ok, _} =
        Boards.open_wait(ctx.card, ctx.agent, %{"needs" => "Note", "on_user_id" => owner.id})

      owner_id = owner.id
      assert [{^owner_id, %{kind: "wait", by_id: nil}}] = toasts()
      assert_no_email_sent()
    end

    test "tells nobody who can't read the card", ctx do
      wait = %Boards.Wait{
        on_user: ctx.stranger,
        on_user_id: ctx.stranger.id,
        opened_by_id: ctx.owner.id,
        opened_by: ctx.owner,
        needs: "?",
        questions: [],
        choices: []
      }

      assert :ok = Boards.WaitEmail.opened(wait, ctx.card)
      assert toasts() == []
      refute_email_sent()
    end

    test "on anyone toasts nobody", ctx do
      {:ok, _} = Boards.open_wait(ctx.card, ctx.agent, %{"needs" => "Anyone?"})
      assert toasts() == []
    end
  end

  describe "a wait routed to you" do
    test "toasts the one it is on and the rest of the route, once each", ctx do
      {:ok, _} =
        WaitRoutes.set(Repo.get!(Boards.Board, ctx.board.id), %{
          "product" => [ctx.priya.email, ctx.ops.email, ctx.owner.email]
        })

      {:ok, _} =
        Boards.open_wait(ctx.card, ctx.agent, %{"needs" => "Which tier?", "question" => "product"})

      got = toasts()
      assert got |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.sort([ctx.priya.id, ctx.ops.id])
      {_, routed} = Enum.find(got, fn {id, _} -> id == ctx.ops.id end)
      assert routed.kind == "wait_routed"
      assert routed.title =~ "(product)"

      # Each telling has its own tag; the asker (the owner) has none.
      assert got |> Enum.map(&elem(&1, 1).id) |> Enum.uniq() |> length() == 2
      refute Enum.any?(got, fn {id, _} -> id == ctx.owner.id end)
    end

    test "toasts nobody on the route who can't read the card", ctx do
      wait = %Boards.Wait{
        on_user_id: ctx.priya.id,
        opened_by_id: ctx.owner.id,
        opened_by: ctx.owner,
        needs: "?",
        question: "ux",
        questions: [],
        choices: []
      }

      assert :ok = Boards.WaitEmail.told(wait, ctx.card, [ctx.stranger])
      assert toasts() == []
      refute_email_sent()
    end
  end

  describe "an @mention" do
    test "in a comment toasts whoever it mentions, and only them", ctx do
      {:ok, _} = Boards.add_comment(ctx.card, "@priya can you look? @stranger too", by: ctx.owner)

      assert_email_sent(fn email -> assert email.to == [{"", ctx.priya.email}] end)
      assert [{id, event}] = toasts()
      assert id == ctx.priya.id
      assert event.kind == "mention"
      assert event.by_id == ctx.owner.id
      assert event.title == "#{ctx.owner.email} mentioned you on “Pricing”"
      assert event.body == "@priya can you look? @stranger too"
    end

    test "never toasts the writer about their own mention", ctx do
      {:ok, _} = Boards.add_comment(ctx.card, "note to self @priya", by: ctx.priya)
      assert toasts() == []
    end

    test "in a description toasts only the newly mentioned", ctx do
      {:ok, card} =
        Boards.update_card(ctx.card, %{"description" => "for @priya"}, by: ctx.owner)

      assert [{id, _}] = toasts()
      assert id == ctx.priya.id

      {:ok, _} =
        Boards.update_card(card, %{"description" => "for @priya and @ops"}, by: ctx.owner)

      assert [{id, _}] = toasts()
      assert id == ctx.ops.id
    end
  end

  describe "person/3" do
    test "sends at once outside a transaction, the toast's text cut short", ctx do
      assert :ok =
               Notify.person(ctx.priya, ctx.card,
                 subject: "Hello",
                 body: "Body",
                 text: String.duplicate("x", 500)
               )

      assert [{_, event}] = toasts()
      assert event.title == "Hello"
      assert String.length(event.body) == 240
      assert event.by_id == nil
      assert_email_sent(subject: "Hello")
    end

    test "held back in a write that may roll back, until it lets go", ctx do
      {:ok, effects} =
        Slipdock.Deferred.collect(fn ->
          Notify.person(ctx.priya, ctx.card, subject: "Later", body: "B", by: ctx.owner)
          :ok
        end)

      assert toasts() == []
      refute_email_sent()
      Slipdock.Deferred.run(effects)
      assert [{_, %{title: "Later", by_id: by}}] = toasts()
      assert by == ctx.owner.id
      assert_email_sent(subject: "Later")
    end

    test "goes only to the person's own topic", ctx do
      Phoenix.PubSub.unsubscribe(Slipdock.PubSub, Notify.topic(ctx.priya))
      Notify.person(ctx.priya, ctx.card, subject: "Only Priya", body: "B")
      assert toasts() == []
    end
  end
end
