defmodule Slipdock.Meetings.ResolveTest do
  @moduledoc """
  Resolve mode's working parts (#547): re-listening as a signal, never an
  override (agree, disagree, a question already raised); and asking the
  speaker — the rest committed while the item waits, the item written when
  they answer, everything still written once and undone together.
  """
  use Slipdock.DataCase, async: true

  import Swoosh.TestAssertions
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{AIStub, Meetings, Repo, Settings}
  alias Slipdock.Boards.Card

  alias Slipdock.Meetings.{
    Commit,
    Finding,
    Question,
    Relisten,
    Review,
    Speakers,
    Undo,
    Usage,
    Utterance
  }

  setup do
    owner = user_fixture("owner@example.com")
    {:ok, owner} = Slipdock.Accounts.update_profile(owner, %{"name" => "Priya Shah"})
    board = board_fixture(%{"name" => "Pricing"}, owner: owner)
    sam = user_fixture("sam@example.com")
    {:ok, sam} = Slipdock.Accounts.update_profile(sam, %{"name" => "Sam Smith"})
    share_fixture(board, [sam], "write")
    %{owner: owner, board: board, sam: sam}
  end

  defp wav(seconds) do
    rate = 8_000
    data = seconds * rate
    path = Path.join(System.tmp_dir!(), "rl-#{System.unique_integer([:positive])}.wav")

    File.write!(path, [
      <<"RIFF", 36 + data::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
        rate::little-32, rate::little-32, 1::little-16, 8::little-16, "data", data::little-32>>,
      :binary.copy(<<128>>, data)
    ])

    on_exit(fn -> File.rm(path) end)
    path
  end

  # A recorded meeting whose line L2 ("We go annual at 20% off.") has an
  # unsure word, and a decision resting on it.
  defp recorded(ctx, findings \\ nil) do
    path = wav(20)

    {:ok, capture} =
      Meetings.create_capture(
        ctx.board,
        ctx.owner,
        %{title: "Call", fingerprint: Meetings.fingerprint(audio: path)},
        audio: %{path: path, filename: "call.wav"},
        utterances: [
          %{speaker: "Priya Shah", text: "Where did we land?", start_ms: 0, end_ms: 4000},
          %{
            speaker: "Sam Smith",
            text: "We go annual at 20% off.",
            start_ms: 4000,
            end_ms: 9000,
            words: [
              %{"word" => "We"},
              %{"word" => "go"},
              %{"word" => "annual"},
              %{"word" => "at"},
              %{"word" => "20%", "confidence" => 0.3},
              %{"word" => "off."}
            ]
          }
        ]
      )

    {:ok, _} = Speakers.diarise(capture)
    {:ok, _} = Speakers.attribute(capture)

    findings =
      findings ||
        [
          %{
            "kind" => "decision",
            "title" => "Annual at 20% off",
            "evidence" => [%{"line" => "L2", "quote" => "We go annual at 20% off."}]
          }
        ]

    capture =
      capture
      |> Ecto.Changeset.change(
        readings: %{"1" => findings},
        context: %{"candidates" => [], "decisions" => []}
      )
      |> Repo.update!()

    {:ok, _} = Meetings.verify(capture)
    capture
  end

  defp finding(capture),
    do:
      Repo.one!(
        from(f in Finding, where: f.capture_id == ^capture.id and f.status == "kept", limit: 1)
      )

  describe "re-listening" do
    setup do
      {:ok, _} = Settings.update(%{"meetings_relisten_model" => "openai/gpt-4o-audio-preview"})
      :ok
    end

    test "agreeing with the transcript marks the passage re-listened", ctx do
      capture = recorded(ctx)
      AIStub.reply_with(%{"heard" => "We go annual at 20% off.", "matches" => "A"})
      {:ok, _} = Relisten.run(capture)

      assert "relistened" in finding(capture).signals
      assert Repo.aggregate(from(q in Question, where: q.capture_id == ^capture.id), :count) == 0

      assert_received {:ai_request, body}
      assert body["model"] == "openai/gpt-4o-audio-preview"

      [
        %{
          "content" => [
            %{"type" => "text", "text" => text},
            %{"type" => "input_audio", "input_audio" => %{"format" => "wav", "data" => data}}
          ]
        }
      ] = body["messages"]

      assert text =~ "We go annual at 20% off."
      assert <<"RIFF", _::binary>> = Base.decode64!(data)

      assert [%{kind: "relisten"}] =
               Usage.for_capture(capture) |> Enum.filter(&(&1.kind == "relisten"))
    end

    test "hearing something else asks a person, with both versions — never overrides", ctx do
      capture = recorded(ctx)
      AIStub.reply_with(%{"heard" => "We go annual at 50% off.", "matches" => "neither"})
      {:ok, _} = Relisten.run(capture)

      assert "audio_unclear" in finding(capture).signals
      [q] = Repo.all(from(q in Question, where: q.capture_id == ^capture.id))
      assert q.kind == "unclear"

      assert Enum.map(q.options, & &1["label"]) == [
               "We go annual at 20% off.",
               "We go annual at 50% off.",
               "Not sure"
             ]

      assert q.context["model_view"]["heard"] == "We go annual at 50% off."
      # The transcript itself is untouched.
      assert Repo.one!(
               from(u in Utterance, where: u.capture_id == ^capture.id and u.line_id == "L2")
             ).text == "We go annual at 20% off."
    end

    test "a question already raised keeps it, with the model's view attached", ctx do
      capture =
        recorded(ctx, [
          %{
            "kind" => "decision",
            "title" => "Annual at 20% off",
            "evidence" => [%{"line" => "L2", "quote" => "annual at 20% off"}]
          }
        ])

      capture =
        capture
        |> Ecto.Changeset.change(
          readings: %{
            "1" => [
              %{
                "kind" => "decision",
                "title" => "Annual at 15% off",
                "evidence" => [%{"line" => "L2", "quote" => "annual"}]
              }
            ],
            "2" => [
              %{
                "kind" => "decision",
                "title" => "Annual at 50% off",
                "evidence" => [%{"line" => "L2", "quote" => "annual"}]
              }
            ]
          }
        )
        |> Repo.update!()

      {:ok, _} = Meetings.verify(capture)
      AIStub.reply_with(%{"heard" => "annual at 50% off", "matches" => "B"})
      {:ok, _} = Relisten.run(capture)

      [q] = Repo.all(from(q in Question, where: q.capture_id == ^capture.id))
      assert q.kind == "which_reading" and q.status == "open"
      assert q.context["model_view"]["matches"] == "B"
    end

    test "nothing happens without a recording, or with it switched off", ctx do
      capture = recorded(ctx)
      {:ok, _} = Settings.update(%{"meetings_relisten_model" => ""})
      {:ok, _} = Relisten.run(capture)
      refute_received {:ai_request, _}

      transcript_only = reviewed_capture(ctx.board, ctx.owner, [decision_finding()])
      {:ok, _} = Settings.update(%{"meetings_relisten_model" => "m"})
      {:ok, _} = Relisten.run(transcript_only)
      refute_received {:ai_request, _}
    end
  end

  describe "asking the speaker" do
    setup ctx do
      # Two findings: a decision that is clear, and an action Sam took on
      # whose owner is in question.
      capture =
        recorded(ctx, [
          %{
            "kind" => "decision",
            "title" => "Annual plan",
            "evidence" => [%{"line" => "L2", "quote" => "We go annual"}]
          },
          %{
            "kind" => "action",
            "title" => "Update the pricing page",
            "owner" => "Sammy",
            "evidence" => [%{"line" => "L2", "quote" => "at 20% off"}]
          }
        ])

      {:ok, capture} = Meetings.transition(Meetings.get_capture!(capture.id), "reading")
      {:ok, capture} = Meetings.transition(capture, "needs_review")
      q = Repo.one!(from(q in Question, where: q.capture_id == ^capture.id))
      %{capture: capture, question: q}
    end

    test "sends them the question, and the rest commits while it waits; then it does", ctx do
      assert Review.speaker_of(ctx.question).id == ctx.sam.id
      {:ok, _} = Review.ask_speaker(ctx.question, ctx.owner)

      assert Repo.reload!(ctx.question).status == "waiting"
      assert Meetings.get_capture!(ctx.capture.id).state == "ready"

      assert_email_sent(fn email ->
        assert [{_, to}] = email.to
        assert to == ctx.sam.email
        assert email.text_body =~ ctx.question.prompt
        assert email.text_body =~ "/resolve/#{ctx.question.id}"
      end)

      # Everything else is written now.
      {:ok, committed} = Commit.commit(Meetings.get_capture!(ctx.capture.id), ctx.owner)
      assert [%{"op" => "decision_entry"}] = committed.change_set["changes"]

      assert [%{"why" => "waiting for the speaker's answer"}] =
               Commit.build(committed)["left_out"] |> Enum.filter(&(&1["why"] =~ "waiting"))

      refute Commit.pending?(committed)
      assert {:error, :conflict, _} = Commit.commit(committed, ctx.owner)

      # Sam answers, after the commit; the item is written on its own.
      {:ok, _} = Review.answer(Repo.reload!(ctx.question), "user:#{ctx.sam.id}", ctx.sam)
      committed = Meetings.get_capture!(ctx.capture.id)
      assert Commit.pending?(committed)

      {:ok, again} = Commit.commit(committed, ctx.owner)

      assert [_, %{"op" => "create_card", "id" => "c2", "card_id" => card_id}] =
               again.change_set["changes"]

      assert Repo.get!(Card, card_id).title == "Update the pricing page"
      assert [%{"changes" => 1}] = again.change_set["later"]

      assert Repo.all(
               from(f in Finding,
                 where: f.capture_id == ^ctx.capture.id and f.status == "kept",
                 select: not is_nil(f.written_at)
               )
             ) == [true, true]

      # Written once each, and undone together.
      assert {:error, :conflict, "this capture was committed already" <> _} =
               Commit.commit(again, ctx.owner)

      {:ok, _} = Undo.undo(again, ctx.owner)
      assert Repo.get!(Card, card_id).archived_at
    end

    test "nobody known to have said it, or yourself, can't be asked", ctx do
      assert {:error, "you are the speaker: answer it yourself"} =
               Review.ask_speaker(ctx.question, ctx.sam)

      Repo.update_all(from(v in Slipdock.Meetings.Voice, where: v.capture_id == ^ctx.capture.id),
        set: [user_id: nil]
      )

      assert {:error, "nobody here is known to have said it, so there is nobody to ask"} =
               Review.ask_speaker(ctx.question, ctx.owner)
    end
  end
end
