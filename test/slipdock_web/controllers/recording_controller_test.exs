defmodule SlipdockWeb.RecordingControllerTest do
  @moduledoc "A meeting page's recording, streamed from Google Drive (W-1690)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GoogleStub

  alias Slipdock.{Repo, Vaults}

  @audio_bytes :binary.copy("0123456789", 100)
  @drive [
    %{
      "id" => "fold",
      "name" => "Rec",
      "mimeType" => "application/vnd.google-apps.folder",
      "parents" => ["root"]
    },
    %{
      "id" => "aud",
      "name" => "m.m4a",
      "mimeType" => "audio/mp4",
      "size" => "1000",
      "parents" => ["fold"],
      content: :binary.copy("0123456789", 100)
    },
    %{"id" => "doc", "name" => "n.pdf", "mimeType" => "application/pdf", "parents" => ["fold"]},
    %{"id" => "out", "name" => "x.m4a", "mimeType" => "audio/mp4", "parents" => ["root"]}
  ]

  setup %{user: user} do
    board = board_fixture(%{"name" => "Notes"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
    vault = vault |> Ecto.Changeset.change(recordings_folder: "Rec") |> Repo.update!()
    connect!(user)
    drive!(@drive)
    %{board: board, vault: vault}
  end

  defp meeting(board, front_matter) do
    page_fixture(board, %{
      "title" => "Meeting #{System.unique_integer([:positive])}",
      "front_matter" => "---\n" <> front_matter <> "\n---\n\n",
      "body" => "Summary"
    })
  end

  test "streams the whole recording", %{conn: conn, board: board} do
    page = meeting(board, "recording: gdrive:Rec/m.m4a")
    conn = get(conn, ~p"/wiki-pages/#{page.id}/recording")

    assert conn.status == 200
    assert response(conn, 200) == @audio_bytes
    assert get_resp_header(conn, "content-type") == ["audio/mp4"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "passes a range on and relays the 206", %{conn: conn, board: board} do
    page = meeting(board, "recording: gdrive:Rec/m.m4a\nrecording_drive_id: aud")

    conn =
      conn
      |> put_req_header("range", "bytes=10-19")
      |> get(~p"/wiki-pages/#{page.id}/recording")

    assert response(conn, 206) == "0123456789"
    assert get_resp_header(conn, "content-range") == ["bytes 10-19/1000"]
    assert_received {:drive, "GET", "/drive/v3/files/aud", %{"alt" => "media"}}
  end

  test "writes nothing to the uploads directory", %{conn: conn, board: board} do
    dir = Slipdock.TestConfig.own_uploads_dir()
    page = meeting(board, "recording: gdrive:Rec/m.m4a")

    assert response(get(conn, ~p"/wiki-pages/#{page.id}/recording"), 200) == @audio_bytes
    assert not File.exists?(dir) or File.ls!(dir) == []
  end

  test "a reader who can't see the board gets a 404", %{board: board} do
    page = meeting(board, "recording: gdrive:Rec/m.m4a")
    stranger = user_fixture("stranger@example.com")
    conn = build_conn() |> log_in_user(stranger) |> get(~p"/wiki-pages/#{page.id}/recording")

    assert json_response(conn, 404) == %{"reason" => "not_found"}
    refute_received {:drive, _, _, _}
  end

  test "signed out is sent to sign in", %{board: board} do
    page = meeting(board, "recording: gdrive:Rec/m.m4a")
    conn = get(build_conn(), ~p"/wiki-pages/#{page.id}/recording")
    assert redirected_to(conn) =~ "/login"
  end

  test "a page without a recording", %{conn: conn, board: board} do
    page = page_fixture(board, %{"title" => "Plain"})

    assert json_response(get(conn, ~p"/wiki-pages/#{page.id}/recording"), 404) == %{
             "reason" => "no_recording"
           }

    assert json_response(get(conn, ~p"/wiki-pages/999999999/recording"), 404) == %{
             "reason" => "not_found"
           }
  end

  test "a page on a board in no vault", %{conn: conn, user: user} do
    other = board_fixture(%{"name" => "Loose"}, owner: user)
    page = meeting(other, "recording: gdrive:Rec/m.m4a")

    assert json_response(get(conn, ~p"/wiki-pages/#{page.id}/recording"), 409) == %{
             "reason" => "no_folder"
           }
  end

  test "each refusal has its status", %{conn: conn, board: board, user: user, vault: vault} do
    outside = meeting(board, "recording: gdrive:x.m4a")

    assert json_response(get(conn, ~p"/wiki-pages/#{outside.id}/recording"), 403) == %{
             "reason" => "outside_folder"
           }

    by_id = meeting(board, "recording: gdrive:Rec/m.m4a\nrecording_drive_id: out")

    assert json_response(get(conn, ~p"/wiki-pages/#{by_id.id}/recording"), 403) == %{
             "reason" => "outside_folder"
           }

    pdf = meeting(board, "recording: gdrive:Rec/n.pdf")

    assert json_response(get(conn, ~p"/wiki-pages/#{pdf.id}/recording"), 403) == %{
             "reason" => "not_audio"
           }

    missing = meeting(board, "recording: gdrive:Rec/gone.m4a")

    assert json_response(get(conn, ~p"/wiki-pages/#{missing.id}/recording"), 404) == %{
             "reason" => "not_found"
           }

    page = meeting(board, "recording: gdrive:Rec/m.m4a")
    vault = vault |> Ecto.Changeset.change(recordings_folder: nil) |> Repo.update!()

    assert json_response(get(conn, ~p"/wiki-pages/#{page.id}/recording"), 409) == %{
             "reason" => "no_folder"
           }

    vault |> Ecto.Changeset.change(recordings_folder: "Rec") |> Repo.update!()

    Slipdock.Google.connection(user)
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert json_response(get(conn, ~p"/wiki-pages/#{page.id}/recording"), 409) == %{
             "reason" => "revoked"
           }

    Repo.delete!(Slipdock.Google.connection(user))

    assert json_response(get(conn, ~p"/wiki-pages/#{page.id}/recording"), 409) == %{
             "reason" => "not_connected"
           }
  end

  test "Drive failing is a 502", %{conn: conn, board: board} do
    page = meeting(board, "recording: gdrive:Rec/m.m4a\nrecording_drive_id: aud")
    stub(fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

    assert json_response(get(conn, ~p"/wiki-pages/#{page.id}/recording"), 502) == %{
             "reason" => "unavailable"
           }
  end

  test "a cached file gone from Drive is forgotten", %{conn: conn, board: board, vault: vault} do
    page = meeting(board, "recording: gdrive:Rec/m.m4a")
    assert response(get(conn, ~p"/wiki-pages/#{page.id}/recording"), 200)
    assert Repo.aggregate(Slipdock.Recordings.File, :count) == 1

    drive!([])

    assert json_response(get(conn, ~p"/wiki-pages/#{page.id}/recording"), 404) == %{
             "reason" => "not_found"
           }

    assert Repo.aggregate(Slipdock.Recordings.File, :count) == 0
    assert vault.id
  end
end
