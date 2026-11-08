defmodule SlipdockWeb.EpicSubcardsWaitingLiveTest do
  @moduledoc """
  An open epic's subcard list marks the rows waiting on you (#2126): a
  badge with the short reason on each row in the Waiting on you line, a
  quieter mark on a row waiting on someone else, nothing on the rest, and
  the line's #ids jumping to their rows.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo}
  alias Slipdock.Boards.{Board, Card}
  alias SlipdockWeb.BoardLive.SubcardWaiting

  setup do
    owner = user_fixture("esw-owner@example.com")
    dana = user_fixture("esw-dana@example.com")
    board = board_fixture(%{"name" => "Ops"}, owner: owner)
    [_backlog, todo | _] = board.columns
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)

    epic = card_fixture(todo, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)

    %{owner: owner, dana: dana, board: board, epic: epic, sub: sub, template: t}
  end

  defp agent(user), do: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: user.id}
  defp sub_card(ctx, title), do: card_fixture(hd(ctx.sub.columns), %{"title" => title})

  defp wait_on(card, by, on) do
    {:ok, wait} =
      Boards.open_wait(card, agent(by), %{"needs" => "Which region?", "on_user_id" => on.id})

    wait
  end

  defp circling(card, n) do
    from(c in Card, where: c.id == ^card.id)
    |> Repo.update_all(
      set: [
        verify_rejections: n,
        verify_state: "rejected",
        flags: ["review"],
        verify_at: DateTime.utc_now(:second)
      ]
    )
  end

  defp open_epic(ctx, user \\ nil) do
    {:ok, view, _} =
      live(
        log_in_user(build_conn(), user || ctx.owner),
        ~p"/boards/#{ctx.board.id}/cards/#{ctx.epic.id}"
      )

    view
  end

  defp mark(card), do: "#subcard-#{card.id}-waiting"
  defp quiet_mark(card), do: "#subcard-#{card.id}-waiting-others"

  test "each row on me carries its reason; someone else's a quieter mark; the rest nothing",
       ctx do
    asked = sub_card(ctx, "Region")
    wait_on(asked, ctx.owner, ctx.owner)
    limit = sub_card(ctx, "Circling")
    circling(limit, 3)
    theirs = sub_card(ctx, "Theirs")
    wait_on(theirs, ctx.owner, ctx.dana)
    quiet = sub_card(ctx, "Quiet")

    view = open_epic(ctx)

    assert has_element?(view, "#subcard-#{asked.id} " <> mark(asked), "a question")
    assert has_element?(view, "#subcard-#{limit.id} " <> mark(limit), "3 rejections")
    refute has_element?(view, mark(asked), "rejections")

    assert has_element?(view, "#subcard-#{theirs.id} " <> quiet_mark(theirs), "on ")
    refute has_element?(view, mark(theirs))
    refute has_element?(view, quiet_mark(asked))
    refute has_element?(view, quiet_mark(limit))

    refute has_element?(view, mark(quiet))
    refute has_element?(view, quiet_mark(quiet))

    # The reason is in words, not colour alone.
    html = view |> element(mark(asked)) |> render()
    assert html =~ "Waiting on you:"
  end

  test "the line's #ids link to their rows", ctx do
    asked = sub_card(ctx, "Region")
    wait_on(asked, ctx.owner, ctx.owner)
    limit = sub_card(ctx, "Circling")
    circling(limit, 3)
    wait_on(sub_card(ctx, "Theirs"), ctx.owner, ctx.dana)

    view = open_epic(ctx)

    line = view |> element("#subcards-waiting-line") |> render()
    assert line =~ "Waiting on you:"
    assert line =~ "(a question)"
    assert line =~ "(3 rejections)"
    assert line =~ "and 1 on someone else"

    for card <- [asked, limit] do
      assert has_element?(
               view,
               ~s(#subcards-waiting-line a[href="#subcard-#{card.id}"]),
               "##{card.id}"
             )

      assert has_element?(view, "li#subcard-#{card.id}")
    end
  end

  test "a card deeper down marks the subcard row it sits under, naming itself", ctx do
    parent = sub_card(ctx, "Parent")
    {:ok, inner} = sub_board(parent, ctx.template)
    inner = Boards.get_board!(inner.id)
    deep = card_fixture(hd(inner.columns), %{"title" => "Deep"})
    wait_on(deep, ctx.owner, ctx.owner)

    view = open_epic(ctx)

    assert has_element?(view, mark(parent), "##{deep.id} a question")

    assert has_element?(
             view,
             ~s(#subcards-waiting-line a[href="#subcard-#{parent.id}"]),
             "##{deep.id}"
           )

    refute has_element?(view, "li#subcard-#{deep.id}")
  end

  test "only someone else's: the line says so and no row is marked as mine", ctx do
    theirs = sub_card(ctx, "Theirs")
    wait_on(theirs, ctx.owner, ctx.dana)

    view = open_epic(ctx)

    assert has_element?(view, "#subcards-waiting-line", "Waiting on someone else: 1")
    refute has_element?(view, "#subcards-waiting-line", "Waiting on you")
    refute has_element?(view, mark(theirs))
    assert has_element?(view, quiet_mark(theirs))
  end

  test "dana sees her own question marked as hers, and the owner's as someone else's", ctx do
    theirs = sub_card(ctx, "Theirs")
    wait_on(theirs, ctx.owner, ctx.dana)

    view = open_epic(ctx, ctx.dana)
    assert has_element?(view, mark(theirs), "a question")
    refute has_element?(view, quiet_mark(theirs))
  end

  test "nothing waiting: no line and no marks", ctx do
    quiet = sub_card(ctx, "Quiet")

    view = open_epic(ctx)
    assert has_element?(view, "li#subcard-#{quiet.id}")
    refute has_element?(view, "#subcards-waiting-line")
    refute has_element?(view, mark(quiet))
    refute has_element?(view, quiet_mark(quiet))
  end

  test "the marks follow a wait as it opens and is answered", ctx do
    card = sub_card(ctx, "Region")
    view = open_epic(ctx)
    refute has_element?(view, mark(card))

    wait_on(card, ctx.owner, ctx.owner)
    assert has_element?(view, mark(card), "a question")

    {:ok, _} =
      Boards.answer_wait(Repo.get!(Card, card.id), Actor.web(ctx.owner), %{"answer" => "EU"})

    refute has_element?(view, mark(card))
    refute has_element?(view, "#subcards-waiting-line")
  end

  test "the in-app guide says the subcard list marks the rows", ctx do
    {:ok, view, _} = live(log_in_user(build_conn(), ctx.owner), ~p"/help/boards")
    part = view |> element("#boards-waiting") |> render() |> String.replace(~r/\s+/, " ")
    assert part =~ "its subcard list marks the same rows"
    assert part =~ "jump to their rows"
  end

  describe "SubcardWaiting" do
    test "build/2 with nothing waiting, or no sub-board, is empty" do
      empty = SubcardWaiting.empty()

      assert SubcardWaiting.build(%{mine: [], others: []}, %Card{sub_board: %Board{id: 1}}) ==
               empty

      assert SubcardWaiting.build(nil, %Card{sub_board: %Board{id: 1}}) == empty
      item = %{card: %Card{id: 5, board_id: 1}, reason: "wait"}
      assert SubcardWaiting.build(%{mine: [item], others: []}, %Card{sub_board: nil}) == empty
      assert SubcardWaiting.build(%{mine: [item], others: []}, nil) == empty
    end

    test "build/2 leaves an item it can't place on a row off the rows, but in the line" do
      placed = %{card: %Card{id: 5, board_id: 1}, reason: "verify"}
      unplaced = %{card: %Card{id: 6, board_id: 99}, reason: "wait"}

      got =
        SubcardWaiting.build(%{mine: [placed, unplaced], others: []}, %Card{
          sub_board: %Board{id: 1}
        })

      assert [%{id: 5, row: 5, reason: "to verify"}, %{id: 6, row: nil, reason: "a question"}] =
               got.mine

      assert Map.keys(got.rows) == [5]
      assert SubcardWaiting.row_entry(got, 7) == %{mine: [], others: []}
    end

    test "label/2 names a deeper card's id and drops repeats" do
      items = [
        %{id: 5, reason: "to verify"},
        %{id: 8, reason: "a question"},
        %{id: 9, reason: "a question"},
        %{id: 8, reason: "a question"}
      ]

      assert SubcardWaiting.label(items, 5) == "to verify, #8 a question, #9 a question"
    end
  end
end
