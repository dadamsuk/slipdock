defmodule SlipdockWeb.MCP.ResourcesRenderTest do
  @moduledoc """
  What each MCP resource (W-1808) says as Markdown: the board, the card in
  full, the page source (ciphertext as stored), a saved view's rows and My
  work; and the caps, which cut with a pointer to the tool for the rest.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Wiki}
  alias SlipdockWeb.MCP.Resources
  alias SlipdockWeb.MCP.Resources.Render

  defp context(user), do: %{user: user, token: %{scope: "write"}, base_url: ""}

  defp read!(user, uri) do
    {:ok, %{contents: [%{text: text, mimeType: "text/markdown"}]}} =
      Resources.read(uri, context(user))

    text
  end

  setup %{user: user} do
    board = board_fixture(%{"name" => "Payments", "description" => "Money in."}, owner: user)
    [first | _] = board.columns
    %{board: board, first: first}
  end

  describe "board" do
    test "lists each list with its open cards, and counts the done ones", ctx do
      open =
        card_fixture(ctx.first, %{
          "title" => "Fix the retry",
          "due_date" => "2026-11-01",
          "flags" => ["blocked"],
          "assignee_ids" => [ctx.user.id]
        })

      card_fixture(ctx.first, %{"title" => "Shipped", "completed" => true})

      text = read!(ctx.user, "slipdock://board/#{ctx.board.code}")

      assert text =~ "# Payments (code #{ctx.board.code}"
      assert text =~ "Money in."
      assert text =~ "## #{ctx.first.name}"
      assert text =~ "- ##{open.id} Fix the retry (due 2026-11-01; flagged blocked)"
      assert text =~ "- …and 1 done"
      refute text =~ "Shipped"
    end
  end

  describe "card" do
    test "has the handoff, description, checklist, subcards, comments and pages", ctx do
      card = card_fixture(ctx.first, %{"title" => "Epic", "description" => "The brief."})
      {:ok, _} = Boards.add_checklist_item(card, "Step one")
      {:ok, _} = Boards.add_comment(card, "Watch the retry limit.", by: ctx.user)

      {:ok, _} =
        Boards.leave_handoff(card, ctx.user, %{"next_step" => "Write the test", "via" => "mcp"})

      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card, t)
      child = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Child"})
      page = page_fixture(ctx.board, %{"title" => "Spec"}, user: ctx.user)
      {:ok, _} = Wiki.pin(page, {:card, card})

      text = read!(ctx.user, "slipdock://card/#{card.id}")

      assert text =~ "# ##{card.id} Epic"
      assert text =~ "Board: Payments · list: #{ctx.first.name}"
      assert text =~ "## Handoff\nLeft off: Write the test"
      assert text =~ "## Description\nThe brief."
      assert text =~ "## Checklist\n- [ ] Step one"
      assert text =~ "## Subcards\n- ##{child.id} Child"
      assert text =~ "## Recent comments"
      assert text =~ "Watch the retry limit."
      assert text =~ "## Wiki pages\n- #{page.code} Spec (pinned)"
    end

    test "an archived card says so", ctx do
      card = card_fixture(ctx.first, %{"title" => "Old"})
      {:ok, _} = Boards.archive_card(card)
      assert read!(ctx.user, "slipdock://card/#{card.id}") =~ "· archived"
    end

    test "only the newest comments, oldest of them first, with a count of the rest", ctx do
      card = card_fixture(ctx.first)

      for n <- 1..12 do
        {:ok, c} = Boards.add_comment(card, "Comment #{n}", by: ctx.user)

        Slipdock.Repo.update_all(
          from(x in Slipdock.Boards.Comment, where: x.id == ^c.id),
          set: [inserted_at: DateTime.add(~U[2026-01-01 00:00:00Z], n, :minute)]
        )
      end

      text = read!(ctx.user, "slipdock://card/#{card.id}")
      assert text =~ "(2 older, in get_card)"
      refute text =~ "Comment 2\n"
      assert :binary.match(text, "Comment 3") < :binary.match(text, "Comment 12")
    end
  end

  describe "page" do
    test "is the source, front matter included", ctx do
      page =
        page_fixture(
          ctx.board,
          %{"title" => "Q4", "body" => "---\ntags: [plan]\n---\n\nThe plan."},
          user: ctx.user
        )

      text = read!(ctx.user, "slipdock://page/#{page.code}")
      assert text =~ "tags: [plan]"
      assert text =~ "The plan."
    end

    test "an encrypted page returns its ciphertext and a note, not an error", ctx do
      secret = "🔐β 💡hint💡QUJDREVGR0g= 🔐"
      page = page_fixture(ctx.board, %{"title" => "Keys", "body" => secret}, user: ctx.user)
      assert Wiki.find_page(page.id) |> elem(1) |> Map.get(:encrypted)

      text = read!(ctx.user, "slipdock://page/#{page.code}")
      assert text =~ "Meld Encrypt ciphertext"
      assert text =~ secret
    end
  end

  describe "view" do
    test "is the saved view's rows of cards", ctx do
      card = card_fixture(ctx.first, %{"title" => "In the view"})
      {:ok, view} = Boards.create_saved_view(ctx.board, %{"name" => "All", "config" => %{}})

      text = read!(ctx.user, "slipdock://view/#{ctx.board.code}/#{view.id}")
      assert text =~ "# All\nSaved view on Payments"
      assert text =~ "##{card.id} In the view"
    end
  end

  describe "My work" do
    test "the cards assigned to me by section, with where they are", ctx do
      card = card_fixture(ctx.first, %{"title" => "Mine", "assignee_ids" => [ctx.user.id]})

      text = read!(ctx.user, "slipdock://work")
      assert text =~ "# My work"
      assert text =~ "## No due date\n- ##{card.id} Mine"
      assert text =~ "— Payments"
    end

    test "says so when nothing is assigned", ctx do
      assert read!(ctx.user, "slipdock://work") =~ "Nothing is assigned to me."
    end
  end

  describe "caps" do
    test "a long text is cut to the kind's cap with the tool for the rest" do
      text = Render.cut(String.duplicate("x", 50_000), :card, "get_card with card 7")
      assert String.length(text) <= Render.cap(:card)
      assert text =~ "…cut at the size cap: use get_card with card 7 for the rest."
    end

    test "a short text is left alone" do
      assert Render.cut("short", :board, "get_board") == "short\n"
    end

    test "a page over its cap points at read_page", ctx do
      page =
        page_fixture(ctx.board, %{"title" => "Long", "body" => String.duplicate("word ", 25_000)},
          user: ctx.user
        )

      text = read!(ctx.user, "slipdock://page/#{page.code}")
      assert String.length(text) <= Render.cap(:page)
      assert text =~ "use read_page with page #{page.code} for the rest"
    end
  end
end
