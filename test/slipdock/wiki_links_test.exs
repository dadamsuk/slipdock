defmodule Slipdock.WikiLinksTest do
  @moduledoc """
  The wiki's own syntax: what it recognises, what it deliberately does not,
  what happens to a link when the thing it names is renamed, and the section
  addressing that lets two writers work on one page without colliding.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.{Markup, Section}
  alias SlipdockWeb.Wiki.Renderer

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Handbook", "code" => "handbook"}, owner: user)
    %{user: user, board: board, column: hd(board.columns)}
  end

  describe "the lexer" do
    test "reads every form of reference" do
      refs =
        Markup.refs("""
        [[Retry policy]] [[retry-policy|how it works]] [[QVM/Rollback]] [[W-31]]
        [[#412]] #99 W-7 [[board:qvm]] [[view:QVM/Blocked work]] [[!toc]] @jess
        """)

      assert %{kind: :page, target: "Retry policy", label: nil} = Enum.at(refs, 0)
      assert %{kind: :page, target: "retry-policy", label: "how it works"} = Enum.at(refs, 1)
      assert %{kind: :page, target: "Rollback", board: "QVM"} = Enum.at(refs, 2)
      assert %{kind: :page, target: "W-31"} = Enum.at(refs, 3)
      assert %{kind: :card, target: "412"} = Enum.at(refs, 4)
      assert %{kind: :card, target: "99"} = Enum.at(refs, 5)
      assert %{kind: :page, target: "W-7"} = Enum.at(refs, 6)
      assert %{kind: :board, target: "qvm"} = Enum.at(refs, 7)
      assert %{kind: :view, target: "Blocked work", board: "QVM"} = Enum.at(refs, 8)
      assert %{kind: :directive, target: "toc"} = Enum.at(refs, 9)
      assert %{kind: :mention, target: "jess"} = Enum.at(refs, 10)
    end

    # "Thanks @jess." took the full stop into the name, so a mention at the
    # end of a sentence never found anybody.
    test "a mention stops before trailing punctuation" do
      assert [%{kind: :mention, target: "jess"}] = Markup.refs("Thanks @jess.")
      assert [%{kind: :mention, target: "jess"}] = Markup.refs("over to @jess-, then")
      assert [%{kind: :mention, target: "jess.smith"}] = Markup.refs("ask @jess.smith.")
      assert [%{kind: :mention, target: "j"}] = Markup.refs("@j!")
      assert "Thanks @jess." |> Markup.tokens() |> Enum.map_join(&Markup.raw/1) == "Thanks @jess."
    end

    test "is lossless: the tokens rebuild the text" do
      text = "a [[X|y]] b #4 c W-9 d @e f"
      assert text |> Markup.tokens() |> Enum.map_join(&Markup.raw/1) == text
    end

    test "leaves code alone, because it is given the tree and not the source" do
      body = "Real [[Retry policy]] but `[[not a link]]` and\n\n```\n[[also not]]\n```\n"

      assert [%{target: "Retry policy"}] = Wiki.extract_links(body)
    end
  end

  describe "resolving" do
    test "finds pages by title, slug, code and across boards", %{board: board, user: user} do
      {:ok, target} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)
      other = board_fixture(%{"name" => "Elsewhere", "code" => "elsewhere"}, owner: user)
      {:ok, far} = Wiki.create_page(other, %{"title" => "Far away"}, user: user)

      body = """
      [[Retry policy]] [[retry-policy]] [[#{target.code}]] [[elsewhere/Far away]]
      [[Never written]]
      """

      {:ok, page} = Wiki.create_page(board, %{"title" => "Index", "body" => body}, user: user)
      links = Wiki.outgoing_links(page)

      resolved = Enum.filter(links, & &1.resolved)
      assert Enum.all?(Enum.take(resolved, 3), &(&1.target_page_id == target.id))
      assert Enum.any?(resolved, &(&1.target_page_id == far.id))

      assert [unresolved] = Enum.reject(links, & &1.resolved)
      assert unresolved.raw == "[[Never written]]"
    end

    test "a card reference resolves to the card, and a stray number does not", %{
      board: board,
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Fix the thing"})

      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Notes", "body" => "See ##{card.id} and #99999."},
          user: user
        )

      links = Wiki.outgoing_links(page)
      assert [%{kind: "card", resolved: true, target_card_id: id}, stray] = links
      assert id == card.id
      refute stray.resolved
    end

    test "counts repeats, so a page about a thing outranks a mention of it", %{
      board: board,
      user: user
    } do
      {:ok, _} = Wiki.create_page(board, %{"title" => "Deploys"}, user: user)

      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Notes", "body" => "[[Deploys]] and [[Deploys]]"},
          user: user
        )

      assert [%{count: 2}] = Wiki.outgoing_links(page)
    end
  end

  describe "backlinks and wanted pages" do
    test "a page knows what points at it", %{board: board, user: user} do
      {:ok, target} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)

      {:ok, source} =
        Wiki.create_page(board, %{"title" => "Runbook", "body" => "see [[Retry policy]]"},
          user: user
        )

      assert [%{page: %{id: id}}] = Wiki.backlinks(target)
      assert id == source.id
    end

    test "renaming a page does not break the links into it", %{board: board, user: user} do
      {:ok, target} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)

      {:ok, _} =
        Wiki.create_page(board, %{"title" => "Runbook", "body" => "see [[Retry policy]]"},
          user: user
        )

      {:ok, renamed} =
        Wiki.update_page(target, %{"title" => "Retries", "slug" => "retries"}, user: user)

      assert [%{page: %{title: "Runbook"}}] = Wiki.backlinks(renamed)
    end

    test "a link written before the page is a wanted page, and comes alive when written", %{
      board: board,
      user: user
    } do
      {:ok, _} =
        Wiki.create_page(board, %{"title" => "Runbook", "body" => "see [[Rollback procedure]]"},
          user: user
        )

      assert [%{title: "Rollback procedure", count: 1, from: [%{title: "Runbook"}]}] =
               Wiki.wanted(board)

      {:ok, written} = Wiki.create_page(board, %{"title" => "Rollback procedure"}, user: user)

      assert Wiki.wanted(board) == []
      assert [%{page: %{title: "Runbook"}}] = Wiki.backlinks(written)
    end

    test "a backlink from a page the reader cannot see is not shown", %{
      board: board,
      user: user
    } do
      {:ok, target} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)

      {:ok, _} =
        Wiki.create_page(
          board,
          %{"title" => "Secret plans", "status" => "draft", "body" => "[[Retry policy]]"},
          user: user
        )

      reader = user_fixture("links.reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)

      assert [_] = Wiki.backlinks(target, user)
      assert [] = Wiki.backlinks(target, reader)
    end
  end

  describe "pinning" do
    test "a page can be the spec for a card, and the card knows it", %{
      board: board,
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Ship it"})

      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Ship spec", "body" => "About ##{card.id}"},
          user: user
        )

      {:ok, _} = Wiki.pin(page, {:card, card})

      assert [%{pinned: true, page: %{id: id}}] = Wiki.pages_for_card(card)
      assert id == page.id
    end

    test "a pin survives an edit that rewrites the prose", %{
      board: board,
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Ship it"})

      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Ship spec", "body" => "About ##{card.id}"},
          user: user
        )

      {:ok, _} = Wiki.pin(page, {:card, card})
      {:ok, page} = Wiki.update_page(page, %{"body" => "Still about ##{card.id}."}, user: user)

      assert [%{pinned: true}] = Wiki.pages_for_card(card)
      assert [%{pinned: true}] = Wiki.outgoing_links(page)
    end

    test "a pin survives the prose losing every mention of the card", %{
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Ship it"})

      {:ok, page} = Wiki.create_page_from_card(card, user: user)
      assert [%{pinned: true}] = Wiki.pages_for_card(card)

      # What "Write it up" gives you is a stub. Replacing all of it — which
      # is the whole point of the stub — must not detach the page.
      {:ok, page} =
        Wiki.update_page(page, %{"body" => "Something else entirely."}, user: user)

      assert [%{pinned: true, page: %{id: id}}] = Wiki.pages_for_card(card)
      assert id == page.id
    end

    test "a page on an archived board stops turning up on the card", %{
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Ship it"})
      shelved = board_fixture(%{"name" => "Old project", "code" => "old"}, owner: user)

      {:ok, page} =
        Wiki.create_page(shelved, %{"title" => "Old spec", "body" => "About ##{card.id}"},
          user: user
        )

      assert [%{page: %{id: id}}] = Wiki.pages_for_card(card, user)
      assert id == page.id

      {:ok, _} = Slipdock.Boards.archive_board(shelved)

      assert [] = Wiki.pages_for_card(card, user)
    end

    test "unpinning takes the page off the card, rather than leaving it listed", %{
      board: board,
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Ship it"})

      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Spec", "body" => "No refs."}, user: user)

      {:ok, _} = Wiki.pin(page, {:card, card})
      assert [%{pinned: true}] = Wiki.pages_for_card(card)

      {:ok, _} = Wiki.pin(page, {:card, card}, false)
      assert [] = Wiki.pages_for_card(card)
    end

    test "unpinning a page that really names the card only unpins it", %{
      board: board,
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Ship it"})

      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Spec", "body" => "About ##{card.id}"}, user: user)

      {:ok, _} = Wiki.pin(page, {:card, card})
      {:ok, _} = Wiki.pin(page, {:card, card}, false)

      assert [%{pinned: false}] = Wiki.pages_for_card(card)
    end

    test "a recorded relation survives a rewrite too", %{
      board: board,
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Ship it"})

      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Notes", "body" => "Nothing."}, user: user)

      {:ok, _} = Slipdock.Wiki.Links.record(page, {:card, card})
      {:ok, _} = Wiki.update_page(page, %{"body" => "Still nothing."}, user: user)

      assert [%{pinned: false}] = Wiki.pages_for_card(card)
    end
  end

  describe "sections" do
    setup %{board: board, user: user} do
      body = """
      # Deploy

      How we ship.

      ## Rollback

      Stop the queue.

      ## Log

      - 2026-09-01 first
      """

      {:ok, page} = Wiki.create_page(board, %{"title" => "Runbook", "body" => body}, user: user)
      %{page: page}
    end

    test "are addressed by heading, in full or by path", %{page: page} do
      assert {:ok, text} = Wiki.read_section(page, "Deploy/Rollback")
      assert text =~ "Stop the queue"
      assert {:ok, ^text} = Wiki.read_section(page, "rollback")
    end

    test "a missed path says what there is instead", %{page: page} do
      assert {:error, :not_found, hint} = Wiki.read_section(page, "Nope")
      assert hint =~ "Deploy/Rollback"
    end

    test "appending to one leaves the rest alone and never conflicts", %{
      page: page,
      user: user
    } do
      {:ok, updated} =
        Wiki.append_section(page, "Log", "- 2026-09-29 rolled back",
          user: user,
          base_hash: "nonsense"
        )

      assert updated.body =~ "- 2026-09-01 first"
      assert updated.body =~ "- 2026-09-29 rolled back"
      assert updated.body =~ "Stop the queue"
    end

    test "two writers touching different sections do not collide", %{page: page, user: user} do
      other = user_fixture("sections.other@example.com")

      {:ok, _} = Wiki.append_section(page, "Log", "- from one", user: user)
      {:ok, after_both} = Wiki.append_section(page, "Rollback", "Then drain it.", user: other)

      assert after_both.body =~ "- from one"
      assert after_both.body =~ "Then drain it."
    end

    test "replacing a section takes its subsections with it", %{page: page, user: user} do
      {:ok, updated} =
        Wiki.replace_section(page, "Deploy/Rollback", "## Rollback\n\nNew words.", user: user)

      refute updated.body =~ "Stop the queue"
      assert updated.body =~ "New words."
      assert updated.body =~ "## Log"
    end

    test "headings inside fenced code are not headings" do
      body = "# Real\n\n```\n# Not real\n```\n"
      assert [%{title: "Real"}] = Section.headings(body)
    end
  end

  describe "rendering" do
    test "draws a card as a live chip and a page as a link", %{
      board: board,
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Fix the thing"})
      {:ok, target} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)

      html =
        Renderer.to_html("See [[Retry policy]] about ##{card.id}.", board: board, as: user)

      assert html =~ ~s|class="wiki-link"|
      assert html =~ Renderer.page_path(target)
      assert html =~ ~s|class="wiki-chip"|
      assert html =~ "Fix the thing"
    end

    test "an unwritten page reads as an invitation, a stray number as itself", %{board: board} do
      html = Renderer.to_html("[[Nothing here]] and #98765 and `[[in code]]`", board: board)

      assert html =~ "wiki-wanted"
      assert html =~ "/wiki/new?title=Nothing+here"
      assert html =~ "#98765"
      refute html =~ ~s|<a href="#98765"|
      assert html =~ "[[in code]]"
    end

    test "a chip for a card the reader cannot open degrades to text", %{
      board: board,
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Commercially sensitive"})
      outsider = user_fixture("render.outsider@example.com")

      as_owner = Renderer.to_html("About ##{card.id}", board: board, as: user)
      as_outsider = Renderer.to_html("About ##{card.id}", board: board, as: outsider)

      assert as_owner =~ "Commercially sensitive"
      refute as_outsider =~ "Commercially sensitive"
      assert as_outsider =~ "##{card.id}"
    end

    test "never lets script through, whoever wrote it", %{board: board} do
      html = Renderer.to_html("<script>alert(1)</script><img src=x onerror=y>", board: board)

      refute html =~ "script"
      refute html =~ "onerror"
    end

    test "expands the directives", %{board: board, user: user} do
      {:ok, parent} =
        Wiki.create_page(board, %{"title" => "Deploys", "body" => "# A\n\n## B\n\n[[!toc]]"},
          user: user
        )

      {:ok, _} =
        Wiki.create_page(board, %{"title" => "Rollback", "parent_id" => parent.id}, user: user)

      html = Renderer.to_html(parent.body, page: parent, board: board, as: user)
      assert html =~ "wiki-toc"
      assert html =~ ">A</a>"

      children = Renderer.to_html("[[!children]]", page: parent, board: board, as: user)
      assert children =~ "wiki-children"
      assert children =~ "Rollback"
    end

    test "resolves to Markdown for an agent, answers rather than syntax", %{
      board: board,
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Fix the thing"})
      {:ok, _} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)

      markdown =
        Renderer.to_markdown("See [[Retry policy]] about ##{card.id}.", board: board, as: user)

      assert markdown =~ "[Retry policy](/boards/#{board.id}/wiki/retry-policy)"
      assert markdown =~ "Fix the thing (##{card.id}"
    end
  end

  describe "a link row" do
    alias Slipdock.Wiki.Link

    defp link_changeset(attrs), do: Link.changeset(%Link{}, attrs)

    test "takes a kind it knows, its raw text and exactly one source", %{board: board, user: user} do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Source"}, user: user)

      changeset = link_changeset(%{kind: "page", raw: "[[X]]", page_id: page.id, label: "x"})
      assert changeset.valid?

      assert Link.kinds() == ~w(page card board view external)

      for kind <- Link.kinds() do
        assert link_changeset(%{kind: kind, raw: "r", page_id: page.id}).valid?
      end
    end

    test "refuses a missing kind or raw, or a kind it does not know", %{board: board, user: user} do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Source"}, user: user)

      errors = errors_on(link_changeset(%{page_id: page.id}))
      assert "can't be blank" in errors.kind
      assert "can't be blank" in errors.raw

      assert "is invalid" in errors_on(
               link_changeset(%{kind: "telepathy", raw: "r", page_id: page.id})
             ).kind
    end

    test "refuses no source, and refuses two", %{board: board, user: user, column: column} do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Source"}, user: user)
      card = card_fixture(column)
      {:ok, comment} = Slipdock.Boards.add_comment(card, "see [[Source]]")

      assert %{page_id: ["exactly one source must be set"]} =
               errors_on(link_changeset(%{kind: "page", raw: "r"}))

      assert %{page_id: ["exactly one source must be set"]} =
               errors_on(
                 link_changeset(%{
                   kind: "page",
                   raw: "r",
                   page_id: page.id,
                   source_comment_id: comment.id
                 })
               )

      # A comment on its own is a source, with the card it was written on
      # carried alongside rather than counted as a second one.
      assert link_changeset(%{
               kind: "page",
               raw: "r",
               source_comment_id: comment.id,
               source_card_id: card.id,
               target_page_id: page.id
             }).valid?
    end
  end
end
