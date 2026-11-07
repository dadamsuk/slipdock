defmodule Slipdock.Handbook.RulesForTest do
  @moduledoc """
  The rules for a set of paths (#1774): `Handbook.rules_for/2` matches each
  rule's scope (its own, or its page's `covers:`) against the paths, and a
  card with lane paths carries those rules in its handbook block, `must`
  first, within the block's cap.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Handbook, Wiki}

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Rules project"}, owner: user)
    {:ok, _} = Handbook.install(user, board)
    pages = Map.new(Handbook.find(board).pages, &{&1.title, &1})

    write(pages["UX & UI"], "ux", "[lib/app_web/**, assets/**]", """
    - **UX-1** should · judgement · Screens use the layout's header.
    - **UX-2** must · test/app_web/tokens_test.exs · No colour literals.
    - **UX-3** must · scope lib/app_web/live/** · judgement · LiveViews stream long lists.
    """)

    write(pages["Data model"], "data-model", "[priv/repo/migrations/**]", """
    - **DATA-1** must · judgement · Never edit a migration that has run.
    """)

    # A page that covers nothing: its unscoped rule is everywhere's.
    write(pages["Operations"], "operations", "[]", """
    - **OPS-1** must · judgement · Nothing personal in the repository.
    """)

    # The Principles page's worked example (1.5.0) is everywhere's too: kept out of
    # these, which are about scope. Handbook's own tests cover them.
    write(pages["Principles"], "principles", "[]", "")

    %{user: user, board: board, handbook: Handbook.find(board)}
  end

  defp write(page, key, covers, rules) do
    {:ok, _} =
      Wiki.update_page(page, %{
        "front_matter" => "---\nhandbook: #{key}\ncovers: #{covers}\n---\n",
        "body" => "# #{page.title}\n\n## Rules\n\n" <> rules
      })
  end

  defp ids(rules), do: Enum.map(rules, & &1.id)

  describe "rules_for/2" do
    test "a file under a page's covers gets that page's rules, must first", %{handbook: h} do
      assert ids(Handbook.rules_for(h, ["lib/app_web/components/menu.ex"])) ==
               ["OPS-1", "UX-2", "UX-1"]
    end

    test "a rule's own scope narrows it from the page's covers", %{handbook: h} do
      assert ids(Handbook.rules_for(h, ["lib/app_web/live/board_live.ex"])) ==
               ["OPS-1", "UX-2", "UX-3", "UX-1"]

      refute "UX-3" in ids(Handbook.rules_for(h, ["assets/css/app.css"]))
    end

    test "any of several paths matching is enough, and each rule comes once", %{handbook: h} do
      rules =
        Handbook.rules_for(h, [
          "priv/repo/migrations/20261105_add.exs",
          "lib/app_web/live/x.ex",
          "lib/app_web/live/y.ex"
        ])

      # `must` first, then `should`; within each, the handbook's page order.
      assert ids(rules) == ["DATA-1", "OPS-1", "UX-2", "UX-3", "UX-1"]
      assert %{page: _, section: "Data model/Rules"} = Enum.find(rules, &(&1.id == "DATA-1"))
    end

    test "a card's lane globs match the rules under them", %{handbook: h} do
      assert ids(Handbook.rules_for(h, ["priv/repo/**"])) == ["DATA-1", "OPS-1"]
    end

    test "a path nothing covers gets only the everywhere rules", %{handbook: h} do
      assert ids(Handbook.rules_for(h, ["README.md"])) == ["OPS-1"]
    end

    test "no paths, blank paths or no handbook is no rules", %{handbook: h} do
      assert Handbook.rules_for(h, []) == []
      assert Handbook.rules_for(h, ["", "  "]) == []
      assert Handbook.rules_for(h, nil) == []
      assert Handbook.rules_for(nil, ["lib/a.ex"]) == []
    end
  end

  describe "pages_for/2 (#1787)" do
    test "the pages whose covers take the paths in, most paths first", %{handbook: h} do
      pages =
        Handbook.pages_for(h, [
          "priv/repo/migrations/20261105_add.exs",
          "lib/app_web/live/x.ex",
          "assets/css/app.css",
          "README.md"
        ])

      assert Enum.map(pages, &{&1.title, &1.paths}) == [{"UX & UI", 2}, {"Data model", 1}]
      assert Enum.all?(pages, &String.starts_with?(&1.code, "W-"))
    end

    test "a tie keeps the handbook's order, and globs match as lanes do", %{handbook: h} do
      # One path each: the handbook's order (as rules_for/2 keeps it).
      pages = Handbook.pages_for(h, ["lib/app_web/x.ex", "priv/repo/**"])
      assert Enum.map(pages, & &1.title) == ["Data model", "UX & UI"]
      assert Enum.map(pages, & &1.paths) == [1, 1]
    end

    test "a page with no covers, the Index, or nothing matching is never listed",
         %{handbook: h} do
      # Operations covers nothing (its rule is everywhere's), but claims no paths.
      assert Handbook.pages_for(h, ["README.md", "lib/other.ex"]) == []
      assert Handbook.pages_for(h, []) == []
      assert Handbook.pages_for(nil, ["lib/a.ex"]) == []
    end
  end

  describe "rules_for_board/4" do
    test "every matching rule, the paths cleaned", %{user: user, board: board} do
      got = Handbook.rules_for_board(board, user, [" README.md ", "README.md", ""])
      assert got.paths == ["README.md"]
      assert ids(got.rules) == ["OPS-1"]
      assert got.pages == []

      got = Handbook.rules_for_board(board, user, ["assets/app.js"])
      assert [%{title: "UX & UI", paths: 1}] = got.pages
      assert got.index_page == Handbook.find(board).index.code
    end

    test "nil for a board without a handbook, or a reader who can't read it",
         %{user: user, board: board} do
      bare = board_fixture(%{"name" => "No handbook"}, owner: user)
      assert Handbook.rules_for_board(bare, user, ["a.ex"]) == nil

      stranger = user_fixture("rules-stranger@example.com")
      assert Handbook.rules_for_board(board, stranger, ["a.ex"]) == nil
      assert Handbook.rules_for_board(board, nil, ["a.ex"]) == nil
    end
  end

  describe "for_card/3's rules" do
    setup %{board: board} do
      [col | _] = board.columns
      %{col: col}
    end

    test "a card with lane paths gets the rules for them", %{user: user, col: col} do
      card = card_fixture(col, %{"title" => "Menu"})
      {:ok, card} = Boards.update_card(card, %{"paths" => ["lib/app_web/live/**"]})

      reading = Handbook.for_card(card, user)
      assert Enum.map(reading.rules, & &1.id) == ["OPS-1", "UX-2", "UX-3", "UX-1"]
      assert reading.rules_more == 0

      assert Enum.at(reading.rules, 1) == %{
               id: "UX-2",
               severity: "must",
               page: Handbook.find(card |> board_of()).pages |> page_code("UX & UI"),
               section: "UX & UI/Rules",
               check: "test/app_web/tokens_test.exs",
               text: "No colour literals."
             }
    end

    test "a card without paths has no rules key", %{user: user, col: col} do
      card = card_fixture(col, %{"title" => "Menu for lib/app_web/live/x.ex"})
      refute Map.has_key?(Handbook.for_card(card, user), :rules)
    end

    test "many long rules stay within the cap, must first, the rest counted",
         %{user: user, board: board, col: col} do
      ux = Enum.find(Handbook.find(board).pages, &(&1.title == "UX & UI"))
      long = String.duplicate("A very long rule text that goes on. ", 12)

      items =
        for n <- 1..60 do
          sev = if rem(n, 2) == 0, do: "must", else: "should"
          "- **UX-#{n}** #{sev} · judgement · #{n}: #{long}"
        end

      write(ux, "ux", "[lib/app_web/**]", Enum.join(items, "\n") <> "\n")
      card = card_fixture(col, %{"title" => "Menu"})
      {:ok, card} = Boards.update_card(card, %{"paths" => ["lib/app_web/x.ex"]})

      reading = Handbook.for_card(card, user)
      assert byte_size(Jason.encode!(reading.rules)) <= Handbook.rules_cap()
      assert reading.rules != []
      assert reading.rules_more == 61 - length(reading.rules)
      assert Enum.all?(reading.rules, &(&1.severity == "must"))
      assert Enum.all?(reading.rules, &(String.length(&1.text) <= 160))
      assert byte_size(Jason.encode!(reading)) < 3 * Handbook.rules_cap() + 2048
    end
  end

  defp board_of(card), do: Boards.get_board!(card.board_id)
  defp page_code(pages, title), do: Enum.find(pages, &(&1.title == title)).code
end
