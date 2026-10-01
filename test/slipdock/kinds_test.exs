defmodule Slipdock.KindsTest do
  @moduledoc """
  The three things a list can hold — a card, a document, a wiki page placed in
  it — and the filters that narrow to one of them: the board's own
  (`Slipdock.Filters`), every other view's (`Slipdock.Swimlanes`) and the card
  listing the API and the CLI go through (`Slipdock.Boards.list_cards/2`).
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Filters, Kinds, Swimlanes, Wiki}
  alias Slipdock.Swimlanes.Config

  setup do
    File.rm_rf!(Boards.uploads_dir())
    user = user_fixture("kinds@example.com")
    board = board_fixture(%{"name" => "Kinds"}, owner: user)
    [todo | _] = board.columns

    src = Path.join(System.tmp_dir!(), "kanban-kind-#{System.unique_integer([:positive])}.txt")
    File.write!(src, "the spec they emailed")
    on_exit(fn -> File.rm(src) end)

    attach = fn card ->
      {:ok, _} =
        Boards.add_attachment(card, %{filename: "spec.txt", content_type: "text/plain"}, src)

      Boards.get_card!(card.id)
    end

    card = card_fixture(todo, %{"title" => "Write the parser"})
    document = attach.(card_fixture(todo, %{"title" => "spec.txt"}))
    page = page_fixture(board, %{"title" => "Retro"}, user: user)
    {:ok, page} = Wiki.place(page, todo)

    %{
      board: board,
      column: todo,
      user: user,
      attach: attach,
      card: card,
      document: document,
      page: page
    }
  end

  describe "what something is" do
    test "a card, a document and a page", ctx do
      assert Kinds.kind_of(ctx.card) == "card"
      assert Kinds.kind_of(ctx.document) == "document"
      assert Kinds.kind_of(ctx.page) == "page"
    end

    test "a card with a file and something of its own is a card again", ctx do
      {:ok, described} = Boards.update_card(ctx.document, %{"description" => "the vendor's spec"})
      assert Kinds.kind_of(Boards.get_card!(described.id)) == "card"

      {:ok, _} = Boards.update_card(described, %{"description" => "   "})
      assert Kinds.kind_of(Boards.get_card!(described.id)) == "document"

      {:ok, _} = Boards.add_checklist_item(ctx.document, "read it")
      assert Kinds.kind_of(Boards.get_card!(ctx.document.id)) == "card"
    end

    test "a file with work hanging beneath it is a card, not a document", ctx do
      {:ok, template} = Boards.find_template("Simple")
      {:ok, sub} = Boards.create_sub_board(ctx.document, template)
      assert Kinds.kind_of(Boards.get_card!(ctx.document.id)) == "document"

      _ = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Read it"})
      assert Kinds.kind_of(Boards.get_card!(ctx.document.id)) == "card"

      rollup = Boards.rollup(Boards.get_board!(ctx.board.id))
      assert %{document: false} = rollup.cards[ctx.document.id]
    end

    test "a card whose attachments were never loaded is not guessed at", ctx do
      light = Slipdock.Repo.get!(Slipdock.Boards.Card, ctx.document.id)
      assert Kinds.kind_of(light) == "card"
      assert Kinds.kind_of(%{light | document: true}) == "document"
    end

    test "an empty filter is no filter", ctx do
      assert Kinds.matches?(ctx.card, [])
      assert Kinds.matches?(ctx.page, [])
      refute Kinds.matches?(ctx.card, ["page"])
    end
  end

  describe "the board's filter bar" do
    test "narrows to one kind, and counts as one filter", ctx do
      filters = %{Filters.empty() | kinds: ["document"]}

      assert Filters.count(filters) == 1
      assert Filters.any?(filters)
      assert Filters.matches?(ctx.document, filters)
      refute Filters.matches?(ctx.card, filters)
      refute Filters.matches?(ctx.page, filters)
    end

    test "several kinds at once", ctx do
      filters = %{Filters.empty() | kinds: ["card", "page"]}

      assert Filters.matches?(ctx.card, filters)
      assert Filters.matches?(ctx.page, filters)
      refute Filters.matches?(ctx.document, filters)
    end

    test "kind narrows alongside the other filters, not instead of them", ctx do
      {:ok, _} = Boards.update_card(ctx.card, %{"priority" => "high"})
      card = Boards.get_card!(ctx.card.id)
      filters = %{Filters.empty() | kinds: ["card"], priority: "high"}

      assert Filters.matches?(card, filters)
      refute Filters.matches?(ctx.document, %{filters | priority: nil, kinds: ["card"]})
    end
  end

  describe "every other view" do
    test "the grid counts all three, and the kinds filter separates them", ctx do
      board = Boards.get_board!(ctx.board.id)
      config = %Config{Config.defaults("table") | rows: "none", cols: "none"}

      assert Swimlanes.grid(board, config).shown == 3
      assert Swimlanes.grid(board, %{config | kinds: ["page"]}).shown == 1
      assert Swimlanes.grid(board, %{config | kinds: ["card", "document"]}).shown == 2

      hidden = Swimlanes.grid(board, %{config | kinds: ["document"]})
      assert hidden.shown == 1
      assert hidden.hidden == 2
    end

    test "kinds survives a query string and a saved view" do
      config = Config.from_query(%{"kinds" => "page,document,nonsense"})

      assert config.kinds == ["document", "page"]
      assert Config.filtering?(config)
      assert Config.active_filter_count(config) == 1

      assert config |> Config.to_map() |> Config.from_map() |> Map.get(:kinds) ==
               ["document", "page"]

      assert Config.clear_filters(config).kinds == []
    end
  end

  describe "the card listing the API and the CLI use" do
    test "kind=document, kind=card, and pages are not cards", ctx do
      titles = fn filters ->
        ctx.board |> Boards.list_cards(filters) |> Enum.map(& &1.title) |> Enum.sort()
      end

      assert titles.(%{}) == ["Write the parser", "spec.txt"]
      assert titles.(%{"kind" => "document"}) == ["spec.txt"]
      assert titles.(%{"kind" => "card"}) == ["Write the parser"]
      assert titles.(%{"kind" => "page"}) == []

      # Query strings arrive as anything at all.
      assert titles.(%{"kind" => "spreadsheet"}) == ["Write the parser", "spec.txt"]
      assert titles.(%{"kind" => ""}) == ["Write the parser", "spec.txt"]
    end
  end

  describe "the outline, whose cards are loaded light" do
    test "still knows a document from a card", ctx do
      rollup = Boards.rollup(Boards.get_board!(ctx.board.id))
      cards = Map.values(rollup.cards)

      assert Enum.sort(Enum.map(cards, &{&1.title, Kinds.kind_of(&1)})) ==
               [{"Write the parser", "card"}, {"spec.txt", "document"}]
    end
  end
end
