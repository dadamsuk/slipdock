defmodule SlipdockWeb.CardTextMarkdownTest do
  @moduledoc """
  The text an agent writes on a card is shown as Markdown (#3001): the bar,
  the evidence and its *No code* reason, the verifier's note, a wait's
  questions and the answers asked before, and a status update. Each was
  drawn as plain text, so a list an agent wrote ran together as one block.
  The bar keeps a box to edit it, behind its rendered view.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.Card

  @list "**Options**\n\n- the first\n- the second\n"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Markdown fields", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"bar_required" => true})
    [_backlog, todo, _doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => "Format it"})
    %{board: board, card: card}
  end

  defp open(ctx), do: live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

  defp set(card, attrs), do: card |> Ecto.Changeset.change(attrs) |> Repo.update!()

  # The element's HTML has the list as a list and the bold as bold, and no
  # literal Markdown left over.
  defp assert_markdown(view, selector) do
    html = view |> element(selector) |> render()
    assert html =~ "<strong>Options</strong>", "#{selector}: #{html}"
    assert html =~ ~r{<ul>\s*<li>the first</li>\s*<li>the second</li>\s*</ul>}, html
    refute html =~ "**Options**"
    refute html =~ "whitespace-pre"
    html
  end

  describe "the bar" do
    test "a written bar shows as Markdown, and Edit opens its box", ctx do
      set(ctx.card, bar: "1. **Shown** as Markdown\n2. Tests pin it\n")
      {:ok, view, _} = open(ctx)

      html = view |> element("#card-bar-view") |> render()

      assert html =~
               ~r{<ol>\s*<li><strong>Shown</strong> as Markdown</li>\s*<li>Tests pin it</li>}

      refute has_element?(view, "#card-bar")
      refute has_element?(view, "#card-bar-done")

      view |> element("#card-bar-edit") |> render_click()
      assert has_element?(view, "#card-bar")
      refute has_element?(view, "#card-bar-view")
      assert view |> element("#card-bar") |> render() =~ "1. **Shown** as Markdown"

      view |> element("#card-bar-done") |> render_click()
      assert has_element?(view, "#card-bar-view")
      refute has_element?(view, "#card-bar")
    end

    test "clicking the rendered bar opens the box too", ctx do
      set(ctx.card, bar: "Done when it ships")
      {:ok, view, _} = open(ctx)

      view |> element("#card-bar-view") |> render_click()
      assert has_element?(view, "#card-bar")
    end

    test "Escape in the box shows the rendered bar again", ctx do
      set(ctx.card, bar: "Done when it ships")
      {:ok, view, _} = open(ctx)

      view |> element("#card-bar-edit") |> render_click()
      view |> element("#card-bar") |> render_keydown(%{"key" => "Escape"})
      assert has_element?(view, "#card-bar-view")
    end

    test "an empty bar shows its box, and typing into it keeps the box open", ctx do
      {:ok, view, _} = open(ctx)
      assert has_element?(view, "#card-bar")
      refute has_element?(view, "#card-bar-view")
      refute has_element?(view, "#card-bar-edit")

      view |> form("#card-bar-form", card: %{"bar" => "1. Tests"}) |> render_change()
      assert Repo.get!(Card, ctx.card.id).bar == "1. Tests"
      assert has_element?(view, "#card-bar")
      refute has_element?(view, "#card-bar-view")
      assert has_element?(view, "#card-bar-done")
    end

    test "a reader who can't change the card sees the rendered bar and no Edit", ctx do
      set(ctx.card, bar: @list)
      viewer = user_fixture("bar-viewer@example.com")
      {:ok, _} = Slipdock.Access.grant(ctx.board, viewer, "read", ctx.user)

      {:ok, view, _} =
        live(log_in_user(ctx.conn, viewer), ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      assert_markdown(view, "#card-bar-view")
      refute has_element?(view, "#card-bar-edit")
      refute has_element?(view, "#card-bar")
    end
  end

  describe "the evidence and the verdict" do
    setup ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"verify_work" => true})
      %{board: board}
    end

    test "the evidence is Markdown", ctx do
      set(ctx.card, evidence: @list, evidence_commit: "abc1234")
      {:ok, view, _} = open(ctx)
      assert_markdown(view, "#card-evidence-text")
    end

    test "a No code reason is Markdown", ctx do
      set(ctx.card, evidence_no_code: @list)
      {:ok, view, _} = open(ctx)
      html = assert_markdown(view, "#card-evidence-no-code")
      assert html =~ "No code:"
    end

    test "the verifier's note is Markdown", ctx do
      set(ctx.card, verify_state: "rejected", verify_note: @list, verify_by: %{"kind" => "agent"})
      {:ok, view, _} = open(ctx)
      assert_markdown(view, "#card-verify-note")
    end

    test "raw HTML in the evidence is shown, not obeyed", ctx do
      set(ctx.card, evidence: "<script>alert(1)</script>")
      {:ok, view, _} = open(ctx)
      html = view |> element("#card-evidence-text") |> render()
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "a wait" do
    test "its question is Markdown", ctx do
      {:ok, _} =
        Boards.Waits.open_wait(ctx.card, Slipdock.Actor.web(ctx.user), %{
          "needs" => @list,
          "choices" => ["the first", "the second"]
        })

      {:ok, view, _} = open(ctx)
      assert_markdown(view, "#wait-needs")
    end

    test "each question of a series is Markdown", ctx do
      {:ok, _} =
        Boards.Waits.open_wait(ctx.card, Slipdock.Actor.web(ctx.user), %{
          "questions" => [@list, "Which **region**?"]
        })

      {:ok, view, _} = open(ctx)
      assert_markdown(view, "#wait-question-1")
      assert view |> element("#wait-question-2") |> render() =~ "<strong>region</strong>"
    end

    test "a question asked before, and its answer, are Markdown", ctx do
      actor = Slipdock.Actor.web(ctx.user)
      {:ok, wait} = Boards.Waits.open_wait(ctx.card, actor, %{"needs" => @list})

      {:ok, _} =
        Boards.Waits.answer_wait(wait, actor, %{"answer" => "Take **the second**"})

      {:ok, view, _} = open(ctx)
      html = assert_markdown(view, "#wait-history-#{wait.id}")
      assert html =~ "<strong>the second</strong>"
    end
  end

  test "a status update's note is Markdown", ctx do
    {:ok, u} =
      Boards.StatusUpdates.add_status_update(ctx.card, ctx.user, %{
        "health" => "at_risk",
        "body" => @list
      })

    {:ok, view, _} = open(ctx)
    assert_markdown(view, "#status-update-#{u.id}-body")
  end
end
