defmodule SlipdockWeb.Meetings.SpeakersLiveTest do
  @moduledoc """
  *Who said what* (#546, screen 3b), and the recording behind its clips: a
  card per voice with its lines, person, evidence and confirm/change; the
  unsure lines that matter; the audio served in ranges to readers only.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Meetings, Repo, Settings}
  alias Slipdock.Meetings.{Speakers, Utterance, Voice}

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    sam = user_fixture("sam@example.com")
    {:ok, sam} = Slipdock.Accounts.update_profile(sam, %{"name" => "Sam Smith"})
    share_fixture(board, [sam], "write")

    capture =
      capture_fixture(board, user, %{transcript: "x#{System.unique_integer()}"},
        utterances: [
          %{speaker: "Speaker 1", text: "Good question, Sam.", start_ms: 0, end_ms: 2000},
          %{speaker: "Speaker 2", text: "We ship Friday.", start_ms: 2000, end_ms: 5000}
        ]
      )

    {:ok, _} = Speakers.diarise(capture)
    {:ok, _} = Speakers.attribute(capture)

    voices =
      Repo.all(from(v in Voice, where: v.capture_id == ^capture.id)) |> Map.new(&{&1.label, &1})

    %{board: board, sam: sam, capture: capture, voices: voices}
  end

  test "a card per voice: lines, person, evidence; transcript only means no clips", ctx do
    {:ok, view, html} =
      live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}/speakers")

    card = view |> element("#voice-#{ctx.voices["Speaker 2"].id}") |> render()
    assert card =~ "Sam Smith"
    assert card =~ "please confirm"
    assert card =~ "We ship Friday."

    assert view |> element("#evidence-#{ctx.voices["Speaker 2"].id}") |> render() =~
             "then this voice answered (L2)"

    assert html =~ "There is no recording, so there are no clips to replay"
    refute html =~ "<audio"
  end

  test "a speaker the transcript names, who isn't on the board, is shown by that name", %{
    conn: conn,
    board: board,
    user: user
  } do
    capture =
      capture_fixture(board, user, %{transcript: "y#{System.unique_integer()}"},
        utterances: [
          %{speaker: "Priya Nair", text: "Thanks for coming.", start_ms: 0, end_ms: 2000},
          %{speaker: "Speaker 2", text: "Glad to.", start_ms: 2000, end_ms: 4000}
        ]
      )

    {:ok, _} = Speakers.diarise(capture)
    {:ok, _} = Speakers.attribute(capture)

    voices =
      Repo.all(from(v in Voice, where: v.capture_id == ^capture.id)) |> Map.new(&{&1.label, &1})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}/speakers")
    priya = view |> element("#voice-#{voices["Priya Nair"].id}-name") |> render()
    assert priya =~ "Priya Nair"
    assert priya =~ "not on this board"
    refute priya =~ "Not known yet"

    assert view |> element("#voice-#{voices["Speaker 2"].id}-name") |> render() =~ "Not known yet"
  end

  test "confirming somebody else changes the voice, and the page follows", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}/speakers")
    id = ctx.voices["Speaker 1"].id

    view
    |> form("#assign-#{id}", %{"voice" => to_string(id), "who" => "other", "other" => "Dana"})
    |> render_submit()

    voice = Repo.get!(Voice, id)
    assert voice.name == "Dana" and voice.confidence == "confirmed"
    assert view |> element("#voice-#{id}") |> render() =~ "confirmed"
  end

  test "the unsure lines a finding depends on are listed", ctx do
    Repo.update_all(
      from(u in Utterance, where: u.capture_id == ^ctx.capture.id and u.line_id == "L2"),
      set: [voice_unsure: true]
    )

    c =
      ctx.capture
      |> Ecto.Changeset.change(
        readings: %{
          "1" => [
            %{
              "kind" => "decision",
              "title" => "Ship Friday",
              "evidence" => [%{"line" => "L2", "quote" => "We ship Friday."}]
            }
          ]
        },
        context: %{"candidates" => [], "decisions" => []}
      )
      |> Repo.update!()

    {:ok, _} = Meetings.verify(c)

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}/speakers")
    assert view |> element("#unsure-L2") |> render() =~ "We ship Friday."
  end

  test "open questions on the review are pointed to, since confirming voices doesn't answer them",
       ctx do
    path = ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}/speakers"
    {:ok, view, _} = live(ctx.conn, path)
    refute has_element?(view, "#questions-elsewhere")

    question_fixture(ctx.capture, %{blocking: true})
    question_fixture(ctx.capture, %{blocking: true})
    {:ok, view, _} = live(ctx.conn, path)

    assert view |> element("#questions-elsewhere") |> render() =~
             "2 questions are still open on the review"

    assert has_element?(
             view,
             ~s(#questions-elsewhere a[href="/boards/#{ctx.board.id}/meetings/#{ctx.capture.id}"])
           )
  end

  test "a reader cannot change who a voice is", ctx do
    reader = user_fixture("reader@example.com")
    share_fixture(ctx.board, [reader], "read")

    {:ok, view, _} =
      live(conn_as(reader), ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}/speakers")

    id = ctx.voices["Speaker 1"].id
    refute has_element?(view, "#assign-#{id}")

    render_submit(view, "assign", %{"voice" => to_string(id), "who" => "other", "other" => "Dana"})

    assert Repo.get!(Voice, id).name == nil
  end

  describe "the recording" do
    setup %{board: board, user: user} do
      path = Path.join(System.tmp_dir!(), "r-#{System.unique_integer([:positive])}.wav")
      File.write!(path, "0123456789abcdefghij")
      on_exit(fn -> File.rm(path) end)

      {:ok, capture} =
        Meetings.create_capture(
          board,
          user,
          %{title: "Call", fingerprint: Meetings.fingerprint(audio: path)},
          audio: %{path: path, filename: "call.wav", content_type: "audio/wav"},
          utterances: [%{speaker: "Sam Smith", text: "Hello.", start_ms: 1000, end_ms: 2500}]
        )

      {:ok, _} = Speakers.diarise(capture)
      {:ok, _} = Speakers.attribute(capture)
      %{audio_capture: capture}
    end

    test "is served whole, or in the range a player asks for", %{conn: conn, audio_capture: c} do
      whole = get(conn, "/captures/#{c.id}/audio")
      assert whole.status == 200
      assert whole.resp_body == "0123456789abcdefghij"
      assert get_resp_header(whole, "accept-ranges") == ["bytes"]

      part = conn |> put_req_header("range", "bytes=5-9") |> get("/captures/#{c.id}/audio")
      assert part.status == 206
      assert part.resp_body == "56789"
      assert get_resp_header(part, "content-range") == ["bytes 5-9/20"]
    end

    test "gives clips on the Who said what page", %{conn: conn, board: board, audio_capture: c} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/meetings/#{c.id}/speakers")
      assert html =~ ~s(src="/captures/#{c.id}/audio#t=1.0,2.5")
    end

    test "is not there for somebody who can't read the board, or with meeting mode off", %{
      audio_capture: c,
      conn: conn
    } do
      stranger = user_fixture("stranger@example.com")
      assert conn_as(stranger) |> get("/captures/#{c.id}/audio") |> response(404)

      {:ok, _} = Settings.update(%{"meetings_enabled" => false})
      assert conn |> get("/captures/#{c.id}/audio") |> response(404)
    end
  end
end
