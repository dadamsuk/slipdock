defmodule SlipdockWeb.SearchLinksTest do
  @moduledoc """
  Search results that land where they matched: the link each kind of match
  gets, the `?at=` the card panel accepts, and what a match is called.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Search}
  alias Slipdock.Boards.Card
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.SearchLinks

  @card %Card{id: 12, board_id: 3}

  describe "path/2" do
    test "a card's own text goes to the card; the rest to the thing inside it" do
      assert SearchLinks.path(@card, %{kind: "card", source_id: 12, section: ""}) ==
               "/boards/3/cards/12"

      for {kind, section, at} <- [
            {"comment", "", "comment-7"},
            {"status_update", "", "status-update-7"},
            {"provenance", "", "provenance-7"},
            {"transcript", "", "transcript-7"},
            {"transcript", "part 3", "transcript-7-part-3"}
          ] do
        assert SearchLinks.path(@card, %{kind: kind, source_id: 7, section: section}) ==
                 "/boards/3/cards/12?at=#{at}"
      end
    end

    test "a page section goes to its heading's anchor" do
      page = %Page{board_id: 3, slug: "runbook"}
      assert SearchLinks.path(page, %{kind: "page", section: ""}) == "/boards/3/wiki/runbook"

      assert SearchLinks.path(page, %{kind: "page_section", section: "Deploy/Roll back#2"}) ==
               "/boards/3/wiki/runbook#roll-back"
    end
  end

  test "at/1 takes only what path/2 writes" do
    for good <- ~w(comment-1 status-update-22 provenance-3 transcript-4 transcript-4-part-12) do
      assert SearchLinks.at(good) == good
    end

    for bad <- [nil, "", "card-1", "comment-", "comment-1;x", "transcript-4-part-", "<script>"] do
      assert SearchLinks.at(bad) == nil
    end
  end

  test "label/1 says what the match is, a transcript by file and part" do
    assert SearchLinks.label(%{kind: "comment", section: "", body: "x"}) == "comment"

    assert SearchLinks.label(%{kind: "page_section", section: "A/B#2", body: "x"}) == "B"

    assert SearchLinks.label(%{
             kind: "transcript",
             section: "part 2",
             body:
               "Transcript of the recording “call.mp3” on card “C” (B), part 2 of 5:\nSteve: hi"
           }) == "transcript of call.mp3, part 2 of 5"

    assert SearchLinks.label(%{
             kind: "transcript",
             section: "",
             body: "Transcript of the recording “call.mp3” on card “C” (B):\nSteve: hi"
           }) == "transcript of call.mp3"

    assert SearchLinks.label(%{kind: "transcript", section: "", body: "odd"}) ==
             "recording transcript"
  end

  describe "landing in the card" do
    setup %{user: user} do
      Slipdock.TestConfig.own_uploads_dir()
      board = board_fixture(%{"name" => "Calls"}, owner: user)
      card = card_fixture(hd(board.columns), %{"title" => "Call with Acme"})
      path = Path.join(System.tmp_dir!(), "rec-#{System.unique_integer([:positive])}")
      File.write!(path, "ID3")
      on_exit(fn -> File.rm(path) end)

      {:ok, audio} =
        Boards.add_attachment(card, %{filename: "call.mp3", content_type: "audio/mpeg"}, path)

      lines =
        for n <- 1..60, do: "Speaker #{rem(n, 2) + 1}: line #{n}#{String.duplicate(" words", 8)}"

      {:ok, audio} =
        Boards.update_attachment_transcript(audio, %{
          transcript_status: "done",
          transcript: Enum.join(lines, "\n")
        })

      %{board: board, card: card, audio: audio}
    end

    test "a transcript opens at the part that matched, lit, and the page is asked to scroll",
         ctx do
      parts = Slipdock.Search.Chunk.transcript_parts(ctx.audio.transcript)
      assert length(parts) >= 3
      at = "transcript-#{ctx.audio.id}-part-2"

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}?at=#{at}")

      assert_push_event(view, "scroll-to-anchor", %{id: ^at})
      assert has_element?(view, "details#transcript-#{ctx.audio.id}[open]")

      assert has_element?(
               view,
               "##{at}.bg-warning\\/15",
               hd(String.split(Enum.at(parts, 1), "\n"))
             )

      refute has_element?(view, "#transcript-#{ctx.audio.id}-part-1.bg-warning\\/15")

      # Every part is drawn, the whole transcript between them.
      for n <- 1..length(parts),
          do: assert(has_element?(view, "#transcript-#{ctx.audio.id}-part-#{n}"))
    end

    test "a comment is scrolled to; without ?at the transcript stays folded", ctx do
      {:ok, comment} = Boards.add_comment(ctx.card, "they want it by Friday")

      {:ok, view, _} =
        live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}?at=comment-#{comment.id}")

      assert_push_event(view, "scroll-to-anchor", %{id: id})
      assert id == "comment-#{comment.id}"
      assert has_element?(view, "#comment-#{comment.id}")
      refute has_element?(view, "details#transcript-#{ctx.audio.id}[open]")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      refute has_element?(view, "details#transcript-#{ctx.audio.id}[open]")
    end

    test "an ?at that isn't one of ours is ignored", ctx do
      {:ok, view, _} =
        live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}?at=x%22%3E%3Cscript%3E")

      refute_push_event(view, "scroll-to-anchor", _)
      assert has_element?(view, "#card-attachments")
    end

    test "a search result links its transcript match straight to the part", ctx do
      Slipdock.AIStub.stub_embeddings()
      {:ok, _} = Search.index_card(ctx.card.id)

      {:ok, view, _} = live(ctx.conn, ~p"/search")
      view |> form("#deep-search") |> render_change(%{"q" => "Speaker line words"})
      render_async(view)

      assert has_element?(
               view,
               "a.match-link[href^='/boards/#{ctx.board.id}/cards/#{ctx.card.id}?at=transcript-#{ctx.audio.id}-part-']",
               "transcript of call.mp3, part"
             )
    end
  end
end
