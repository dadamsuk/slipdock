defmodule SlipdockWeb.Meetings.ResolveLiveTest do
  @moduledoc """
  The Resolve screen (#547, screen 6): one question at a time with the
  passage, its neighbours and what else bears on it; replay controls where
  there is a recording (and why not where there isn't); an answer recorded
  with the replay that came before it; ask the speaker; and on to the next.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Meetings, Repo}
  alias Slipdock.Meetings.{Question, Speakers}

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    sam = user_fixture("sam@example.com")
    {:ok, sam} = Slipdock.Accounts.update_profile(sam, %{"name" => "Sam Smith"})
    share_fixture(board, [sam], "write")
    %{board: board, sam: sam}
  end

  defp questions(capture),
    do: Repo.all(from(q in Question, where: q.capture_id == ^capture.id, order_by: q.id))

  describe "a transcript-only capture" do
    setup %{board: board, user: user} do
      capture =
        reviewed_capture(board, user, [
          action_finding("Sammy"),
          action_finding("Zed", %{
            "title" => "Other",
            "evidence" => [%{"line" => "L1", "quote" => "pricing page"}]
          })
        ])

      %{capture: capture}
    end

    test "shows the question, the lines around it, no replay and why", %{
      conn: conn,
      board: board,
      capture: capture
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}/resolve")
      [first | _] = questions(capture)

      assert has_element?(view, "#resolve-#{first.id}")
      assert view |> element("#around") |> render() =~ "Sam, can you update PL-14 by Friday?"
      refute has_element?(view, "#replay")

      assert view |> element("#replay-missing") |> render() =~
               "There is no recording of this meeting"

      assert view |> element("#choose-1") |> render() =~ "Sam Smith"

      # The value a browser sends with the click (#553).
      assert has_element?(view, ~s(#choose-1[value="#{hd(first.options)["value"]}"]))
    end

    test "answering moves on to the next question, then back to the review", %{
      conn: conn,
      board: board,
      capture: capture
    } do
      [first, second] = questions(capture)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}/resolve/#{first.id}")

      view |> element("#choose-1") |> render_click()
      assert Repo.reload!(first).status == "answered"
      assert_patch(view, ~p"/boards/#{board}/meetings/#{capture.id}/resolve/#{second.id}")

      render_keydown(view, "key", %{"key" => "2"})
      assert Repo.reload!(second).status == "answered"
      assert_redirect(view, ~p"/boards/#{board}/meetings/#{capture.id}")
    end

    test "a question on a finding left out is skipped: not counted, not moved on to", %{
      conn: conn,
      board: board,
      capture: capture,
      user: user
    } do
      [first, second] = questions(capture)
      finding = Repo.get!(Slipdock.Meetings.Finding, second.finding_id)
      {:ok, _} = Slipdock.Meetings.Review.include(finding, false, user)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}/resolve")
      assert render(view) =~ "1 left"

      view |> element("#choose-1") |> render_click()
      assert Repo.reload!(first).status == "answered"
      assert Repo.reload!(second).status == "open"
      assert_redirect(view, ~p"/boards/#{board}/meetings/#{capture.id}")
      assert Meetings.get_capture!(capture.id).state == "ready"
    end

    test "the review links each open question here", %{conn: conn, board: board, capture: capture} do
      [first | _] = questions(capture)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}")

      assert has_element?(
               view,
               "#resolve-link-#{first.id}[href='/boards/#{board.id}/meetings/#{capture.id}/resolve/#{first.id}']"
             )
    end
  end

  describe "a recorded meeting" do
    setup %{board: board, user: user} do
      path = Path.join(System.tmp_dir!(), "rv-#{System.unique_integer([:positive])}.wav")
      File.write!(path, "RIFF....WAVE")
      on_exit(fn -> File.rm(path) end)

      {:ok, capture} =
        Meetings.create_capture(
          board,
          user,
          %{title: "Call", fingerprint: Meetings.fingerprint(audio: path)},
          audio: %{path: path, filename: "call.wav"},
          utterances: [
            %{speaker: "Priya Shah", text: "Who owns it?", start_ms: 455_000, end_ms: 458_000},
            %{
              speaker: "Sam Smith",
              text: "That's mine, I'll update the pricing page.",
              start_ms: 458_000,
              end_ms: 464_000
            }
          ]
        )

      {:ok, _} = Speakers.diarise(capture)
      {:ok, _} = Speakers.attribute(capture)

      capture =
        capture
        |> Ecto.Changeset.change(
          readings: %{
            "1" => [
              %{
                "kind" => "action",
                "title" => "Update the pricing page",
                "owner" => "Sammy",
                "evidence" => [%{"line" => "L2", "quote" => "I'll update the pricing page."}]
              }
            ]
          },
          context: %{"candidates" => [], "decisions" => []}
        )
        |> Repo.update!()

      {:ok, _} = Meetings.verify(capture)
      {:ok, capture} = Meetings.transition(Meetings.get_capture!(capture.id), "reading")
      {:ok, capture} = Meetings.transition(capture, "needs_review")
      [q] = questions(capture)
      %{capture: capture, question: q}
    end

    test "has replay controls on the passage, and an answer after a replay says so", %{
      conn: conn,
      board: board,
      capture: capture,
      question: q
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}/resolve/#{q.id}")

      assert has_element?(
               view,
               "#replay[phx-hook=Replay][data-from='458000'][data-to='464000'][data-src='/captures/#{capture.id}/audio']"
             )

      assert has_element?(view, "#replay-slow[data-replay='0.75']")
      assert has_element?(view, "#replay-loop[data-loop]")

      render_hook(view, "replayed", %{"from" => 458_000, "to" => 464_000, "rate" => 0.75})
      assert view |> element("#replayed-note") |> render() =~ "replayed 7:38–7:44"

      view |> element("#choose-1") |> render_click()
      q = Repo.reload!(q)
      assert q.context["replayed"] == "7:38–7:44"

      assert Repo.exists?(
               from(e in Slipdock.Meetings.Event,
                 where:
                   e.capture_id == ^capture.id and like(e.message, "%after replaying 7:38–7:44%")
               )
             )
    end

    test "the model's view is shown, and called a guess", %{
      conn: conn,
      board: board,
      capture: capture,
      question: q
    } do
      q
      |> Ecto.Changeset.change(
        context:
          Map.put(q.context, "model_view", %{"heard" => "that's Sam's", "model" => "gpt-audio"})
      )
      |> Repo.update!()

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}/resolve/#{q.id}")
      html = view |> element("#model-view") |> render()
      assert html =~ "gpt-audio&#39;s view — a guess"
      assert html =~ "that&#39;s Sam&#39;s"
    end

    test "ask the speaker: it waits, the capture can be committed, and they answer on this page",
         %{conn: conn, board: board, capture: capture, question: q, sam: sam} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}/resolve/#{q.id}")
      view |> element("#ask-speaker") |> render_click()

      assert Repo.reload!(q).status == "waiting"
      assert Meetings.get_capture!(capture.id).state == "ready"

      {:ok, theirs, _} =
        live(conn_as(sam), ~p"/boards/#{board}/meetings/#{capture.id}/resolve/#{q.id}")

      assert theirs |> element("#waiting-note") |> render() =~ "that&#39;s you"
      refute has_element?(theirs, "#ask-speaker")
      theirs |> element("#choose-1") |> render_click()
      assert %{status: "answered", answered_by_id: sam_id} = Repo.reload!(q)
      assert sam_id == sam.id
    end
  end
end
