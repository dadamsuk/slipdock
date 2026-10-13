defmodule Slipdock.WikiMeldTest do
  @moduledoc """
  Meld Encrypt's ciphertext on the server (W-103 R6): recognised, drawn
  locked, kept out of search and excerpts, marked on the page and in the
  tree — and never decrypted here. The vectors come from Meld's own code
  (test/support/fixtures/meld_vectors.json).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Repo
  alias Slipdock.Search.Chunk
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Meld, Page, Tree, WikiFile}
  alias SlipdockWeb.Wiki.Renderer

  @vectors "test/support/fixtures/meld_vectors.json" |> File.read!() |> Jason.decode!()
  @inline @vectors["inline"]

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Vault"}, owner: user)
    %{user: user, board: board}
  end

  defp v(n), do: Enum.at(@inline, n)

  describe "Meld" do
    test "recognises every version and both reading-view markers, as Meld wrote them" do
      for vector <- @inline do
        assert [block] = Meld.blocks("before " <> vector["text"] <> " after")
        assert block.text == vector["text"]
        assert block.version == vector["version"]
        assert block.hint == vector["hint"]
        assert block.visible == vector["visible"]
        assert Meld.encrypted?(vector["text"])
      end
    end

    test "an emoji on its own, or a block that is not closed, is not ciphertext" do
      refute Meld.encrypted?("🔐 just a lock emoji")
      refute Meld.encrypted?("🔐β abc")
      refute Meld.encrypted?(nil)
      assert Meld.blocks(nil) == []
    end

    test "conceal swaps each block for a lock, and drops one cut off at the end" do
      text = "PIN #{v(0)["text"]} and #{v(2)["text"]}."
      assert Meld.conceal(text) == "PIN 🔒 and 🔒."
      assert Meld.conceal(text, "") == "PIN  and ."
      cut = "Start " <> String.slice(v(0)["text"], 0, 40)
      assert Meld.conceal(cut) == "Start 🔒"
      assert Meld.conceal(nil) == nil
    end

    test "replace with a function sees each block" do
      assert Meld.replace("a #{v(0)["text"]} b", fn block -> "[#{block.hint}]" end) ==
               "a [the usual] b"
    end

    test "whole-note files: by name, and by what they hold" do
      assert Meld.note_file?("Secret.mdenc")
      assert Meld.note_file?("Old.ENCRYPTED")
      refute Meld.note_file?("Secret.md")
      refute Meld.note_file?(nil)

      for note <- @vectors["notes"] do
        assert %{version: version, hint: hint} = Meld.parse_note(note["file"])
        assert version == note["version"]
        assert hint == note["hint"]
      end

      assert Meld.parse_note(~s|{"version": "9.0", "encodedData": ""}|) == nil
      assert Meld.parse_note("not json") == nil
      assert Meld.parse_note(nil) == nil
    end
  end

  describe "rendering" do
    test "a block is drawn locked with its hint, carrying only the ciphertext" do
      html = Renderer.to_html("My PIN: #{v(0)["text"]} — keep it safe.")
      assert html =~ ~s|class="meld-locked"|
      assert html =~ ~s|data-meld-block="#{v(0)["text"]}"|
      assert html =~ ~s|<span class="meld-hint">the usual</span>|
      assert html =~ "My PIN:"
      assert html =~ "keep it safe."
      refute html =~ v(0)["plaintext"]
    end

    test "a hidden (%%) block is drawn too, and with no hint there is no hint" do
      html = Renderer.to_html(v(1)["text"])
      assert html =~ ~s|data-meld-block="%%🔐β |
      refute html =~ "meld-hint"
    end

    test "a hint is escaped, in the attribute and in the label" do
      text = String.replace(v(0)["text"], "the usual", ~s|Tom & "Jerry"|)
      html = Renderer.to_html(text)
      assert html =~ "meld-locked"
      assert html =~ ~s|data-meld-block="🔐β 💡Tom &amp; &quot;Jerry&quot;💡|
      assert html =~ ~s|<span class="meld-hint">Tom &amp; "Jerry"</span>|
    end

    test "markup in a hint is sanitised like any other, and the block is left as text" do
      html =
        Renderer.to_html(
          String.replace(v(0)["text"], "the usual", "<img src=x onerror=alert(1)>")
        )

      refute html =~ "onerror"
    end

    test "inside a code span it stays code" do
      html = Renderer.to_html("`#{v(0)["text"]}`")
      refute html =~ "meld-locked"
      assert html =~ "<code>"
    end

    test "wiki links next to a block still resolve as text around it", %{board: board, user: user} do
      page_fixture(board, %{"title" => "Target"}, user: user)
      html = Renderer.to_html("See [[Target]] #{v(0)["text"]} [[Target]]", board: board)
      assert length(Regex.scan(~r/class="wiki-link"/, html)) == 2
      assert html =~ "meld-locked"
    end

    test "the excerpt shows a lock, not base64" do
      assert Renderer.excerpt("Notes #{v(0)["text"]} here") == "Notes 🔒 here"
    end
  end

  describe "the page" do
    test "records that it holds ciphertext, on create and on every save", %{
      board: board,
      user: user
    } do
      page =
        page_fixture(board, %{"title" => "Secrets", "body" => "PIN: #{v(0)["text"]}"}, user: user)

      assert page.encrypted

      {:ok, page} = Wiki.update_page(page, %{"body" => "nothing now"}, user: user)
      refute page.encrypted
      refute Repo.get!(Page, page.id).encrypted

      {:ok, page} = Wiki.update_page(page, %{"body" => v(1)["text"]}, user: user)
      assert Repo.get!(Page, page.id).encrypted
    end

    test "keeps the ciphertext byte for byte", %{board: board, user: user} do
      body = "a\r\n#{v(1)["text"]}\r\n#{v(4)["text"]}\n"
      page = page_fixture(board, %{"title" => "Bytes", "body" => body}, user: user)
      assert Repo.get!(Page, page.id).body == body
    end

    test "search indexes the words around a block and never the ciphertext", %{
      board: board,
      user: user
    } do
      page =
        page_fixture(
          board,
          %{"title" => "Bank", "body" => "Sort code #{v(0)["text"]} at the branch"},
          user: user
        )

      chunks = page |> Repo.preload(:board) |> Chunk.for_page()
      text = Enum.map_join(chunks, " ", & &1.body)
      assert text =~ "Sort code"
      assert text =~ "at the branch"
      refute text =~ "🔐"
      refute text =~ Meld.blocks(v(0)["text"]) |> hd() |> Map.get(:base64)
    end

    test "the tree shows a lock on a page holding ciphertext and on a whole encrypted note",
         %{board: board, user: user} do
      page_fixture(board, %{"title" => "Locked", "body" => v(0)["text"]}, user: user)
      page_fixture(board, %{"title" => "Open", "body" => "plain"}, user: user)

      Repo.insert!(%WikiFile{
        board_id: board.id,
        name: "Diary.mdenc",
        content_type: "application/octet-stream",
        size: 1,
        sha256: "x",
        key: "k/Diary.mdenc"
      })

      {:ok, rows} = Tree.children(board, :root)
      by_title = Map.new(rows, &{&1.title, &1})
      assert by_title["Locked"].encrypted
      refute by_title["Open"].encrypted
      assert by_title["Diary.mdenc"].encrypted
    end
  end
end
