defmodule SlipdockWeb.Meetings.ProvenanceTest do
  @moduledoc """
  Provenance (#540, G11): a card made or changed by a meeting says so on the
  card — meeting, time, words, speaker, how it was read, who committed —
  and keeps saying so after the capture and its recording are gone; a
  decision that replaces another strikes it and links both ways; and words
  said in the meeting find the card in search.
  """
  # Search goes through the boot-started indexer and the shared AI stub.
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Boards, Meetings, Repo, Search, Wiki}
  alias Slipdock.Meetings.{Commit, Provenance, Undo, Version}
  alias Slipdock.Search.Indexer

  setup %{user: user} do
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()
    meetings_on()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    %{board: board}
  end

  defp commit_action(ctx, extra \\ []) do
    finding =
      action_finding(nil, %{
        "owner" => nil,
        "title" => "Tell sales",
        "evidence" => [%{"line" => "L4", "quote" => "Yes, that's mine."}]
      })

    capture = reviewed_capture(ctx.board, ctx.user, [finding | extra])
    {:ok, capture} = Commit.commit(capture, ctx.user)
    [create | _] = capture.change_set["changes"]
    {capture, create["card_id"]}
  end

  test "the card says where it came from", ctx do
    {_capture, card_id} = commit_action(ctx)

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card_id}")
    block = view |> element("#card-provenance") |> render()

    assert block =~ "From a meeting"
    assert block =~ "Made from “Pricing sync”"
    assert block =~ "7 Oct 2026"
    assert block =~ "at 0:14"
    assert block =~ "“Yes, that&#39;s mine.”"
    assert block =~ "— Sam"
    assert block =~ "Read as: quoted word for word"
    assert block =~ "Committed by #{ctx.user.email}"
  end

  test "it outlives the capture and its recording", ctx do
    {capture, card_id} = commit_action(ctx)
    {:ok, _} = Meetings.delete_capture(capture)

    assert [%Provenance{capture_id: nil, quote: "Yes, that's mine."}] =
             Provenance.for_card(card_id)

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card_id}")
    assert view |> element("#card-provenance") |> render() =~ "Yes, that&#39;s mine."
  end

  test "a card without a meeting behind it shows nothing of the sort", ctx do
    card = card_fixture(hd(ctx.board.columns), %{"title" => "Plain"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")
    refute has_element?(view, "#card-provenance")
  end

  test "a changed card's provenance goes when the change is undone", ctx do
    card =
      card_fixture(Enum.find(ctx.board.columns, &(&1.name == "To Do")), %{
        "title" => "Pricing page refresh"
      })

    candidate = %{
      "type" => "card",
      "id" => card.id,
      "ref" => "##{card.id}",
      "title" => card.title,
      "lines" => ["L3"],
      "strength" => "id",
      "version" => Version.of(card)
    }

    change = %{
      "kind" => "card_change",
      "title" => "Due Friday",
      "card" => "##{card.id}",
      "change" => %{"field" => "due_date", "to" => "2026-10-09"},
      "evidence" => [%{"line" => "L3", "quote" => "update PL-14 by Friday"}]
    }

    capture = reviewed_capture(ctx.board, ctx.user, [change], %{"candidates" => [candidate]})
    {:ok, capture} = Commit.commit(capture, ctx.user)
    assert [%Provenance{kind: "changed"}] = Provenance.for_card(card.id)

    {:ok, _} = Undo.undo(capture, ctx.user)
    assert Provenance.for_card(card.id) == []
  end

  test "a decision replacing one on another page strikes it there, linking both ways", ctx do
    {:ok, plans} =
      Wiki.create_page(
        ctx.board,
        %{"title" => "Decisions / Plans", "body" => "- Monthly plan only\n- Free tier stays\n"},
        user: ctx.user
      )

    capture =
      reviewed_capture(ctx.board, ctx.user, [
        decision_finding(%{"supersedes" => "Monthly plan only"})
      ])

    {:ok, capture} = Commit.commit(capture, ctx.user)

    plans = Repo.reload!(plans)

    assert plans.body =~
             "- ~~Monthly plan only~~ (replaced by “Annual plan at 20% off” on [[decisions-pricing-sync-7-oct-2026|Decisions / Pricing sync · 7 Oct 2026]])"

    assert plans.body =~ "- Free tier stays"

    [pricing] =
      Enum.filter(
        capture.change_set["changes"],
        &(&1["page_title"] == "Decisions / Pricing sync · 7 Oct 2026")
      )

    page = Repo.get!(Wiki.Page, pricing["page_id"])
    assert page.body =~ "**Annual plan at 20% off**"
    assert page.body =~ "Replaces “Monthly plan only” on [[decisions-plans|Decisions / Plans]]."
    assert page.body =~ "Sam: “We go with the annual plan at 20% off.”"

    # The link resolves: the replaced page knows who points at it.
    assert Enum.any?(Wiki.Links.backlinks(plans), &(&1.page_id == page.id and &1.resolved))
  end

  test "words said in the meeting find the card", ctx do
    {_capture, card_id} =
      commit_action(ctx, [])

    Indexer.flush()
    {:ok, results} = Search.search(ctx.user, "that's mine", kind: :card)

    assert Enum.any?(
             results,
             &((&1.card && &1.card.id == card_id) and
                 Enum.any?(&1.matches, fn m -> m.kind == "provenance" end))
           )

    assert Boards.get_card!(card_id).title == "Tell sales"
  end
end
