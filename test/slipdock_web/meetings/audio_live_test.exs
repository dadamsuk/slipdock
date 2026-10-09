defmodule SlipdockWeb.Meetings.AudioLiveTest do
  @moduledoc """
  Recordings on the pages (#545): the upload page names the transcriber
  before anything is sent, and a capture whose recording has been deleted
  says replay is gone.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Meetings, Settings}
  alias Slipdock.Meetings.Audio

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    %{board: board}
  end

  defp upload_audio(view) do
    view
    |> file_input("#new-capture-form", :audio, [%{name: "call.wav", content: "RIFF....WAVE", type: "audio/wav"}])
    |> render_upload("call.wav")
  end

  test "with a transcriber set up, the upload page names it before anything is sent", %{conn: conn, board: board} do
    {:ok, _} = Settings.update(%{"meetings_transcription" => "endpoint", "meetings_transcription_url" => "http://whisper.example/v1", "meetings_transcription_model" => "large-v3"})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/new")
    upload_audio(view)

    html = view |> element("#capture-destination") |> render()
    assert html =~ "The recording is transcribed by"
    assert html =~ "large-v3"
    assert html =~ "whisper.example"
  end

  test "with none, it says the recording stays here and needs a transcript", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/new")
    upload_audio(view)
    assert view |> element("#capture-destination") |> render() =~ "it transcribes nothing, so send a transcript with it"
  end

  test "a capture says how long its recording is kept, then that replay is gone", %{conn: conn, board: board, user: user} do
    path = Path.join(System.tmp_dir!(), "l-#{System.unique_integer([:positive])}.wav")
    File.write!(path, "RIFF....WAVE")
    on_exit(fn -> File.rm(path) end)

    {:ok, capture} =
      Meetings.create_capture(board, user, %{title: "Call", fingerprint: Meetings.fingerprint(audio: path), retention: "90_days"},
        audio: %{path: path, filename: "call.wav"}
      )

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}")
    assert view |> element("#recording-kept") |> render() =~ "recording kept for 90 days"

    Audio.purge(capture)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/meetings/#{capture.id}")
    assert view |> element("#recording-gone") |> render() =~ "replay is no longer possible"
    refute has_element?(view, "#recording-kept")
  end
end
