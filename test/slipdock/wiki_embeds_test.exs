defmodule Slipdock.WikiEmbedsTest do
  @moduledoc """
  Heading and block links, and embeds (W-103 R4.3): `[[Note#Heading]]`,
  `[[Note#^block]]`, `[[#Heading]]` on the same page, `![[Note]]` and
  `![[Note#Heading]]` — while `[[#412]]` stays a card.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki
  alias Slipdock.Wiki.Markup
  alias SlipdockWeb.Wiki.Renderer

  describe "the lexer" do
    test "page links carry an anchor: a heading or a ^block" do
      assert [%{kind: :page, target: "Note", anchor: "Backoff"}] = Markup.refs("[[Note#Backoff]]")
      assert [%{kind: :page, target: "Note", anchor: "^a1b2"}] = Markup.refs("[[Note#^a1b2]]")
      assert [%{kind: :page, target: "W-31", anchor: "Log"}] = Markup.refs("[[W-31#Log]]")

      assert [%{kind: :page, board: "QVM", target: "Note", anchor: "H", label: "x"}] =
               Markup.refs("[[QVM/Note#H|x]]")

      assert [%{kind: :page, target: "Note"} = plain] = Markup.refs("[[Note#]]")
      refute Map.has_key?(plain, :anchor)
    end

    test "[[#Heading]] is this page; [[#412]] is still card 412" do
      assert [%{kind: :page, target: "", anchor: "Setup steps"}] = Markup.refs("[[#Setup steps]]")
      assert [%{kind: :page, target: "", anchor: "^blk"}] = Markup.refs("[[#^blk]]")
      assert [%{kind: :card, target: "412"}] = Markup.refs("[[#412]]")
      assert Markup.refs("[[#]]") == []
    end

    test "![[…]] embeds a page, or a part of one; nothing else embeds" do
      assert [%{kind: :page, target: "Note", embed: true}] = Markup.refs("![[Note]]")

      assert [%{kind: :page, target: "Note", embed: true, anchor: "H"}] =
               Markup.refs("![[Note#H]]")

      assert [%{kind: :page} = link] = Markup.refs("[[Note]]")
      refute Map.get(link, :embed)

      assert Markup.tokens("![[#412]]") == [{:text, "![[#412]]"}]
      assert Markup.tokens("![[#Heading]]") == [{:text, "![[#Heading]]"}]
      assert "![[Note]]" == "![[Note]]" |> Markup.tokens() |> Enum.map_join(&Markup.raw/1)
    end

    test "plain text reads a same-page link as its words" do
      assert Markup.to_plain("see [[#Setup]]") == "see Setup"
    end
  end

  describe "on pages" do
    setup do
      user = user_fixture()
      board = board_fixture(%{"name" => "Brain", "code" => "embeds"}, owner: user)

      {:ok, note} =
        Wiki.create_page(
          board,
          %{
            "title" => "Note",
            "body" =>
              "Intro words.\n\n## Backoff\n\nWait longer each time.\n\n## Other\n\nElse.\n\nA key block ^blk1\n"
          },
          user: user
        )

      %{user: user, board: board, note: note}
    end

    defp html(ctx, body, opts \\ []),
      do: Renderer.to_html(body, Keyword.merge([board: ctx.board, as: ctx.user], opts))

    test "a heading link goes to the heading, named Note › Heading", ctx do
      out = html(ctx, "[[Note#Backoff]]")
      assert out =~ ~s(href="/boards/#{ctx.board.id}/wiki/note#backoff")
      assert out =~ "Note › Backoff"
    end

    test "headings carry the ids the links aim at", ctx do
      assert html(ctx, "## Setup steps") =~ ~s(id="setup-steps")
    end

    test "a same-page link needs no lookup and makes no wanted page", ctx do
      out = html(ctx, "[[#Setup steps]] and [[#^blk|that block]]")
      assert out =~ ~s(href="#setup-steps")
      assert out =~ ~s(href="#^blk")
      assert out =~ "that block"
      refute out =~ "wiki-wanted"
    end

    test "a block id becomes an anchor and is not shown", ctx do
      out = html(ctx, "A key block ^blk1")
      assert out =~ ~s(id="^blk1")
      refute out =~ "^blk1</"
      assert out =~ "A key block"
      assert html(ctx, "[[Note#^blk1]]") =~ ~s(note#^blk1")
    end

    test "![[Note]] draws the note in place", ctx do
      out = html(ctx, "Before\n\n![[Note]]\n\nAfter")
      assert out =~ ~s(class="wiki-embed")
      assert out =~ "Intro words."
      assert out =~ "Wait longer each time."
    end

    test "![[Note#Heading]] draws that section only, and ![[Note#^id]] that block", ctx do
      section = html(ctx, "![[Note#Backoff]]")
      assert section =~ "Wait longer each time."
      refute section =~ "Intro words."
      refute section =~ "Else."

      block = html(ctx, "![[Note#^blk1]]")
      assert block =~ "A key block"
      refute block =~ "Wait longer"
    end

    test "an embed of a heading that is not there is a link, not an error", ctx do
      out = html(ctx, "![[Note#Nowhere]]")
      refute out =~ "wiki-embed\""
      assert out =~ "Note › Nowhere"
    end

    test "embeds go one level deep and never round in a circle", ctx do
      {:ok, a} =
        Wiki.create_page(ctx.board, %{"title" => "A", "body" => "A says\n\n![[B]]"},
          user: ctx.user
        )

      {:ok, _b} =
        Wiki.create_page(ctx.board, %{"title" => "B", "body" => "B says\n\n![[A]]"},
          user: ctx.user
        )

      out = Renderer.to_html(a.body, page: a, as: ctx.user)
      assert out =~ "B says"
      # B's embed of A is drawn as a link, not as A again.
      assert length(String.split(out, "A says")) == 2
    end

    test "a reader who cannot open the page gets none of it", ctx do
      stranger = user_fixture("stranger@example.com")
      out = Renderer.to_html("![[Note]]", board: ctx.board, as: stranger)
      refute out =~ "Intro words."
    end

    test "a published page names what it embeds and shows none of it", ctx do
      out = html(ctx, "![[Note]]", static: true)
      refute out =~ "Intro words."
      assert out =~ "Note"
    end

    test "a file embed stays as written until attachments sync", ctx do
      out = html(ctx, "![[diagram.png]]")
      assert out =~ "![[diagram.png]]"
      refute out =~ "wiki-wanted"
    end

    test "the Markdown render quotes what an embed shows", ctx do
      out = Renderer.to_markdown("![[Note#Backoff]]", board: ctx.board, as: ctx.user)
      assert out =~ "> **[Note › Backoff](/boards/#{ctx.board.id}/wiki/note#backoff)**"
      assert out =~ "> Wait longer each time."
      assert Renderer.to_markdown("[[#Backoff]]", board: ctx.board) == "[Backoff](#backoff)"
    end

    test "links store the page, not the anchor; same-page links store nothing", ctx do
      {:ok, linker} =
        Wiki.create_page(
          ctx.board,
          %{"title" => "Linker", "body" => "[[Note#Backoff]] ![[Note]] [[#Here]]"},
          user: ctx.user
        )

      assert [%{target_page_id: id, count: 2}] = Wiki.outgoing_links(linker)
      assert id == ctx.note.id
      assert [%{page: %{id: linker_id}}] = Wiki.backlinks(ctx.note)
      assert linker_id == linker.id
    end

    test "a wanted [[Ghost#Part]] comes alive when Ghost is written", ctx do
      {:ok, linker} =
        Wiki.create_page(ctx.board, %{"title" => "Linker", "body" => "![[Ghost#Part]]"},
          user: ctx.user
        )

      assert [%{resolved: false}] = Wiki.outgoing_links(linker)
      assert [%{title: "Ghost"}] = Wiki.wanted(ctx.board)

      {:ok, ghost} =
        Wiki.create_page(ctx.board, %{"title" => "Ghost", "body" => "boo"}, user: ctx.user)

      assert [%{target_page_id: id}] = Wiki.outgoing_links(linker)
      assert id == ghost.id
    end
  end
end
