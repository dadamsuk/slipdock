defmodule SlipdockWeb.Meetings.ChatReviewTest do
  @moduledoc """
  Reviewing and committing a conversation (#1077): the same review, digest
  and undo as a meeting; a touched card's trail reads *From a conversation*
  and links to the capture; review copy that says conversation; and
  `keep_transcript: false` dropping the lines once committed while the
  quoted evidence stays.
  """
  # Committing indexes cards through the boot-started indexer and the shared
  # AI stub.
  use SlipdockWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Slipdock.Fixtures

  alias Slipdock.{Meetings, Repo}
  alias Slipdock.Meetings.{Commit, Evidence, Ingest, Pipeline, Provenance, Undo, Utterance}

  @chat """
  User: Should we ship the pricing page on Friday?
  Assistant: I'd suggest Friday.
  User: Yes. I'll tell sales today.
  """

  @findings %{
    "findings" => [
      %{
        "kind" => "action",
        "title" => "Tell sales",
        "evidence" => [%{"line" => "L3", "quote" => "I'll tell sales today."}]
      }
    ]
  }

  setup %{user: user} do
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()
    {:ok, _} = Slipdock.Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    %{board: board}
  end

  defp ready_chat(ctx, params \\ %{}) do
    {:ok, capture} =
      Ingest.ingest(
        ctx.board,
        ctx.user,
        Map.merge(
          %{
            kind: "chat",
            transcript: @chat,
            title: "Pricing chat",
            findings: Jason.encode!(@findings)
          },
          params
        )
      )

    capture = Pipeline.run(capture)
    assert capture.state == "ready"
    capture
  end

  defp commit(ctx, capture) do
    {:ok, capture} = Commit.commit(capture, ctx.user)
    [create | _] = capture.change_set["changes"]
    {capture, create["card_id"]}
  end

  test "commit makes the card, its trail reads From a conversation and links the capture",
       ctx do
    {capture, card_id} = commit(ctx, ready_chat(ctx))
    assert capture.state == "committed"

    assert [%Provenance{source: "chat", meeting: "Pricing chat"}] = Provenance.for_card(card_id)

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card_id}")
    block = view |> element("#card-provenance") |> render()
    assert block =~ "From a conversation"
    refute block =~ "From a meeting"
    assert block =~ "Made from “Pricing chat”"
    assert block =~ "“I&#39;ll tell sales today.”"

    assert view
           |> element("#card-provenance a[href='/boards/#{ctx.board.id}/meetings/#{capture.id}']")
           |> render() =~ "Open the conversation"
  end

  test "undo takes the card back", ctx do
    {capture, card_id} = commit(ctx, ready_chat(ctx))
    {:ok, _} = Undo.undo(capture, ctx.user)

    # The card it made is archived; its trail stays with it, as a meeting's does.
    assert Repo.get!(Slipdock.Boards.Card, card_id).archived_at
    assert Meetings.get_capture!(capture.id).undone_at
  end

  test "a card from a meeting and a conversation says both", ctx do
    {_capture, card_id} = commit(ctx, ready_chat(ctx))

    Provenance.record(
      %Slipdock.Boards.Card{id: card_id},
      %{"source" => "meeting", "meeting" => "Pricing sync", "quote" => "ok"},
      "changed"
    )

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card_id}")
    assert view |> element("#card-provenance h3") |> render() =~ "From meetings and conversations"
  end

  describe "keep_transcript" do
    test "kept by default: the lines are still there after commit", ctx do
      capture = ready_chat(ctx)
      assert capture.keep_transcript
      {capture, _} = commit(ctx, capture)

      assert Repo.aggregate(from(u in Utterance, where: u.capture_id == ^capture.id), :count) == 3
      refute Meetings.get_capture!(capture.id).transcript_dropped_at
    end

    test "false: the lines go once committed, the evidence stays", ctx do
      capture = ready_chat(ctx, %{keep_transcript: "false"})
      refute capture.keep_transcript
      # Not before the commit: the review needs them.
      assert Repo.aggregate(from(u in Utterance, where: u.capture_id == ^capture.id), :count) == 3

      {capture, card_id} = commit(ctx, capture)
      capture = Meetings.get_capture!(capture.id)

      assert Repo.aggregate(from(u in Utterance, where: u.capture_id == ^capture.id), :count) == 0
      assert capture.transcript == nil
      assert capture.transcript_dropped_at

      [evidence] =
        Repo.all(
          from(e in Evidence,
            join: f in assoc(e, :finding),
            where: f.capture_id == ^capture.id and f.status == "kept"
          )
        )

      assert evidence.quote == "I'll tell sales today."
      assert evidence.speaker
      assert [%Provenance{quote: "I'll tell sales today."}] = Provenance.for_card(card_id)

      assert Enum.any?(Repo.preload(capture, :events).events, &(&1.kind == "transcript_dropped"))

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{capture.id}")
      assert html =~ "transcript dropped after commit"

      # Undo still works without the lines.
      assert {:ok, _} = Undo.undo(capture, ctx.user)
    end

    test "the preview's tick decides it, until committed", ctx do
      capture = ready_chat(ctx)

      {:ok, view, _} =
        live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{capture.id}/preview")

      assert render(view) =~ "Keep the conversation after"

      view
      |> form("#keep-transcript-form", %{"keep_transcript" => "false"})
      |> render_change()

      refute Meetings.get_capture!(capture.id).keep_transcript

      view
      |> form("#keep-transcript-form", %{"keep_transcript" => "true"})
      |> render_change()

      assert Meetings.get_capture!(capture.id).keep_transcript

      {capture, _} = commit(ctx, Meetings.get_capture!(capture.id))

      assert {:error, cs} =
               capture |> Slipdock.Meetings.Capture.keep_changeset(false) |> Repo.update()

      assert %{keep_transcript: ["can't change once the capture is committed"]} =
               Slipdock.DataCase.errors_on(cs)
    end

    test "the API takes it, and shows it", ctx do
      body =
        ctx.conn
        |> post(~p"/api/boards/#{ctx.board.id}/captures", %{
          "kind" => "chat",
          "transcript" => @chat,
          "keep_transcript" => "false"
        })
        |> json_response(201)

      assert body["capture"]["keep_transcript"] == false
      assert body["capture"]["transcript_dropped_at"] == nil
    end
  end

  describe "review copy" do
    test "the review page and its nav say conversation", ctx do
      capture = ready_chat(ctx)
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{capture.id}")
      # Meeting mode is off: the nav names the conversation, not the Meetings list.
      assert html =~ "Conversation"

      refute html =~ ~s(href="/boards/#{ctx.board.id}/meetings")
    end

    test "while reading, it says it is reading the conversation", ctx do
      {:ok, capture} =
        Ingest.ingest(ctx.board, ctx.user, %{
          kind: "chat",
          transcript: @chat,
          title: "Pricing chat"
        })

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{capture.id}")
      assert html =~ "Reading the conversation"
      refute html =~ "Reading the meeting"
    end

    test "the ready email is about a conversation", ctx do
      ready_chat(ctx)

      assert_email_sent(fn email ->
        assert email.subject == "Conversation ready for review: Pricing chat"
      end)
    end
  end
end
