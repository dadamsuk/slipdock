defmodule SlipdockWeb.SettingsFlashTest do
  @moduledoc """
  Each flash the account's Settings tab raises reaches the page that draws it
  (#2895): the tab sends it up through `SlipdockWeb.ComponentFlash`, and the
  page shows it as `#flash-info` or `#flash-error`.

  Quick add, quick note's refusal, header links and a refused endpoint are
  asserted beside their features; these are the rest.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.AI.Keys

  setup %{conn: conn} do
    file =
      Path.join(System.tmp_dir!(), "settings_flash_#{System.unique_integer([:positive])}.json")

    Slipdock.TestConfig.merge(:ai, key_file: file, api_key: nil)
    on_exit(fn -> File.rm(file) end)

    user = user_fixture("settings-flash@example.com")
    %{conn: log_in_user(conn, user), user: user, key_file: file}
  end

  # The server's AI settings file can't be read, so nothing is saved over it.
  defp break_key_file(file), do: File.write!(file, "{\"users\": [")

  describe "names in trees and lists" do
    test "a save says so", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account/settings")

      view |> form("#tree-names-form", display: %{tree_names: "short"}) |> render_submit()

      assert has_element?(view, "#flash-info", "Display saved.")
      refute has_element?(view, "#flash-error")
    end

    test "a choice it doesn't offer is refused", %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, ~p"/account/settings")

      view
      |> element("#tree-names-form")
      |> render_submit(%{"display" => %{"tree_names" => "bogus"}})

      assert has_element?(view, "#flash-error", "Couldn't save that.")
      refute has_element?(view, "#flash-info")
      assert Slipdock.Accounts.get_user!(user.id).tree_names == user.tree_names
    end
  end

  describe "when something waits on you" do
    test "a save says so", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account/settings")

      view
      |> form("#waiting-notice-form", notice: %{waiting_alerts: "false", waiting_emails: "true"})
      |> render_submit()

      assert has_element?(view, "#flash-info", "Saved.")
      refute has_element?(view, "#flash-error")
    end
  end

  describe "quick note" do
    test "a save says so", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account/settings")

      view |> form("#quick-note-form", %{"location" => ""}) |> render_submit()

      assert has_element?(view, "#flash-info", "Quick note settings saved.")
      refute has_element?(view, "#flash-error")
    end
  end

  describe "AI model" do
    test "saving the endpoint says so", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account/settings")

      view
      |> form("form[phx-submit=save_ai_provider]", %{"base_url" => "http://box.local:1234/v1"})
      |> render_submit()

      assert has_element?(view, "#flash-info", "AI settings saved.")
      refute has_element?(view, "#flash-error")
    end

    test "picking a model says so, and a settings file that can't be read says that",
         %{conn: conn, user: user, key_file: file} do
      Slipdock.AIStub.stub_models(["local/big", "local/small"])
      :ok = Keys.put_settings(user, %{base_url: "http://box.local:1234/v1"})

      {:ok, view, _} = live(conn, ~p"/account/settings")
      view |> element("button[phx-click=list_ai_models]") |> render_click()
      render_async(view)

      view
      |> form("form[phx-submit=save_ai_model]", %{"model" => "local/small"})
      |> render_submit()

      assert has_element?(view, "#flash-info", "Model saved.")
      refute has_element?(view, "#flash-error")

      break_key_file(file)

      view
      |> form("form[phx-submit=save_ai_model]", %{"model" => "local/big"})
      |> render_submit()

      assert has_element?(view, "#flash-error", "AI settings file is unreadable")
    end

    test "removing the key says so", %{conn: conn, user: user} do
      :ok = Keys.put(user, "sk-or-v1-0123456789abcdef")
      {:ok, view, _} = live(conn, ~p"/account/settings")

      view |> element("button[phx-click=remove_ai_key]") |> render_click()

      assert has_element?(view, "#flash-info", "AI key removed.")
      refute has_element?(view, "#flash-error")
      refute Keys.configured?(user)
    end

    test "a key that can't be removed says why", %{conn: conn, user: user, key_file: file} do
      :ok = Keys.put(user, "sk-or-v1-0123456789abcdef")
      {:ok, view, _} = live(conn, ~p"/account/settings")
      break_key_file(file)

      view |> element("button[phx-click=remove_ai_key]") |> render_click()

      assert has_element?(view, "#flash-error", "AI settings file is unreadable")
      refute has_element?(view, "#flash-info")
    end
  end
end
