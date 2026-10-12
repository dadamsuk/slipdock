defmodule Slipdock.WikiNoteTagsTest do
  @moduledoc """
  Inline `#tags` and nested tags (W-103 R3.4): read from a note's front
  matter and body on a board in a vault, kept apart from the board's card
  tags, and left alone everywhere else.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Vaults, Wiki}
  alias Slipdock.Wiki.NoteTags

  describe "extract/2" do
    test "inline tags, nested tags, and the front matter's own" do
      body = "Ideas for #work and #area/sub-topic, (#paren) and #Mixed_Case.\n\n- item #listed"
      header = "---\ntags: [from-yaml, \"#hashed\"]\n---\n"

      assert NoteTags.extract(body, header) ==
               ~w(area/sub-topic from-yaml hashed listed mixed_case paren work)
    end

    test "front matter tags as a block list, or as words" do
      assert NoteTags.extract("", "---\ntags:\n  - one\n  - two\n---\n") == ~w(one two)
      assert NoteTags.extract("", "---\ntags: one, two three\n---\n") == ~w(one three two)
      assert NoteTags.extract("", nil) == []
    end

    test "not in code, headings, links, HTML or URLs" do
      body = """
      # Heading #not-this

      `#inline-code` and [a #link](https://x.example/#frag) and https://example.com/#anchor

      ```
      #fenced
      ```

      <div>#html</div>

      but #this
      """

      assert NoteTags.extract(body, nil) == ["this"]
    end

    test "digits stay card references: #412 and #2026/q1 are not tags" do
      assert NoteTags.extract("See #412 and #2026/q1 but #q1/2026 and #v2", nil) == ~w(q1/2026 v2)
    end

    test "tags are kept once, lower-case, without a trailing slash" do
      assert NoteTags.extract("#Ideas #ideas #ideas/", "---\ntags: IDEAS\n---\n") == ["ideas"]
    end
  end

  describe "on a board" do
    setup do
      user = user_fixture()
      board = board_fixture(%{"name" => "Brain", "code" => "brain"}, owner: user)
      outside = board_fixture(%{"name" => "Work", "code" => "work"}, owner: user)
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
      %{user: user, board: board, outside: outside, vault: vault}
    end

    test "a save in a vault reads them; the board's card tags are untouched", ctx do
      {:ok, page} =
        Wiki.create_page(ctx.board, %{"title" => "Note", "body" => "#idea #area/sub"},
          user: ctx.user
        )

      assert page.note_tags == ~w(area/sub idea)
      assert Wiki.get_page!(page.id).note_tags == ~w(area/sub idea)
      assert Wiki.tags(page) == []

      assert Boards.list_tags(ctx.board.id)
             |> Enum.map(& &1.name)
             |> Enum.filter(&(&1 in ~w(idea area/sub))) == []

      {:ok, page} = Wiki.update_page(page, %{"body" => "now #other"}, user: ctx.user)
      assert page.note_tags == ["other"]
    end

    test "a board outside a vault is unchanged: #word is a word", ctx do
      {:ok, page} =
        Wiki.create_page(ctx.outside, %{"title" => "Note", "body" => "#idea"}, user: ctx.user)

      assert page.note_tags == []
      assert Wiki.list_pages(ctx.outside, note_tag: "idea") == []
    end

    test "joining a vault reads the board's notes; leaving clears them", ctx do
      {:ok, page} =
        Wiki.create_page(ctx.outside, %{"title" => "Note", "body" => "#idea"}, user: ctx.user)

      {:ok, _} = Vaults.add_mapping(ctx.vault, ctx.user, %{path: "/Work", board: ctx.outside})
      assert Wiki.get_page!(page.id).note_tags == ["idea"]

      {:ok, _} = Vaults.remove_mapping(ctx.vault, "/Work")
      assert Wiki.get_page!(page.id).note_tags == []

      {:ok, in_vault} =
        Wiki.create_page(ctx.board, %{"title" => "Kept", "body" => "#x"}, user: ctx.user)

      {:ok, _} = Vaults.delete_vault(ctx.vault)
      assert Wiki.get_page!(in_vault.id).note_tags == []
    end

    test "listing by tag finds the tag and what is nested under it", ctx do
      for {title, body} <- [{"A", "#area"}, {"B", "#area/sub"}, {"C", "#areas"}, {"D", "none"}] do
        {:ok, _} =
          Wiki.create_page(ctx.board, %{"title" => title, "body" => body}, user: ctx.user)
      end

      titles = fn tag ->
        ctx.board |> Wiki.list_pages(note_tag: tag) |> Enum.map(& &1.title) |> Enum.sort()
      end

      assert titles.("area") == ~w(A B)
      assert titles.("#Area/Sub") == ~w(B)
      assert titles.("missing") == []
    end

    test "counts carry nested tags up to their parents, and skip archived notes", ctx do
      {:ok, _} =
        Wiki.create_page(ctx.board, %{"title" => "A", "body" => "#area/sub #solo"},
          user: ctx.user
        )

      {:ok, _} = Wiki.create_page(ctx.board, %{"title" => "B", "body" => "#area"}, user: ctx.user)

      {:ok, gone} =
        Wiki.create_page(ctx.board, %{"title" => "C", "body" => "#area #gone"}, user: ctx.user)

      {:ok, _} = Wiki.archive_page(gone)

      assert NoteTags.counts(ctx.board) == [
               %{tag: "area", count: 2},
               %{tag: "area/sub", count: 1},
               %{tag: "solo", count: 1}
             ]
    end
  end
end
