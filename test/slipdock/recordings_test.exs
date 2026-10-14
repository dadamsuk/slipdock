defmodule Slipdock.RecordingsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GoogleStub

  alias Slipdock.{Recordings, Vaults}

  @folder %{
    "id" => "fold",
    "name" => "Manuel2 Recordings",
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

  @recording "gdrive:Manuel2 Recordings/2026-09/meeting.m4a"

  setup do
    user = user_fixture()
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})

    vault =
      Ecto.Changeset.change(vault, recordings_folder: "Manuel2 Recordings") |> Repo.update!()

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
      assert Recordings.parse("manuel2://play?x") == {:error, :invalid}
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
      assert Recordings.resolve(vault, "gdrive:Manuel2 Recordings") == {:error, :outside_folder}

      assert Recordings.resolve(vault, "gdrive:Manuel2 Recordings2/x.m4a") ==
               {:error, :outside_folder}

      assert drive_calls() == 0
    end

    test "a .. in the path is refused", %{vault: vault} do
      assert Recordings.resolve(vault, "gdrive:Manuel2 Recordings/../Private/secret.m4a") ==
               {:error, :invalid}
    end

    test "a missing segment is not found", %{vault: vault} do
      assert Recordings.resolve(vault, "gdrive:Manuel2 Recordings/2026-10/meeting.m4a") ==
               {:error, :not_found}

      assert Recordings.resolve(vault, "gdrive:Manuel2 Recordings/2026-09/gone.m4a") ==
               {:error, :not_found}

      assert Recordings.resolve(vault, @recording, "nope") == {:error, :not_found}
    end

    test "a file that is not audio is refused", %{vault: vault} do
      assert Recordings.resolve(vault, "gdrive:Manuel2 Recordings/2026-09/notes.pdf") ==
               {:error, :not_audio}

      assert Recordings.resolve(vault, "gdrive:Manuel2 Recordings/2026-09/film.mp4") ==
               {:error, :not_audio}
    end

    test "an .m4a Drive calls video/mp4 is audio", %{vault: vault} do
      assert {:ok, %{id: "vm4a"}} =
               Recordings.resolve(vault, "gdrive:Manuel2 Recordings/2026-09/tagged.m4a")
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
      assert Vaults.set_recordings_folder(vault, "Manuel2 Recordings") == {:error, :not_connected}
    end

    test "checks the folder is there, and keeps it normalised", %{vault: vault, user: user} do
      connect!(user)
      drive!(@drive)

      assert {:ok, %{recordings_folder: "Manuel2 Recordings/2026-09"}} =
               Vaults.set_recordings_folder(vault, "/Manuel2 Recordings/2026-09/")

      assert Vaults.set_recordings_folder(vault, "Nope") == {:error, :not_found}
      # A file is not a folder.
      assert Vaults.set_recordings_folder(vault, "Manuel2 Recordings/2026-09/meeting.m4a") ==
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
end
