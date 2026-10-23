defmodule SlipdockWeb.WaitLiveTest do
  @moduledoc """
  A card's wait in the browser (#1114): the panel beneath the title with a
  button for each choice and a box for words, how many questions the card
  has asked, withdrawing, the flag toggle withdrawing it, who may answer,
  and the mark on the card's front. A card with no wait shows none of it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Actor, Boards}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Deploy"})
    %{board: board, card: card, owner: owner}
  end

  defp open(conn, ctx), do: live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

  defp ask(ctx, attrs \\ %{}) do
    agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: ctx.owner.id, agent: "claude"}

    {:ok, wait} =
      Boards.open_wait(ctx.card, agent, Map.merge(%{"needs" => "Which region?"}, attrs))

    wait
  end

  test "shows what it needs, who asked, and a button per choice", ctx do
    ask(ctx, %{"choices" => ["eu", "us"]})
    {:ok, view, html} = open(ctx.conn, ctx)

    assert has_element?(view, "#card-wait #wait-needs", "Which region?")
    assert has_element?(view, "#card-wait", "Waiting on anyone:")
    assert has_element?(view, "#wait-byline", "(agent: claude)")
    assert has_element?(view, "#wait-choice-1", "eu")
    assert has_element?(view, "#wait-choice-2", "us")
    assert has_element?(view, "#wait-answer-form textarea[placeholder='Or answer in words']")
    refute has_element?(view, "#wait-byline", "question")

    {title, _} = :binary.match(html, ~s(id="card-title-form"))
    {panel, _} = :binary.match(html, ~s(id="card-wait"))
    assert title < panel
  end

  test "clicking a choice answers it, as the person, and the panel goes", ctx do
    ask(ctx, %{"choices" => ["eu", "us"]})
    {:ok, view, _} = open(ctx.conn, ctx)

    view |> element("#wait-choice-2") |> render_click()

    assert %{close_reason: "answered", choice: 2, kind: "agent"} = Boards.last_wait(ctx.card)
    assert Boards.last_wait(ctx.card).closed_by_id == ctx.owner.id
    refute has_element?(view, "#card-wait")
    refute "waiting" in Boards.get_card!(ctx.card.id).flags
  end

  test "an answer in words, and the count once the card has asked more than once", ctx do
    ask(ctx)
    {:ok, _} = Boards.withdraw_wait(ctx.card, Actor.web(ctx.owner))
    ask(ctx, %{"needs" => "Size?"})
    {:ok, view, _} = open(ctx.conn, ctx)

    assert has_element?(view, "#wait-byline", "question 2 on this card")

    view
    |> form("#wait-answer-form", %{"wait" => %{"answers" => %{"1" => "Large"}}})
    |> render_submit()

    assert %{answer: "Large", close_reason: "answered"} = Boards.last_wait(ctx.card)
  end

  test "Withdraw closes it", ctx do
    ask(ctx)
    {:ok, view, _} = open(ctx.conn, ctx)
    view |> element("#wait-withdraw") |> render_click()
    assert %{close_reason: "withdrawn"} = Boards.last_wait(ctx.card)
  end

  test "turning the waiting flag off in the panel withdraws it, naming who (AE4)", ctx do
    ask(ctx)
    {:ok, view, _} = open(ctx.conn, ctx)

    render_click(
      view
      |> element("#card-modal [phx-click='toggle_flag'][phx-value-flag='waiting']")
    )

    assert %{close_reason: "withdrawn", closed_by_id: id} = Boards.last_wait(ctx.card)
    assert id == ctx.owner.id
  end

  test "a reader sees the question but no way to answer it", ctx do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
    ask(ctx, %{"choices" => ["eu"]})

    {:ok, view, _} = open(log_in_user(build_conn(), reader), ctx)
    assert has_element?(view, "#wait-needs", "Which region?")
    refute has_element?(view, "#wait-choice-1")
    refute has_element?(view, "#wait-answer-form")
  end

  test "the card's front shows what it is waiting on; a card with none shows nothing", ctx do
    plain = card_fixture(hd(ctx.board.columns), %{"title" => "Plain"})
    ask(ctx)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    assert has_element?(view, "#card-#{ctx.card.id} [data-role='wait-mark']", "Which region?")
    refute has_element?(view, "#card-#{plain.id} [data-role='wait-mark']")

    {:ok, _} = Boards.answer_wait(ctx.card, Actor.web(ctx.owner), %{"answer" => "eu"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    refute has_element?(view, "[data-role='wait-mark']")
  end

  test "a card with no wait has no panel", ctx do
    {:ok, view, _} = open(ctx.conn, ctx)
    refute has_element?(view, "#card-wait")
  end
end
