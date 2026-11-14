defmodule SlipdockWeb.DocumentTextLiveTest do
  @moduledoc """
  The text read from a file, on the card panel and in search results.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query, only: [from: 2]

  alias Slipdock.{Boards, OCR, TestConfig}

  setup %{user: user} do
    TestConfig.own_uploads_dir()
    board = board_fixture(%{"name" => "Paper", "code" => "ocrl1"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Scans"})
    path = Path.join(System.tmp_dir!(), "ocr-live-#{System.unique_integer([:positive])}")
    File.write!(path, <<0x89, "PNG", 0, 0, 0, 0>>)
    on_exit(fn -> File.rm(path) end)

    {:ok, a} =
      Boards.Attachments.add_attachment(
        card,
        %{filename: "s.png", content_type: "image/png"},
        path
      )

    %{board: board, card: card, attachment: a}
  end

  defp open(conn, board, card), do: live(conn, ~p"/boards/#{board}/cards/#{card.id}")

  test "nothing shows while it waits its turn", %{conn: conn} = ctx do
    {:ok, view, _} = open(conn, ctx.board, ctx.card)

    refute has_element?(view, "#document-#{ctx.attachment.id}")
    refute has_element?(view, "#document-error-#{ctx.attachment.id}")
  end

  test "the text shows under the file once read", %{conn: conn} = ctx do
    TestConfig.put(:ocr, run: fn _, _ -> {"Invoice 42", 0} end)
    OCR.run_next()

    {:ok, view, _} = open(conn, ctx.board, ctx.card)

    assert has_element?(view, "#document-#{ctx.attachment.id}-part-1", "Invoice 42")
  end

  test "a file with no words shows nothing", %{conn: conn} = ctx do
    TestConfig.put(:ocr, run: fn _, _ -> {" ", 0} end)
    OCR.run_next()

    {:ok, view, _} = open(conn, ctx.board, ctx.card)
    refute has_element?(view, "#document-#{ctx.attachment.id}")
  end

  test "?at= opens the text at the part that matched", %{conn: conn} = ctx do
    TestConfig.put(:ocr, run: fn _, _ -> {"Invoice 42", 0} end)
    OCR.run_next()
    at = "document-#{ctx.attachment.id}-part-1"

    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}?at=#{at}")

    assert has_element?(view, "details#document-#{ctx.attachment.id}[open]")
  end

  test "a failure says why, and Try again reads it again", %{conn: conn} = ctx do
    TestConfig.put(:ocr, run: fn _, _ -> {"", 1} end)
    OCR.run_next()

    {:ok, view, _} = open(conn, ctx.board, ctx.card)
    assert has_element?(view, "#document-error-#{ctx.attachment.id}", "the image can't be read")

    view |> element("#read-text-#{ctx.attachment.id}") |> render_click()

    assert OCR.text_of(ctx.attachment).status == "queued"
    refute has_element?(view, "#panel-notice")
  end

  describe "Read text refused (#2895): said in the panel, and the card stays open" do
    defp read_text(view, id),
      do:
        view |> with_target("#board-card") |> render_click("read_text", %{"id" => to_string(id)})

    defp notice, do: "#card-modal #panel-notice[data-callout=error]"

    test "while the file is being read", %{conn: conn} = ctx do
      {1, _} =
        Slipdock.Repo.update_all(
          from(t in OCR.Text, where: t.attachment_id == ^ctx.attachment.id),
          set: [status: "running"]
        )

      {:ok, view, _} = open(conn, ctx.board, ctx.card)
      read_text(view, ctx.attachment.id)

      assert has_element?(view, notice(), "It is being read already.")
      refute has_element?(view, "#flash-error")
      assert has_element?(view, "#card-modal")
      assert OCR.text_of(ctx.attachment).status == "running"
    end

    test "a file that isn't a PDF or an image", %{conn: conn} = ctx do
      path = Path.join(System.tmp_dir!(), "ocr-live-#{System.unique_integer([:positive])}")
      File.write!(path, "ID3 fake audio")
      on_exit(fn -> File.rm(path) end)

      {:ok, audio} =
        Boards.Attachments.add_attachment(
          ctx.card,
          %{filename: "call.mp3", content_type: "audio/mpeg"},
          path
        )

      {:ok, view, _} = open(conn, ctx.board, ctx.card)
      read_text(view, audio.id)

      assert has_element?(view, notice(), "Only PDFs and images are read for text.")
      refute has_element?(view, "#flash-error")
      assert has_element?(view, "#card-modal")
    end

    test "a file that isn't the card's says nothing and reads nothing", %{conn: conn} = ctx do
      other = card_fixture(hd(ctx.board.columns), %{"title" => "Elsewhere"})
      {:ok, view, _} = open(conn, ctx.board, other)

      read_text(view, ctx.attachment.id)
      read_text(view, "nope")

      refute has_element?(view, "#panel-notice")
      refute has_element?(view, "#flash-error")
      assert has_element?(view, "#card-modal")
    end
  end
end
