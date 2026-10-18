defmodule SlipdockWeb.StaleAssetsLiveTest do
  # Not async: the endpoint's static manifest is global, and these tests
  # stand one up the way a production release has it.
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias SlipdockWeb.{Endpoint, StaleAssetsHook}

  @latest %{
    "assets/js/app.js" => "assets/js/app-new.js",
    "assets/css/app.css" => "assets/css/app-new.css"
  }

  setup %{conn: conn} do
    before = Endpoint.config(:cache_static_manifest_latest)
    on_exit(fn -> Phoenix.Config.put(Endpoint, :cache_static_manifest_latest, before) end)
    %{conn: log_in_user(conn, user_fixture())}
  end

  # What the layout's `phx-track-static` tags make the browser report.
  defp running(conn, digest) do
    put_connect_params(conn, %{
      "_track_static" => [
        "http://localhost:4000/assets/css/app-#{digest}.css?vsn=d",
        "http://localhost:4000/assets/js/app-#{digest}.js?vsn=d"
      ]
    })
  end

  defp deployed(manifest),
    do: Phoenix.Config.put(Endpoint, :cache_static_manifest_latest, manifest)

  test "a tab running the assets from before a deploy is told to reload", %{conn: conn} do
    deployed(@latest)
    {:ok, view, _html} = live(running(conn, "old"), ~p"/work")

    assert has_element?(view, "#stale-assets", StaleAssetsHook.message())
    # A plain link to the same address: a full page load, not a LiveView patch.
    assert has_element?(view, ~s|#stale-assets a#stale-assets-reload[href=""]|, "Reload")
    refute has_element?(view, "#stale-assets-reload[data-phx-link]")
  end

  test "it is told so on whichever page it reconnects to", %{conn: conn} do
    deployed(@latest)
    {:ok, view, _html} = live(running(conn, "old"), ~p"/account")
    assert has_element?(view, "#stale-assets")
  end

  test "a tab that is up to date sees no bar", %{conn: conn} do
    deployed(@latest)
    {:ok, view, _html} = live(running(conn, "new"), ~p"/work")
    refute has_element?(view, "#stale-assets")
  end

  test "only one stale asset is enough", %{conn: conn} do
    deployed(@latest)

    conn =
      put_connect_params(conn, %{
        "_track_static" => [
          "http://localhost:4000/assets/css/app-new.css?vsn=d",
          "http://localhost:4000/assets/js/app-old.js?vsn=d"
        ]
      })

    {:ok, view, _html} = live(conn, ~p"/work")
    assert has_element?(view, "#stale-assets")
  end

  test "without a static manifest (dev, test) nothing is stale", %{conn: conn} do
    deployed(nil)
    {:ok, view, _html} = live(running(conn, "old"), ~p"/work")
    refute has_element?(view, "#stale-assets")
  end

  test "the dead render never shows it", %{conn: conn} do
    deployed(@latest)
    html = conn |> running("old") |> get(~p"/work") |> html_response(200)
    refute html =~ "stale-assets"
  end

  test "it can be dismissed", %{conn: conn} do
    deployed(@latest)
    {:ok, view, _html} = live(running(conn, "old"), ~p"/work")

    view |> element("#stale-assets button[aria-label=close]") |> render_click()
    refute has_element?(view, "#stale-assets")
  end
end
