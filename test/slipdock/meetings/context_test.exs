defmodule Slipdock.Meetings.ContextTest do
  @moduledoc """
  What a capture reads alongside the meeting (#533): cards and pages named by
  id, by title and by similarity, only from the boards in scope and only
  what the capture's owner can open (G12), each with its version (G7), and
  the decisions already written down.
  """
  # Semantic search goes through the boot-started indexer and the shared AI
  # stub, so this cannot run alongside other tests.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Boards, Meetings, Search, Wiki}
  alias Slipdock.Meetings.{Context, Version}

  setup do
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()

    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Pricing", "code" => "PL"}, owner: owner)
    column = hd(board.columns)
    %{owner: owner, board: board, column: column}
  end

  defp capture(board, owner, lines, attrs \\ %{}) do
    capture_fixture(
      board,
      owner,
      Map.put(
        attrs,
        :transcript,
        Enum.map_join(lines, "\n", & &1.text) <> "#{System.unique_integer()}"
      ),
      utterances: lines
    )
  end

  defp said(texts), do: Enum.map(texts, &%{speaker: "Sam", text: &1})

  defp refs(context), do: Enum.map(context["candidates"], &{&1["ref"], &1["strength"]})

  test "a card's code, its number and a page's code are links by id", ctx do
    card = card_fixture(ctx.column, %{"title" => "Annual plan pricing"})
    other = card_fixture(ctx.column, %{"title" => "Something else entirely"})
    {:ok, page} = Wiki.create_page(ctx.board, %{"title" => "Pricing principles"}, user: ctx.owner)

    capture =
      capture(
        ctx.board,
        ctx.owner,
        said(["Can you update PL-#{card.id} by Friday?", "See ##{other.id} and #{page.code}."])
      )

    context = Context.gather(capture)

    assert {"##{card.id}", "id"} in refs(context)
    assert {"##{other.id}", "id"} in refs(context)
    assert {page.code, "id"} in refs(context)

    [c] = Enum.filter(context["candidates"], &(&1["id"] == card.id and &1["type"] == "card"))
    assert c["lines"] == ["L1"]
    assert c["version"] == Version.of(card)
    assert c["title"] == "Annual plan pricing"
    assert context["stats"]["by_id"] == 3
  end

  test "a code for another board's card, or no card at all, is no link", ctx do
    elsewhere = board_fixture(%{"name" => "Ops", "code" => "OPS"}, owner: ctx.owner)
    theirs = card_fixture(hd(elsewhere.columns), %{"title" => "Ops thing"})

    capture =
      capture(ctx.board, ctx.owner, said(["PL-#{theirs.id} and OPS-#{theirs.id} and PL-999999"]))

    context = Context.gather(capture)

    refute Enum.any?(context["candidates"], &(&1["id"] == theirs.id))
  end

  test "a title said aloud is a link by name; a one-word title is not", ctx do
    card = card_fixture(ctx.column, %{"title" => "Refresh the pricing page"})
    card_fixture(ctx.column, %{"title" => "Misc"})

    capture =
      capture(
        ctx.board,
        ctx.owner,
        said(["So, refresh the pricing page — who's on it?", "misc misc"])
      )

    context = Context.gather(capture)

    assert {"##{card.id}", "name"} in refs(context)
    refute Enum.any?(context["candidates"], &(&1["title"] == "Misc"))
  end

  test "similar cards come back as links by similarity, and the search is counted", ctx do
    card =
      card_fixture(ctx.column, %{
        "title" => "Stripe webhook retries",
        "description" => "webhook retries backoff stripe"
      })

    {:ok, _} = Search.index_card(card.id)

    capture =
      capture(
        ctx.board,
        ctx.owner,
        said(["webhook calls from stripe keep failing, retries and backoff"])
      )

    {:ok, capture} = Meetings.gather_context(capture)

    assert {"##{card.id}", "similarity"} in refs(capture.context)
    assert capture.stats["context"]["semantic"] == true
    assert capture.stats["context"]["searches"] == 1
    assert capture.stats["context"]["candidates"] == length(capture.context["candidates"])
    assert is_integer(capture.stats["context"]["ms"])
  end

  test "a card the owner cannot read is never returned, even as the best match", ctx do
    stranger = user_fixture("stranger@example.com")
    private = board_fixture(%{"name" => "Private", "code" => "PRV"}, owner: stranger)

    secret =
      card_fixture(hd(private.columns), %{
        "title" => "Stripe webhook retries",
        "description" => "stripe webhook retries backoff"
      })

    {:ok, _} = Search.index_card(secret.id)

    capture =
      capture(
        ctx.board,
        ctx.owner,
        said(["Stripe webhook retries, see ##{secret.id} and PRV-#{secret.id}"])
      )

    context = Context.gather(capture)
    refute Enum.any?(context["candidates"], &(&1["id"] == secret.id and &1["type"] == "card"))
  end

  test "a member who sends a capture reads the board as members do", ctx do
    # The other side of G12: a member who sends a capture sees what members see.
    member = user_fixture("member@example.com")
    share_fixture(ctx.board, [member], "write")
    card = card_fixture(ctx.column, %{"title" => "Annual plan pricing"})

    capture = capture(ctx.board, member, said(["annual plan pricing it is"]))
    assert {"##{card.id}", "name"} in refs(Context.gather(capture))
  end

  test "the parent board is read only when asked", ctx do
    parent_card = card_fixture(ctx.column, %{"title" => "Launch epic"})
    {:ok, template} = Boards.find_template("Simple")
    {:ok, sub} = sub_board(parent_card, template)
    up_there = card_fixture(ctx.column, %{"title" => "Partner announcement draft"})

    lines = said(["the partner announcement draft is late"])

    without = Context.gather(capture(sub, ctx.owner, lines))
    refute Enum.any?(without["candidates"], &(&1["id"] == up_there.id))

    with_parent =
      Context.gather(
        capture(sub, ctx.owner, lines, %{
          context_scope: %{"board" => true, "wiki" => true, "parent" => true}
        })
      )

    assert {"##{up_there.id}", "name"} in refs(with_parent)
  end

  test "decisions already written down are collected, struck-through ones as superseded", ctx do
    {:ok, _} =
      Wiki.create_page(
        ctx.board,
        %{
          "title" => "Decisions / Pricing",
          "body" => "- ~~Monthly plan only~~\n- Annual plan at 20% off\n\n### Free tier stays"
        },
        user: ctx.owner
      )

    {:ok, _} = Wiki.create_page(ctx.board, %{"title" => "Meeting notes"}, user: ctx.owner)

    context = Context.gather(capture(ctx.board, ctx.owner, said(["hello"])))

    assert [%{"title" => "Decisions / Pricing", "entries" => entries}] = context["decisions"]

    assert entries == [
             %{"text" => "Monthly plan only", "superseded" => true},
             %{"text" => "Annual plan at 20% off", "superseded" => false},
             %{"text" => "Free tier stays", "superseded" => false}
           ]
  end

  test "a card's version changes when it is edited, and a page's when its body does", ctx do
    card = card_fixture(ctx.column, %{"title" => "Before"})
    v1 = Version.of(card)
    {:ok, card} = Boards.update_card(card, %{"title" => "After"})
    refute Version.of(card) == v1
    assert Version.current("card", card.id) == Version.of(card)

    {:ok, page} = Wiki.create_page(ctx.board, %{"title" => "P", "body" => "one"}, user: ctx.owner)
    p1 = Version.of(page)
    {:ok, page} = Wiki.update_page(page, %{"body" => "two"}, user: ctx.owner)
    refute Version.of(page) == p1
    assert Version.current("page", -1) == nil
  end
end
