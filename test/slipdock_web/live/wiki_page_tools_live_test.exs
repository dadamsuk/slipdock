defmodule SlipdockWeb.WikiPageToolsLiveTest do
  @moduledoc "The AI tools beside a wiki page, reading and editing it (#1539)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{AIStub, Boards, Wiki}

  setup do
    board = board_fixture(%{"name" => "Tools PT"})
    {:ok, page} = Wiki.create_page(board, %{"title" => "Launch", "body" => "Ring the printers."})
    %{board: board, page: page}
  end

  defp open(view), do: view |> element("#page-tools-toggle") |> render_click()

  defp run(view, tool) do
    view |> element("#page-tool-#{tool}") |> render_click()
    render_async(view)
  end

  defp chat(text), do: %{"message" => %{"content" => text}}

  test "reading: the panel opens, summarises the saved page and shuts", ctx do
    AIStub.reply_with("**All** about printers.")
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    refute has_element?(view, "#page-tools-#{ctx.page.id}")

    open(view)
    assert has_element?(view, "#page-tools-toggle[aria-pressed=true]")
    refute has_element?(view, "#page-tool-improve")

    assert run(view, "summarise") =~ "<strong>All</strong> about printers."
    assert_received {:ai_request, %{"messages" => [_, %{"content" => content}]}}
    assert content =~ "Ring the printers."
    refute has_element?(view, "#page-tools-insert")

    view |> element("#page-tools-close") |> render_click()
    refute has_element?(view, "#page-tools-#{ctx.page.id}")
  end

  test "an action becomes a card once, and the page links to it", ctx do
    AIStub.reply_with(%{"actions" => ["Book the hall", "Ring the printers."]})
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    open(view)
    run(view, "actions")

    view |> element("#page-tools-card-1") |> render_click()
    refute has_element?(view, "#page-tools-card-1")
    assert has_element?(view, "#page-tools-card-0")

    [card] = Boards.get_board!(ctx.board.id).columns |> hd() |> Map.fetch!(:cards)
    assert card.title == "Ring the printers."
    assert render(view) =~ "##{card.id}"
    assert Wiki.get_page!(ctx.page.id).body =~ "(##{card.id})"
  end

  # #2875: the index came through String.to_integer/1, which crashed the
  # panel on text, and a negative one made a card from the end of the list.
  test "an index that isn't one makes no card, and the panel stays up", ctx do
    AIStub.reply_with(%{"actions" => ["Book the hall", "Ring the printers."]})
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    open(view)
    run(view, "actions")
    tools = with_target(view, "#page-tools-#{ctx.page.id}")

    for index <- ["x", "1abc", "", "-1", "2"],
        do: render_hook(tools, "make_card", %{"index" => index})

    assert Boards.get_board!(ctx.board.id).columns |> hd() |> Map.fetch!(:cards) == []
    assert has_element?(view, "#page-tools-card-0")
    assert has_element?(view, "#page-tools-card-1")
  end

  test "a reader who can't write gets the tools and no cards", ctx do
    AIStub.reply_with(%{"actions" => ["Book the hall"]})
    reader = user_fixture("reader-pt@example.com")
    {:ok, _} = Slipdock.Access.grant(ctx.board, reader, "read", ctx.user)

    {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    open(view)
    assert run(view, "actions") =~ "Book the hall"
    refute has_element?(view, "#page-tools-card-0")
    assert has_element?(view, "#page-tools-copy[data-target=page-tools-actions]")
  end

  test "editing: works on the editor's unsaved text and adds to the page by event", ctx do
    AIStub.reply_with("Better words.")
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}/edit")
    open(view)
    assert has_element?(view, "#page-tool-improve")

    view
    |> form("#page-form", %{"page" => %{"body" => "Words not yet saved."}})
    |> render_change()

    assert run(view, "improve") =~ "Better words."
    assert_received {:ai_request, %{"messages" => [_, %{"content" => content}]}}
    assert content =~ "Words not yet saved."
    refute content =~ "Ring the printers."

    view |> element("#page-tools-insert") |> render_click()
    assert_push_event(view, "wiki-editor:insert", %{text: "Better words."})
    assert Wiki.get_page!(ctx.page.id).body == "Ring the printers."
  end

  test "editing offers no cards: making one could write to the page under the editor", ctx do
    AIStub.reply_with(%{"actions" => ["Book the hall"]})
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}/edit")
    open(view)
    assert run(view, "actions") =~ "Book the hall"
    refute has_element?(view, "#page-tools-card-0")
  end

  test "a new page has the tools, once there is something in the editor", ctx do
    AIStub.reply_with("Short.")
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/new")
    open(view)

    run(view, "summarise")
    assert has_element?(view, "#page-tools-error", "nothing on this page")

    view
    |> form("#page-form", %{"page" => %{"title" => "Fresh", "body" => "New words."}})
    |> render_change()

    assert run(view, "summarise") =~ "Short."
    refute has_element?(view, "#page-tools-error")
  end

  test "the tools stay open from page to page, with a clean panel", ctx do
    AIStub.reply_with("About printers.")
    {:ok, other} = Wiki.create_page(ctx.board, %{"title" => "Other", "body" => "Else."})
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    open(view)
    run(view, "summarise")

    render_patch(view, ~p"/boards/#{ctx.board}/wiki/#{other.slug}")
    assert has_element?(view, "#page-tools-#{other.id}")
    refute has_element?(view, "#page-tools-answer")
  end

  test "a model that fails says so in the panel, and the tools can run again", ctx do
    AIStub.fail_with(429, "slow down")
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    open(view)
    assert run(view, "key_points") =~ "rate-limited"

    AIStub.reply_with("- A point")
    assert run(view, "key_points") =~ "A point"
    refute has_element?(view, "#page-tools-error")
  end

  # #3104: the button goes after one click, but a double click or a replayed
  # event sends the same index again, and only `made` stands in its way.
  test "an index sent again makes no second card and leaves the page alone", ctx do
    AIStub.reply_with(%{"actions" => ["Book the hall", "Ring the printers."]})
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    open(view)
    run(view, "actions")
    tools = with_target(view, "#page-tools-#{ctx.page.id}")

    render_hook(tools, "make_card", %{"index" => "1"})
    body = Wiki.get_page!(ctx.page.id).body
    [card] = Boards.get_board!(ctx.board.id).columns |> hd() |> Map.fetch!(:cards)

    render_hook(tools, "make_card", %{"index" => "1"})
    assert [^card] = Boards.get_board!(ctx.board.id).columns |> hd() |> Map.fetch!(:cards)
    assert Wiki.get_page!(ctx.page.id).body == body
    assert body =~ "(##{card.id})"
  end

  test "a board with no lists says so and makes no card", ctx do
    AIStub.reply_with(%{"actions" => ["Book the hall"]})
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    open(view)
    run(view, "actions")

    for column <- Boards.get_board!(ctx.board.id).columns,
        do: {:ok, _} = Boards.Columns.delete_column(column)

    view |> element("#page-tools-card-0") |> render_click()
    assert has_element?(view, "#page-tools-error", "That board has no lists to put a card in.")
    assert has_element?(view, "#page-tools-card-0")
    assert Slipdock.Repo.aggregate(Boards.Card, :count) == 0
    assert Wiki.get_page!(ctx.page.id).body == "Ring the printers."
  end

  # The free card limit refuses the card: the page used the owner's one item.
  test "a card that is refused says so, makes no card and leaves the page alone" do
    {:ok, _} =
      Slipdock.Settings.complete_setup(%{
        "admin_email" => "admin@example.com",
        "free_card_limit" => 1
      })

    owner = user_fixture("full-pt@example.com")
    board = board_fixture(%{"name" => "Full PT"}, owner: owner)
    {:ok, page} = Wiki.create_page(board, %{"title" => "Launch", "body" => "Ring the printers."})

    AIStub.reply_with(%{"actions" => ["Book the hall"]})
    {:ok, view, _html} = live(conn_as(owner), ~p"/boards/#{board}/wiki/#{page.slug}")
    open(view)
    run(view, "actions")

    view |> element("#page-tools-card-0") |> render_click()
    assert has_element?(view, "#page-tools-error", "That card couldn't be made.")
    assert has_element?(view, "#page-tools-card-0")
    assert Slipdock.Repo.aggregate(Boards.Card, :count) == 0
    assert Wiki.get_page!(page.id).body == "Ring the printers."
  end

  test "a tool run that crashes says so, and the tools can run again", ctx do
    Req.Test.stub(Slipdock.AI, fn _conn -> raise "the model's connection fell over" end)
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    open(view)

    ExUnit.CaptureLog.capture_log(fn -> run(view, "summarise") end)
    assert has_element?(view, "#page-tools-error", "That didn't work; please try again.")
    refute has_element?(view, "#page-tool-summarise[disabled]")

    AIStub.reply_with("About printers.")
    assert run(view, "summarise") =~ "About printers."
    refute has_element?(view, "#page-tools-error")
  end

  test "a run sent while one is working starts no second request", ctx do
    test = self()

    Req.Test.stub(Slipdock.AI, fn conn ->
      send(test, {:asked, self()})
      receive do: (:answer -> Req.Test.json(conn, %{"choices" => [chat("One answer.")]}))
    end)

    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    open(view)
    view |> element("#page-tool-summarise") |> render_click()
    assert_receive {:asked, model}
    assert has_element?(view, "#page-tool-summarise", "Working…")

    tools = with_target(view, "#page-tools-#{ctx.page.id}")
    render_hook(tools, "run", %{"tool" => "key_points"})
    refute_receive {:asked, _}, 200
    assert has_element?(view, "#page-tool-summarise", "Working…")

    send(model, :answer)
    assert render_async(view) =~ "One answer."
    refute_received {:asked, _}
  end

  test "insert while reading pushes nothing to an editor", ctx do
    AIStub.reply_with("About printers.")
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    open(view)
    assert run(view, "summarise") =~ "About printers."
    refute has_element?(view, "#page-tools-insert")

    view |> with_target("#page-tools-#{ctx.page.id}") |> render_hook("insert", %{})
    refute_push_event(view, "wiki-editor:insert", %{})
    assert Wiki.get_page!(ctx.page.id).body == "Ring the printers."
  end

  test "a drawing and the history have no tools", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}/history")
    refute has_element?(view, "#page-tools-toggle")

    {:ok, drawing} =
      Wiki.create_page(ctx.board, %{
        "title" => "Sketch",
        "file_name" => "Sketch.excalidraw",
        "body" => "{}"
      })

    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{drawing.slug}")
    assert has_element?(view, "#open-drawing")
    refute has_element?(view, "#page-tools-toggle")
  end
end
