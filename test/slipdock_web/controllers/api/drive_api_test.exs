defmodule SlipdockWeb.API.DriveTest do
  @moduledoc """
  Google Drive for meeting recordings over the API (W-1690): `GET /api/me/drive`
  and a vault's `recordings_folder` through `PATCH /api/vaults/:id`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.GoogleStub

  alias Slipdock.Vaults

  @folder %{
    "id" => "fold",
    "name" => "Manuel2 Recordings",
    "mimeType" => "application/vnd.google-apps.folder",
    "parents" => ["root"]
  }

  setup %{conn: conn, user: user} do
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
    %{conn: put_req_header(conn, "accept", "application/json"), vault: vault}
  end

  describe "GET /api/me/drive" do
    test "not connected, with each vault's folder", %{conn: conn, vault: vault} do
      assert json_response(get(conn, "/api/me/drive"), 200) == %{
               "drive" => %{"status" => "not_connected", "email" => nil},
               "vaults" => [
                 %{"id" => vault.id, "name" => "GMinds", "recordings_folder" => nil}
               ]
             }
    end

    test "connected, and who as", %{conn: conn, user: user, vault: vault} do
      connect!(user, email: "me@example.com")
      vault |> Ecto.Changeset.change(recordings_folder: "Rec") |> Slipdock.Repo.update!()

      body = json_response(get(conn, "/api/me/drive"), 200)
      assert body["drive"] == %{"status" => "connected", "email" => "me@example.com"}
      assert [%{"name" => "GMinds", "recordings_folder" => "Rec"}] = body["vaults"]
    end

    test "revoked, and a server without Google", %{conn: conn, user: user} do
      connect!(user, revoked: true)
      assert json_response(get(conn, "/api/me/drive"), 200)["drive"]["status"] == "revoked"

      Slipdock.TestConfig.put(:google, [])
      assert json_response(get(conn, "/api/me/drive"), 200)["drive"]["status"] == "not_configured"
    end
  end

  describe "PATCH /api/vaults/:id recordings_folder" do
    test "sets a folder that is there, and clears it", %{conn: conn, user: user} do
      connect!(user)
      drive!([@folder])

      vault =
        conn
        |> patch("/api/vaults/GMinds", %{"recordings_folder" => "/Manuel2 Recordings/"})
        |> json_response(200)
        |> Map.fetch!("vault")

      assert vault["recordings_folder"] == "Manuel2 Recordings"
      assert vault["name"] == "GMinds"

      cleared =
        conn
        |> patch("/api/vaults/GMinds", %{"recordings_folder" => ""})
        |> json_response(200)

      assert cleared["vault"]["recordings_folder"] == nil
    end

    test "refuses one that isn't there", %{conn: conn, user: user} do
      connect!(user)
      drive!([@folder])

      assert json_response(
               patch(conn, "/api/vaults/GMinds", %{"recordings_folder" => "Nope"}),
               422
             ) ==
               %{"error" => ~s(there is no folder "Nope" in your My Drive)}
    end

    test "needs a connection", %{conn: conn} do
      assert json_response(
               patch(conn, "/api/vaults/GMinds", %{"recordings_folder" => "Rec"}),
               409
             )[
               "error"
             ] =~ "connect Google Drive first"
    end

    test "renaming alone leaves the folder be", %{conn: conn, vault: vault} do
      vault |> Ecto.Changeset.change(recordings_folder: "Rec") |> Slipdock.Repo.update!()

      assert json_response(patch(conn, "/api/vaults/GMinds", %{"name" => "Minds"}), 200)["vault"][
               "recordings_folder"
             ] == "Rec"
    end
  end
end
