defmodule SlipdockWeb.VaultRecordingsLiveTest do
  @moduledoc "A vault's recordings folder on Google Drive, set on the vaults screen (W-1690)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.GoogleStub

  alias Slipdock.Vaults

  @folder %{
    "id" => "fold",
    "name" => "Manuel2 Recordings",
    "mimeType" => "application/vnd.google-apps.folder",
    "parents" => ["root"]
  }

  setup %{user: user} do
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
    %{vault: vault}
  end

  test "without a connection the field is off and says what to do", %{conn: conn, vault: vault} do
    {:ok, view, _html} = live(conn, ~p"/vaults")
    assert has_element?(view, "#recordings-folder-input-#{vault.id}[disabled]")
    assert has_element?(view, "#recordings-folder-#{vault.id} a[href='/account/settings']")
  end

  test "saves a folder that is there", %{conn: conn, user: user, vault: vault} do
    connect!(user)
    drive!([@folder])
    {:ok, view, _html} = live(conn, ~p"/vaults")

    html =
      view
      |> form("#recordings-folder-#{vault.id}", %{"folder" => "Manuel2 Recordings"})
      |> render_submit()

    assert html =~ "plays its recordings from Manuel2 Recordings"

    assert Vaults.get_vault(user, vault.id) |> elem(1) |> Map.get(:recordings_folder) ==
             "Manuel2 Recordings"
  end

  test "refuses a folder that isn't there", %{conn: conn, user: user, vault: vault} do
    connect!(user)
    drive!([@folder])
    {:ok, view, _html} = live(conn, ~p"/vaults")

    html =
      view
      |> form("#recordings-folder-#{vault.id}", %{"folder" => "Elsewhere"})
      |> render_submit()

    assert html =~ "no folder &quot;Elsewhere&quot; in your My Drive"
    assert Vaults.get_vault(user, vault.id) |> elem(1) |> Map.get(:recordings_folder) == nil
  end

  test "is not there on a server without Google", %{conn: conn, vault: vault} do
    Slipdock.TestConfig.put(:google, [])
    {:ok, view, _html} = live(conn, ~p"/vaults")
    refute has_element?(view, "#recordings-folder-#{vault.id}")
  end

  # #783: one outcome on screen at a time.
  describe "the message after a save" do
    setup %{user: user} do
      connect!(user)
      drive!([@folder])
      :ok
    end

    defp save(view, vault, folder) do
      view |> form("#recordings-folder-#{vault.id}", %{"folder" => folder}) |> render_submit()
    end

    test "a good folder after a missing one clears the error", %{conn: conn, vault: vault} do
      {:ok, view, _html} = live(conn, ~p"/vaults")
      assert save(view, vault, "Elsewhere") =~ "no folder &quot;Elsewhere&quot;"

      html = save(view, vault, "Manuel2 Recordings")
      assert html =~ "plays its recordings from Manuel2 Recordings"
      refute html =~ "no folder &quot;Elsewhere&quot;"
    end

    test "a missing folder after a good one clears the success", %{conn: conn, vault: vault} do
      {:ok, view, _html} = live(conn, ~p"/vaults")
      assert save(view, vault, "Manuel2 Recordings") =~ "plays its recordings from"

      html = save(view, vault, "Elsewhere")
      assert html =~ "no folder &quot;Elsewhere&quot;"
      refute html =~ "plays its recordings from"
    end

    test "clearing the folder after a failure clears the error",
         %{conn: conn, user: user, vault: vault} do
      {:ok, view, _html} = live(conn, ~p"/vaults")
      assert save(view, vault, "Elsewhere") =~ "no folder"

      html = save(view, vault, "")
      assert html =~ "GMinds has no recordings folder now."
      refute html =~ "no folder &quot;Elsewhere&quot;"
      assert Vaults.get_vault(user, vault.id) |> elem(1) |> Map.get(:recordings_folder) == nil
    end

    test "other vault events clear a stale error too", %{conn: conn, vault: vault} do
      {:ok, view, _html} = live(conn, ~p"/vaults")
      assert save(view, vault, "Elsewhere") =~ "no folder"

      html = render_click(view, "delete", %{"id" => vault.id})
      assert html =~ "Deleted GMinds."
      refute html =~ "no folder &quot;Elsewhere&quot;"
    end
  end
end
