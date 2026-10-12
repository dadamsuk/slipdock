defmodule SlipdockWeb.AudioAttachmentTest do
  @moduledoc """
  A recording attached to a card: it plays in the card's Attachments, and
  with a transcription server set up, Transcribe puts its text underneath.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Settings}

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    board = board_fixture(%{"name" => "Recordings"})
    card = card_fixture(hd(board.columns), %{"title" => "Call with Acme"})
    path = Path.join(System.tmp_dir!(), "audio-#{System.unique_integer([:positive])}")
    File.write!(path, "ID3 fake audio")
    on_exit(fn -> File.rm(path) end)

    {:ok, audio} =
      Boards.add_attachment(card, %{filename: "call.mp3", content_type: "audio/mpeg"}, path)

    {:ok, pdf} =
      Boards.add_attachment(card, %{filename: "deck.pdf", content_type: "application/pdf"}, path)

    %{board: reload(board), card: card, audio: audio, pdf: pdf}
  end

  defp manuel(answer) do
    Req.Test.stub(Slipdock.Transcription, fn conn ->
      if conn.request_path == "/v1/status" do
        Req.Test.json(conn, %{"api_version" => "1.0.0", "capabilities" => []})
      else
        {status, body} = answer
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end
    end)
  end

  defp set_up_server do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => "admin@example.com",
        "transcription_server_url" => "https://manuel.example"
      })
  end

  test "a recording plays in place; other files don't get a player", %{
    conn: conn,
    board: board,
    card: card,
    audio: audio,
    pdf: pdf
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    assert has_element?(
             view,
             "#audio-#{audio.id}[controls][preload=metadata][src='#{Boards.attachment_url(audio)}']"
           )

    refute has_element?(view, "#audio-#{pdf.id}")
    # No server set up, no button.
    refute has_element?(view, "#transcribe-#{audio.id}")
  end

  test "Transcribe shows only beside recordings, once a server is set up", %{
    conn: conn,
    board: board,
    card: card,
    audio: audio,
    pdf: pdf
  } do
    set_up_server()
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    assert has_element?(view, "#transcribe-#{audio.id}", "Transcribe")
    refute has_element?(view, "#transcribe-#{pdf.id}")
  end

  test "pressing it puts the transcript under the recording", %{
    conn: conn,
    board: board,
    card: card,
    audio: audio
  } do
    set_up_server()
    manuel({200, %{"text" => "We agreed to ship on Friday."}})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    view |> element("#transcribe-#{audio.id}") |> render_click()

    assert has_element?(view, "#transcript-#{audio.id}", "We agreed to ship on Friday.")
    # Shown as written: no template whitespace before it in a pre-wrap block.
    assert view |> element("#transcript-#{audio.id} p") |> render() =~
             ~r/>We agreed to ship on Friday\.<\/p>/

    assert has_element?(view, "#transcribe-#{audio.id}", "Transcribe again")
    assert Boards.get_attachment!(audio.id).transcript == "We agreed to ship on Friday."
  end

  test "silence is said as such, not shown as an empty box", %{
    conn: conn,
    board: board,
    card: card,
    audio: audio
  } do
    set_up_server()
    manuel({200, %{"text" => ""}})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    view |> element("#transcribe-#{audio.id}") |> render_click()
    assert has_element?(view, "#transcript-#{audio.id}", "No speech was found")
  end

  test "a failure says why, and offers to try again", %{
    conn: conn,
    board: board,
    card: card,
    audio: audio
  } do
    set_up_server()
    manuel({401, %{"error" => %{"code" => "invalid_api_key", "message" => "bad key"}}})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    view |> element("#transcribe-#{audio.id}") |> render_click()

    assert has_element?(view, "#transcript-error-#{audio.id}", "refused the token")
    assert has_element?(view, "#transcribe-#{audio.id}", "Try again")
    refute has_element?(view, "#transcript-#{audio.id}")
  end

  test "while it runs the button says so and can't be pressed", %{
    conn: conn,
    board: board,
    card: card,
    audio: audio
  } do
    set_up_server()

    {:ok, _} =
      Boards.update_attachment_transcript(audio, %{
        transcript_status: "running",
        transcript_started_at: DateTime.utc_now(:second)
      })

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    assert has_element?(view, "#transcribe-#{audio.id}[disabled]", "Transcribing…")

    # Pushed anyway, nothing is sent and the reader is told.
    render_click(with_target(view, "#board-card"), "transcribe", %{"id" => to_string(audio.id)})
    assert render(view) =~ "It is being transcribed already."
  end

  test "a reader who can't change the card has no button", %{
    board: board,
    card: card,
    audio: audio
  } do
    set_up_server()
    reader = user_fixture("audio.reader@example.com")
    {:ok, _} = Slipdock.Access.grant(board, reader, "read", board.owner)

    {:ok, view, _} =
      build_conn() |> log_in_user(reader) |> live(~p"/boards/#{board}/cards/#{card.id}")

    assert has_element?(view, "#audio-#{audio.id}")
    refute has_element?(view, "#transcribe-#{audio.id}")

    render_click(with_target(view, "#board-card"), "transcribe", %{"id" => to_string(audio.id)})
    assert Boards.get_attachment!(audio.id).transcript_status == nil
  end
end
