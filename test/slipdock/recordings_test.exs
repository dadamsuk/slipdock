defmodule Slipdock.RecordingsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GoogleStub

  alias Slipdock.{Recordings, Vaults}

  @folder %{
    "id" => "fold",
    "name" => "Meeting Recordings",
    "mimeType" => "application/vnd.google-apps.folder",
    "parents" => ["root"]
  }
  @month %{
    "id" => "month",
    "name" => "2026-09",
    "mimeType" => "application/vnd.google-apps.folder",
    "parents" => ["fold"]
  }
  @audio %{
    "id" => "aud",
    "name" => "meeting.m4a",
    "mimeType" => "audio/mp4",
    "size" => "1234",
    "parents" => ["month"]
  }
  @video_m4a %{
    "id" => "vm4a",
    "name" => "tagged.m4a",
    "mimeType" => "video/mp4",
    "size" => "9",
    "parents" => ["month"]
  }
  @video %{"id" => "vid", "name" => "film.mp4", "mimeType" => "video/mp4", "parents" => ["month"]}
  @pdf %{
    "id" => "pdf",
    "name" => "notes.pdf",
    "mimeType" => "application/pdf",
    "parents" => ["month"]
  }
  @elsewhere_dir %{
    "id" => "priv",
    "name" => "Private",
    "mimeType" => "application/vnd.google-apps.folder",
    "parents" => ["root"]
  }
  @elsewhere %{
    "id" => "secret",
    "name" => "secret.m4a",
    "mimeType" => "audio/mp4",
    "parents" => ["priv"]
  }
  @drive [@folder, @month, @audio, @video_m4a, @video, @pdf, @elsewhere_dir, @elsewhere]

  @recording "gdrive:Meeting Recordings/2026-09/meeting.m4a"

  setup do
    user = user_fixture()
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})

    vault =
      Ecto.Changeset.change(vault, recordings_folder: "Meeting Recordings") |> Repo.update!()

    %{user: user, vault: vault}
  end

  defp drive_calls do
    receive do
      {:drive, _, _, _} -> 1 + drive_calls()
    after
      0 -> 0
    end
  end

  describe "parse/1" do
    test "a gdrive: path as segments" do
      assert Recordings.parse(" gdrive:/a//b/c.m4a ") == {:ok, ["a", "b", "c.m4a"]}
    end

    test "refuses anything else" do
      assert Recordings.parse("custom://play?x") == {:error, :invalid}
      assert Recordings.parse("gdrive:") == {:error, :invalid}
      assert Recordings.parse("gdrive:a/../b") == {:error, :invalid}
      assert Recordings.parse("gdrive:a/./b") == {:error, :invalid}
      assert Recordings.parse(nil) == {:error, :invalid}
    end
  end

  describe "resolve/3" do
    setup %{user: user} do
      connect!(user)
      drive!(@drive)
      :ok
    end

    test "walks a path to its file", %{vault: vault} do
      assert Recordings.resolve(vault, @recording) ==
               {:ok, %{id: "aud", name: "meeting.m4a", mime_type: "audio/mp4", size: 1234}}
    end

    test "a second time is answered from the cache, without asking Drive", %{vault: vault} do
      assert {:ok, %{id: "aud"}} = Recordings.resolve(vault, @recording)
      assert drive_calls() > 0

      assert {:ok, %{id: "aud", mime_type: "audio/mp4", size: 1234}} =
               Recordings.resolve(vault, @recording)

      assert drive_calls() == 0
    end

    test "an id is checked against the folder through its parents", %{vault: vault} do
      assert {:ok, %{id: "aud"}} = Recordings.resolve(vault, @recording, "aud")
    end

    test "an id outside the folder is refused, whatever the path says", %{vault: vault} do
      assert Recordings.resolve(vault, @recording, "secret") == {:error, :outside_folder}
    end

    test "a path outside the folder is refused without asking Drive", %{vault: vault} do
      assert Recordings.resolve(vault, "gdrive:Private/secret.m4a") == {:error, :outside_folder}
      assert Recordings.resolve(vault, "gdrive:Meeting Recordings") == {:error, :outside_folder}

      assert Recordings.resolve(vault, "gdrive:Meeting Recordings2/x.m4a") ==
               {:error, :outside_folder}

      assert drive_calls() == 0
    end

    test "a .. in the path is refused", %{vault: vault} do
      assert Recordings.resolve(vault, "gdrive:Meeting Recordings/../Private/secret.m4a") ==
               {:error, :invalid}
    end

    test "a missing segment is not found", %{vault: vault} do
      assert Recordings.resolve(vault, "gdrive:Meeting Recordings/2026-10/meeting.m4a") ==
               {:error, :not_found}

      assert Recordings.resolve(vault, "gdrive:Meeting Recordings/2026-09/gone.m4a") ==
               {:error, :not_found}

      assert Recordings.resolve(vault, @recording, "nope") == {:error, :not_found}
    end

    test "a file that is not audio is refused", %{vault: vault} do
      assert Recordings.resolve(vault, "gdrive:Meeting Recordings/2026-09/notes.pdf") ==
               {:error, :not_audio}

      assert Recordings.resolve(vault, "gdrive:Meeting Recordings/2026-09/film.mp4") ==
               {:error, :not_audio}
    end

    test "an .m4a Drive calls video/mp4 is audio", %{vault: vault} do
      assert {:ok, %{id: "vm4a"}} =
               Recordings.resolve(vault, "gdrive:Meeting Recordings/2026-09/tagged.m4a")
    end

    test "forget/2 drops the cached path", %{vault: vault} do
      {:ok, _} = Recordings.resolve(vault, @recording)
      drive_calls()
      Recordings.forget(vault, @recording)
      {:ok, _} = Recordings.resolve(vault, @recording)
      assert drive_calls() > 0
    end
  end

  describe "resolve/3 without a connection" do
    test "not connected", %{vault: vault} do
      assert Recordings.resolve(vault, @recording) == {:error, :not_connected}
    end

    test "revoked", %{vault: vault, user: user} do
      connect!(user, revoked: true)
      assert Recordings.resolve(vault, @recording) == {:error, :revoked}
    end

    test "no folder set", %{vault: vault, user: user} do
      connect!(user)
      vault = Ecto.Changeset.change(vault, recordings_folder: nil) |> Repo.update!()
      assert Recordings.resolve(vault, @recording) == {:error, :no_folder}
    end
  end

  describe "Vaults.set_recordings_folder/2" do
    test "needs a connection", %{vault: vault} do
      assert Vaults.set_recordings_folder(vault, "Meeting Recordings") == {:error, :not_connected}
    end

    test "checks the folder is there, and keeps it normalised", %{vault: vault, user: user} do
      connect!(user)
      drive!(@drive)

      assert {:ok, %{recordings_folder: "Meeting Recordings/2026-09"}} =
               Vaults.set_recordings_folder(vault, "/Meeting Recordings/2026-09/")

      assert Vaults.set_recordings_folder(vault, "Nope") == {:error, :not_found}
      # A file is not a folder.
      assert Vaults.set_recordings_folder(vault, "Meeting Recordings/2026-09/meeting.m4a") ==
               {:error, :not_found}
    end

    test "blank clears it, and changing it forgets what was found", %{vault: vault, user: user} do
      connect!(user)
      drive!(@drive)
      {:ok, _} = Recordings.resolve(vault, @recording)
      drive_calls()

      assert {:ok, %{recordings_folder: nil}} = Vaults.set_recordings_folder(vault, " ")
      assert Repo.aggregate(Slipdock.Recordings.File, :count) == 0
    end
  end

  # #784: a vault without a folder and a board in no vault are told apart.
  describe "for_page/1" do
    setup %{user: user, vault: vault} do
      board = board_fixture(%{"name" => "Notes"}, owner: user)
      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
      %{board: board}
    end

    defp page(board, front_matter) do
      %{front_matter: "---\n" <> front_matter <> "\n---\n\n", board_id: board.id}
    end

    test "a vault with a folder plays", %{board: board} do
      assert Recordings.for_page(page(board, "recording: #{@recording}")) == :ok
    end

    test "a vault without a folder is :no_folder", %{board: board, vault: vault} do
      Ecto.Changeset.change(vault, recordings_folder: nil) |> Repo.update!()
      assert Recordings.for_page(page(board, "recording: #{@recording}")) == {:error, :no_folder}
    end

    test "a board in no vault is :no_vault", %{user: user} do
      loose = board_fixture(%{"name" => "Loose"}, owner: user)
      assert Recordings.for_page(page(loose, "recording: #{@recording}")) == {:error, :no_vault}
    end

    test "a server without Google is :not_configured either way", %{board: board, user: user} do
      Slipdock.TestConfig.put(:google, [])
      loose = board_fixture(%{"name" => "Loose"}, owner: user)

      assert Recordings.for_page(page(board, "recording: #{@recording}")) ==
               {:error, :not_configured}

      assert Recordings.for_page(page(loose, "recording: #{@recording}")) ==
               {:error, :not_configured}
    end

    test "no gdrive: recording is not a player", %{board: board} do
      assert Recordings.for_page(page(board, "recording: custom://play?file=x.m4a")) == nil
      assert Recordings.for_page(%{front_matter: nil, board_id: board.id}) == nil
    end
  end
end
