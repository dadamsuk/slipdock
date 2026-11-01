defmodule SlipdockWeb.API.RecordingControllerTest do
  @moduledoc "A meeting page's recording, played with an API token (#1562)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GoogleStub

  alias Slipdock.{Access, Accounts, Repo, Vaults, Wiki}

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
    board = board_fixture(%{"name" => "Recording API"}, owner: user)
    {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Recording API"})
    vault = vault |> Ecto.Changeset.change(recordings_folder: "Rec") |> Repo.update!()
    connect!(user)
    drive!(@drive)
    {token, _} = Accounts.create_api_token(user, "desktop")
    %{board: board, vault: vault, token: token}
  end

  defp meeting(board, front_matter, attrs \\ %{}) do
    page_fixture(
      board,
      Map.merge(
        %{
          "title" => "Meeting #{System.unique_integer([:positive])}",
          "front_matter" => "---\n" <> front_matter <> "\n---\n\n",
          "body" => "Summary"
        },
        attrs
      )
    )
  end

  # No session: only the token gets this through.
  defp play(ref, token, headers \\ []) do
    conn = put_req_header(build_conn(), "authorization", "Bearer " <> token)

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> get("/api/pages/#{ref}/recording")
  end

  defp token_for(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "limited", opts)
    token
  end

  describe "the stream" do
    test "the whole recording", %{board: board, token: token} do
      conn = play(meeting(board, "recording: gdrive:Rec/m.m4a").id, token)

      assert response(conn, 200) == @audio_bytes
      assert get_resp_header(conn, "content-type") == ["audio/mp4"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "a range comes back as a 206", %{board: board, token: token} do
      page = meeting(board, "recording: gdrive:Rec/m.m4a\nrecording_drive_id: aud")
      conn = play(page.id, token, [{"range", "bytes=10-19"}])

      assert response(conn, 206) == "0123456789"
      assert get_resp_header(conn, "content-range") == ["bytes 10-19/1000"]
      assert_received {:drive, "GET", "/drive/v3/files/aud", %{"alt" => "media"}}
    end

    test "writes nothing to the uploads directory", %{board: board, token: token} do
      dir = Slipdock.TestConfig.own_uploads_dir()
      page = meeting(board, "recording: gdrive:Rec/m.m4a")

      assert response(play(page.id, token), 200) == @audio_bytes
      assert not File.exists?(dir) or File.ls!(dir) == []
    end

    test "an Accept that takes anything passes, a strict one is a 406", %{
      board: board,
      token: token
    } do
      page = meeting(board, "recording: gdrive:Rec/m.m4a")

      assert response(play(page.id, token, [{"accept", "*/*"}]), 200) == @audio_bytes

      assert_error_sent 406, fn -> play(page.id, token, [{"accept", "audio/mp4"}]) end
    end
  end

  describe "finding the page" do
    test "by id, by code and by board/slug", %{board: board, token: token} do
      page = meeting(board, "recording: gdrive:Rec/m.m4a")

      for ref <- [page.id, page.code, URI.encode_www_form("#{board.code}/#{page.slug}")] do
        assert response(play(ref, token), 200) == @audio_bytes
      end
    end

    test "nothing by that name, or archived, is a 404", %{board: board, token: token} do
      assert json_response(play("W-99999999", token), 404) == %{"reason" => "not_found"}
      assert json_response(play("999999999", token), 404) == %{"reason" => "not_found"}
      assert json_response(play("a-slug", token), 404) == %{"reason" => "not_found"}

      page = meeting(board, "recording: gdrive:Rec/m.m4a")
      {:ok, _} = Wiki.archive_page(page)

      assert json_response(play(page.id, token), 404) == %{"reason" => "not_found"}
      refute_received {:drive, _, _, _}
    end
  end

  describe "who may hear it" do
    test "a read-only token may", %{board: board, user: user} do
      page = meeting(board, "recording: gdrive:Rec/m.m4a")
      assert response(play(page.id, token_for(user, scope: "read")), 200) == @audio_bytes
    end

    test "a token limited to this board may", %{board: board, user: user} do
      page = meeting(board, "recording: gdrive:Rec/m.m4a")
      token = token_for(user, scope_boards: [board.id])
      assert response(play(page.id, token), 200) == @audio_bytes
    end

    test "a token limited to another board is refused, and told why", %{
      board: board,
      user: user
    } do
      other = board_fixture(%{"name" => "Recording API other"}, owner: user)
      page = meeting(board, "recording: gdrive:Rec/m.m4a")

      assert %{"error" => error} =
               json_response(play(page.id, token_for(user, scope_boards: [other.id])), 403)

      assert error =~ "scope"
      refute_received {:drive, _, _, _}
    end

    test "no token, a bad one, a revoked one and an expired one are 401s", %{
      board: board,
      user: user
    } do
      page = meeting(board, "recording: gdrive:Rec/m.m4a")

      assert json_response(get(build_conn(), "/api/pages/#{page.id}/recording"), 401)
      assert json_response(play(page.id, "not-a-token"), 401)

      {token, %{id: id}} = Accounts.create_api_token(user, "gone")
      assert response(play(page.id, token), 200)
      Accounts.delete_api_token(user, id)
      assert json_response(play(page.id, token), 401)

      past = DateTime.utc_now(:second) |> DateTime.add(-60, :second)
      assert json_response(play(page.id, token_for(user, expires_at: past)), 401)
    end

    test "a reader who can't see the board gets a 404, and Drive isn't asked", %{board: board} do
      page = meeting(board, "recording: gdrive:Rec/m.m4a")
      stranger = user_fixture("recording.stranger@example.com")

      for ref <- [page.id, page.code] do
        assert json_response(play(ref, token_for(stranger)), 404) == %{"reason" => "not_found"}
      end

      refute_received {:drive, _, _, _}
    end

    test "a page shared alone stays silent, as in the browser", %{board: board, user: user} do
      page = meeting(board, "recording: gdrive:Rec/m.m4a")
      sharee = user_fixture("recording.sharee@example.com")
      {:ok, _} = Access.grant(page, sharee, "read", user)
      token = token_for(sharee)

      assert %{"page" => _} =
               build_conn()
               |> put_req_header("authorization", "Bearer " <> token)
               |> get("/api/pages/#{page.id}")
               |> json_response(200)

      assert json_response(play(page.id, token), 404) == %{"reason" => "not_found"}
      refute_received {:drive, _, _, _}
    end

    test "a draft is a writer's, as on the other page routes", %{board: board, token: token} do
      page = meeting(board, "recording: gdrive:Rec/m.m4a", %{"status" => "draft"})
      reader = user_fixture("recording.reader@example.com")
      share_fixture(board, reader, "read")

      assert json_response(play(page.id, token_for(reader)), 404) == %{"reason" => "not_found"}
      assert response(play(page.id, token), 200) == @audio_bytes
    end

    test "a read-only member of the board may", %{board: board} do
      page = meeting(board, "recording: gdrive:Rec/m.m4a")
      reader = user_fixture("recording.member@example.com")
      share_fixture(board, reader, "read")

      assert response(play(page.id, token_for(reader)), 200) == @audio_bytes
    end
  end

  describe "the refusals" do
    test "no_recording and not_found", %{board: board, token: token} do
      plain = page_fixture(board, %{"title" => "Plain"})
      assert json_response(play(plain.id, token), 404) == %{"reason" => "no_recording"}

      gone = meeting(board, "recording: gdrive:Rec/gone.m4a")
      assert json_response(play(gone.id, token), 404) == %{"reason" => "not_found"}
    end

    test "no_vault: a board nobody owns", %{user: user, token: token} do
      owner = user_fixture("rec-gone@example.com")
      loose = board_fixture(%{"name" => "Recording API loose"}, owner: owner)
      share_fixture(loose, user, "read")
      page = meeting(loose, "recording: gdrive:Rec/m.m4a")
      loose |> Ecto.Changeset.change(owner_id: nil) |> Repo.update!()

      assert json_response(play(page.id, token), 409) == %{"reason" => "no_vault"}
    end

    test "outside_folder and not_audio", %{board: board, token: token} do
      for front_matter <- [
            "recording: gdrive:x.m4a",
            "recording: gdrive:Rec/m.m4a\nrecording_drive_id: out"
          ] do
        page = meeting(board, front_matter)
        assert json_response(play(page.id, token), 403) == %{"reason" => "outside_folder"}
      end

      pdf = meeting(board, "recording: gdrive:Rec/n.pdf")
      assert json_response(play(pdf.id, token), 403) == %{"reason" => "not_audio"}
    end

    test "no_folder", %{board: board, vault: vault, token: token} do
      page = meeting(board, "recording: gdrive:Rec/m.m4a")
      vault |> Ecto.Changeset.change(recordings_folder: nil) |> Repo.update!()

      assert json_response(play(page.id, token), 409) == %{"reason" => "no_folder"}
    end

    test "revoked, then not_connected", %{board: board, user: user, token: token} do
      page = meeting(board, "recording: gdrive:Rec/m.m4a")

      Slipdock.Google.connection(user)
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      assert json_response(play(page.id, token), 409) == %{"reason" => "revoked"}

      Repo.delete!(Slipdock.Google.connection(user))

      assert json_response(play(page.id, token), 409) == %{"reason" => "not_connected"}
    end

    test "unavailable, when Drive fails", %{board: board, token: token} do
      page = meeting(board, "recording: gdrive:Rec/m.m4a\nrecording_drive_id: aud")
      stub(fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert json_response(play(page.id, token), 502) == %{"reason" => "unavailable"}
    end
  end
end
