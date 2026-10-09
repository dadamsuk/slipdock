defmodule SlipdockWeb.Meetings.ReviewLiveTest do
  @moduledoc """
  The review screen (#537, screen 5): selecting a finding lights exactly its
  evidence; questions answered inline gate the commit; include, leave out,
  edit and add; the keyboard; a phone's one column; and two reviewers seeing
  each other's answers.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.Meetings.{Finding, Question}
  alias Slipdock.Repo

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    sam = user_fixture("sam@example.com")
    {:ok, sam} = Slipdock.Accounts.update_profile(sam, %{"name" => "Sam Smith"})
    share_fixture(board, [sam], "write")
    capture = reviewed_capture(board, user, [decision_finding(), action_finding("Sammy")])

    [decision, action] =
      Repo.all(from(f in Finding, where: f.capture_id == ^capture.id, order_by: f.position))

    question = Repo.one!(from(q in Question, where: q.capture_id == ^capture.id))

    %{
      board: board,
      sam: sam,
      capture: capture,
      decision: decision,
      action: action,
      question: question
    }
  end

  defp open(conn, board, capture), do: live(conn, ~p"/boards/#{board}/meetings/#{capture.id}")

  test "selecting a finding highlights exactly its evidence lines", ctx do
    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.capture)

    # The first finding is selected to begin with.
    assert has_element?(view, "#line-L2[data-highlight=true]")
    refute has_element?(view, "#line-L3[data-highlight=true]")

    view |> element("#finding-#{ctx.action.id} button[phx-click=select]") |> render_click()
    assert has_element?(view, "#line-L3[data-highlight=true]")

    for line <- ~w(L1 L2 L4),
        do: assert(has_element?(view, "#line-#{line}[data-highlight=false]"))
  end

  test "signals read as words, and what it becomes is said plainly", ctx do
    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.capture)
    assert view |> element("#signals-#{ctx.decision.id}") |> render() =~ "quoted word for word"
    refute view |> element("#review-findings") |> render() =~ ~r/\d+(\.\d+)?%\s*(confidence|sure)/

    assert view |> element("#becomes-#{ctx.decision.id}") |> render() =~
             "decisions page (Pricing)"

    assert view |> element("#becomes-#{ctx.action.id}") |> render() =~
             "a new card “Update the pricing page” in To Do"
  end

  test "commit is off while a question is open; answering turns it on, taking it back off again",
       ctx do
    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.capture)
    assert has_element?(view, "#commit-capture[disabled]")
    assert view |> element("#open-questions") |> render() =~ "1 question to settle"

    view |> element("#answer-#{ctx.question.id}-1") |> render_click()
    refute has_element?(view, "#commit-capture[disabled]")
    assert view |> element("#question-#{ctx.question.id}") |> render() =~ "Sam Smith"
    assert view |> element("#becomes-#{ctx.action.id}") |> render() =~ "for Sam Smith"

    view |> element("#unanswer-#{ctx.question.id}") |> render_click()
    assert has_element?(view, "#commit-capture[disabled]")
  end

  test "the question count goes to the next open question, and says why commit is off", ctx do
    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.capture)
    assert has_element?(view, "#finding-#{ctx.decision.id}[data-selected=true]")
    assert view |> element("#commit-blocked") |> render() =~ "not on Who said what"

    view |> element("#open-questions") |> render_click()
    assert has_element?(view, "#finding-#{ctx.action.id}[data-selected=true]")
    assert_push_event(view, "scroll-to-finding", %{id: id})
    assert id == ctx.action.id

    view |> element("#answer-#{ctx.question.id}-1") |> render_click()
    refute has_element?(view, "#open-questions")
    refute has_element?(view, "#commit-blocked")
  end

  test "commit goes to the preview once nothing is left to settle", ctx do
    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.capture)
    view |> element("#answer-#{ctx.question.id}-1") |> render_click()
    view |> element("#commit-capture") |> render_click()
    assert_redirect(view, "/boards/#{ctx.board.id}/meetings/#{ctx.capture.id}/preview")
  end

  test "leave out and include", ctx do
    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.capture)
    view |> element("#leave-out-#{ctx.decision.id}") |> render_click()
    assert has_element?(view, "#finding-#{ctx.decision.id}[data-included=false]")
    assert view |> element("#becomes-#{ctx.decision.id}") |> render() =~ "nothing — left out"

    view |> element("#include-#{ctx.decision.id}") |> render_click()
    assert has_element?(view, "#finding-#{ctx.decision.id}[data-included=true]")
  end

  test "an edited finding says who edited it", ctx do
    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.capture)
    view |> element("#edit-#{ctx.decision.id}") |> render_click()

    view
    |> form("#edit-form-#{ctx.decision.id}", finding: %{title: "Go annual at 20% off"})
    |> render_submit()

    assert view |> element("#finding-#{ctx.decision.id}") |> render() =~ "Go annual at 20% off"

    assert view |> element("#edited-#{ctx.decision.id}") |> render() =~
             "edited by #{ctx.user.email}"
  end

  test "something the transcript missed is added, marked as a person's", ctx do
    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.capture)
    view |> element("#start-add") |> render_click()
    view |> form("#add-form", added: %{kind: "action", title: "Tell sales"}) |> render_submit()

    html = view |> element("#review-findings") |> render()
    assert html =~ "Tell sales"
    assert html =~ "added by a person"
    assert html =~ "with no words from the meeting behind it"
  end

  test "the keyboard: J/K move, X leaves out, 1 answers, N finds the open question", ctx do
    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.capture)

    render_keydown(view, "key", %{"key" => "j"})
    assert has_element?(view, "#finding-#{ctx.action.id}[data-selected=true]")
    render_keydown(view, "key", %{"key" => "k"})
    assert has_element?(view, "#finding-#{ctx.decision.id}[data-selected=true]")

    render_keydown(view, "key", %{"key" => "x"})
    assert has_element?(view, "#finding-#{ctx.decision.id}[data-included=false]")
    render_keydown(view, "key", %{"key" => "i"})
    assert has_element?(view, "#finding-#{ctx.decision.id}[data-included=true]")

    render_keydown(view, "key", %{"key" => "n"})
    assert has_element?(view, "#finding-#{ctx.action.id}[data-selected=true]")
    render_keydown(view, "key", %{"key" => "1"})
    assert has_element?(view, "#question-#{ctx.question.id}[data-status=answered]")
  end

  test "the keyboard is quiet while a form is open", ctx do
    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.capture)
    view |> element("#edit-#{ctx.decision.id}") |> render_click()
    render_keydown(view, "key", %{"key" => "x"})
    assert has_element?(view, "#finding-#{ctx.decision.id}[data-included=true]")
  end

  test "two reviewers see each other's answers as they happen", ctx do
    {:ok, mine, _} = open(ctx.conn, ctx.board, ctx.capture)
    {:ok, theirs, _} = open(conn_as(ctx.sam), ctx.board, ctx.capture)

    mine |> element("#answer-#{ctx.question.id}-1") |> render_click()
    assert has_element?(theirs, "#question-#{ctx.question.id}[data-status=answered]")
    refute has_element?(theirs, "#commit-capture[disabled]")
  end

  test "a read-only member sees the review but cannot act on it", ctx do
    reader = user_fixture("reader@example.com")
    share_fixture(ctx.board, [reader], "read")
    {:ok, view, _} = open(conn_as(reader), ctx.board, ctx.capture)

    assert has_element?(view, "#finding-#{ctx.decision.id}")
    refute has_element?(view, "#commit-capture")
    refute has_element?(view, "#leave-out-#{ctx.decision.id}")
    refute has_element?(view, "#answer-#{ctx.question.id}-1")
    render_click(view, "include", %{"id" => to_string(ctx.decision.id), "included" => "false"})
    assert Repo.reload!(ctx.decision).included
  end

  test "on a phone: one column, the transcript behind a toggle", ctx do
    {:ok, view, _} = live(phone(ctx.conn), ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}")

    assert has_element?(view, "#review[data-layout=one-column]")
    refute has_element?(view, "#review-transcript")
    assert has_element?(view, "#review-findings")
    # Nothing on it is laid out wider than the screen.
    refute render(view) =~ ~r/(min-w|w)-\[(\d{4,}|[4-9]\d\d)px\]/

    view |> element("#toggle-transcript") |> render_click()
    assert has_element?(view, "#review-transcript")
    refute has_element?(view, "#review-findings")
  end

  test "unsure words are underlined, long silences and unsure voices shown", ctx do
    Repo.update_all(
      from(u in Slipdock.Meetings.Utterance,
        where: u.capture_id == ^ctx.capture.id and u.line_id == "L4"
      ),
      set: [
        start_ms: 60_000,
        voice_unsure: true,
        words: [
          %{"word" => "Yes,", "confidence" => 0.95},
          %{"word" => "that's", "confidence" => 0.3},
          %{"word" => "mine.", "confidence" => 0.9}
        ]
      ]
    )

    {:ok, view, _} = open(ctx.conn, ctx.board, ctx.capture)
    line = view |> element("#line-L4") |> render()
    assert line =~ "voice unsure"
    assert line =~ ~s(data-unsure="true">that&#39;s</span>)
    assert render(view) =~ "with nothing said"
  end
end
