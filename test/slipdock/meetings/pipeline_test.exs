defmodule Slipdock.Meetings.PipelineTest do
  @moduledoc """
  The pipeline (#536): durable steps, each stored before the next, a
  restart resuming after the last one finished rather than from the start,
  failures that say why and can be retried, the person who sent it told when
  it is ready, and every step that costs something on the ledger.
  """
  use Slipdock.DataCase, async: true

  import Swoosh.TestAssertions
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{AIStub, Meetings, Repo}
  alias Slipdock.Meetings.{Capture, Event, Pipeline, UsageEntry}

  @decision %{
    "kind" => "decision",
    "title" => "Annual plan at 20% off",
    "evidence" => [%{"line" => "L2", "quote" => "We go with the annual plan at 20% off."}]
  }

  @unknown_owner %{
    "kind" => "action",
    "title" => "Update the page",
    "owner" => "Zed",
    "evidence" => [%{"line" => "L3", "quote" => "can you update PL-14"}]
  }

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Pricing"}, owner: owner)
    %{owner: owner, board: board, capture: capture_fixture(board, owner)}
  end

  defp requests do
    receive do
      {:ai_request, body} -> [body | requests()]
    after
      0 -> []
    end
  end

  defp events(capture),
    do:
      Repo.all(
        from(e in Event,
          where: e.capture_id == ^capture.id,
          order_by: e.id,
          select: {e.kind, e.message}
        )
      )

  test "a full run goes through every step, stores each, and ends ready", %{
    capture: capture,
    owner: owner
  } do
    AIStub.reply_with(%{"findings" => [@decision]})

    capture = Pipeline.start(capture, mode: :sync)

    assert capture.state == "ready"
    assert capture.step == "ready"
    assert capture.context["stats"]["candidates"] == 0
    assert [_] = capture.readings["1"]
    assert capture.stats["found"] == %{"kept" => 1, "dropped" => 0, "questions" => 0}

    kinds = Repo.all(from(u in UsageEntry, where: u.capture_id == ^capture.id, select: u.kind))
    # One reading by default.
    assert Enum.sort(kinds) == ["context", "reading"]

    assert_email_sent(fn email ->
      assert email.subject == "Meeting ready for review: Pricing sync"
      assert [{_, to}] = email.to
      assert to == owner.email
      assert email.text_body =~ "Nothing needs settling"
      assert email.text_body =~ "/boards/#{capture.board_id}/meetings/#{capture.id}"
    end)

    assert {"notified", _} = List.last(events(capture))
  end

  test "questions left open end it in needs_review, and the email says how many", %{
    capture: capture,
    board: board
  } do
    # Two Zeds on the board: which one is meant can't be left to a default.
    for {email, name} <- [{"zed.a@example.com", "Zed Adams"}, {"zed.b@example.com", "Zed Brown"}] do
      {:ok, zed} = Slipdock.Accounts.update_profile(user_fixture(email), %{"name" => name})
      share_fixture(board, [zed], "write")
    end

    AIStub.reply_with(%{"findings" => [@unknown_owner]})
    capture = Pipeline.start(capture, mode: :sync)

    assert capture.state == "needs_review"
    assert_email_sent(fn email -> assert email.text_body =~ "1 thing needs you to settle" end)
  end

  test "stopping between steps and starting again resumes after the last step stored", %{
    capture: capture
  } do
    AIStub.reply_with(%{"findings" => [@decision]})

    # Killed after the context was stored: the reading never happened.
    capture = Pipeline.start(capture, mode: :manual)
    capture = Pipeline.run(capture, stop_after: "context")
    assert capture.state == "reading" and capture.step == "context"
    assert requests() == []

    # Mark what the context step stored, so a second gathering would show.
    marked = put_in(capture.context, ["stats", "marker"], "first")
    Repo.update!(Ecto.Changeset.change(capture, context: marked))

    Repo.update_all(from(c in Capture, where: c.id == ^capture.id),
      set: [updated_at: ~U[2020-01-01 00:00:00Z]]
    )

    Slipdock.TestConfig.merge(:meetings, pipeline: :sync)
    assert Pipeline.sweep() == 1

    capture = Meetings.get_capture!(capture.id)
    assert capture.state == "ready"
    assert capture.context["stats"]["marker"] == "first"
    # Read (once, by default), not gathered again, not ingested again.
    assert length(requests()) == 1

    assert Enum.any?(
             events(capture),
             &match?({"resumed", "Resumed after a restart, from Reading the meeting."}, &1)
           )
  end

  test "the sweep leaves alone what moved recently or is not reading", %{
    board: board,
    owner: owner,
    capture: capture
  } do
    capture = Pipeline.start(capture, mode: :manual)
    assert capture.state == "reading"
    _ready = capture_fixture(board, owner)
    assert Pipeline.sweep() == 0
  end

  test "a provider error fails it with the provider's words, and retry carries on", %{
    capture: capture,
    owner: owner
  } do
    AIStub.fail_with(503, "the upstream model is overloaded")
    capture = Pipeline.start(capture, mode: :sync)

    assert capture.state == "failed"
    assert capture.step == "context"
    assert capture.state_reason =~ "reading 1:"
    assert capture.state_reason =~ "overloaded"

    AIStub.reply_with(%{"findings" => [@decision]})
    capture = Pipeline.retry(capture, owner, mode: :sync)
    assert capture.state == "ready"
    assert {"state", "Retrying from Reading the meeting."} in events(capture)
  end

  test "only a failed capture can be retried", %{capture: capture, owner: owner} do
    assert {:error, "only a failed capture can be retried (this one is receiving)"} =
             Pipeline.retry(capture, owner)
  end

  test "an exception inside a step is a failure with a reason, not a capture stuck reading", %{
    capture: capture,
    owner: owner
  } do
    {:ok, capture} = Meetings.transition(capture, "reading")
    {:ok, capture} = Meetings.transition(capture, "failed", reason: "x")

    capture =
      capture
      |> Ecto.Changeset.change(step: "read", readings: %{"1" => "not a list"})
      |> Repo.update!()

    capture = Pipeline.retry(capture, owner, mode: :sync)
    assert capture.state == "failed"
    assert capture.state_reason == "something went wrong while checking every quote"
    refute Pipeline.running?(capture.id)
  end

  test "a recording with no transcript says what it needs", %{board: board, owner: owner} do
    path = Path.join(System.tmp_dir!(), "p-#{System.unique_integer([:positive])}.mp3")
    File.write!(path, "audio")
    on_exit(fn -> File.rm(path) end)

    {:ok, capture} =
      Meetings.create_capture(
        board,
        owner,
        %{title: "Call", fingerprint: Meetings.fingerprint(audio: path)},
        audio: %{path: path, filename: "call.mp3"}
      )

    capture = Pipeline.start(capture, mode: :sync)
    assert capture.state == "failed"
    assert capture.state_reason =~ "a recording needs a transcript sent with it"
  end

  test "each step's progress is broadcast", %{capture: capture} do
    Meetings.subscribe(capture)
    AIStub.reply_with(%{"findings" => []})
    Pipeline.start(capture, mode: :sync)

    id = capture.id
    for _ <- Pipeline.steps(), do: assert_received({:capture_changed, ^id})
  end

  test "next_step walks the steps in order" do
    assert Pipeline.next_step(nil) == "ingest"
    assert Pipeline.next_step("context") == "read"
    assert Pipeline.next_step("ready") == nil
  end
end
