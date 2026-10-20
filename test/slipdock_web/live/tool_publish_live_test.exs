defmodule SlipdockWeb.ToolPublishLiveTest do
  @moduledoc """
  Publishing a Tool from the browser: a package uploaded on the Tools page
  makes a new Tool or the next version of one of yours; on your Tool's own
  page it is the next version of that Tool and nothing else.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Repo, Tools}

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    :ok
  end

  defp upload(view, form, bytes, filename \\ "tool.tgz") do
    input = file_input(view, form, :package, [%{name: filename, content: bytes}])
    render_upload(input, filename)
    input
  end

  defp latest(name),
    do: Tools.latest_version(Repo.get_by!(Tools.Tool, slug: name)).version

  describe "on the Tools page" do
    test "a new Tool is published as yours and its page opens", %{conn: conn, user: user} do
      name = unique_name()
      {:ok, view, _html} = live(conn, ~p"/tools")
      assert has_element?(view, "#tools-publish", "Publish a Tool")

      upload(view, "#tools-publish-form", package(name))
      view |> form("#tools-publish-form") |> render_submit()

      {path, flash} = assert_redirect(view)
      assert path == "/tools/#{name}?version=1.0.0"
      assert flash["info"] == "Published #{name} 1.0.0."

      assert {:ok, tool} = Tools.fetch(user, name)
      assert tool.owner_id == user.id
    end

    test "a higher version of one of yours is its next version", %{conn: conn, user: user} do
      name = unique_name()
      {:ok, _} = Tools.publish(user, package(name, "1.0.0"))
      {:ok, view, _html} = live(conn, ~p"/tools")

      upload(view, "#tools-publish-form", package(name, "1.1.0"))
      view |> form("#tools-publish-form") |> render_submit()

      assert {path, _flash} = assert_redirect(view)
      assert path == "/tools/#{name}?version=1.1.0"
      assert latest(name) == "1.1.0"
    end

    test "a refused package says why on the page and publishes nothing", %{
      conn: conn,
      user: user
    } do
      name = unique_name()
      {:ok, _} = Tools.publish(user, package(name, "1.0.0"))
      taken = unique_name()
      {:ok, _} = Tools.publish(user_fixture("publish-owner@example.com"), package(taken))

      for {bytes, says} <- [
            {"not a tarball", "that is not a readable .tar.gz"},
            {package(name, "1.0.0"), "already published"},
            {package(taken, "2.0.0"), "belongs to someone else's Tool"},
            {package(unique_name(), "1.0.0", %{"tool.json" => nil}), "tool.json"}
          ] do
        {:ok, view, _html} = live(conn, ~p"/tools")
        upload(view, "#tools-publish-form", bytes)
        view |> form("#tools-publish-form") |> render_submit()

        assert has_element?(view, "#tools-publish-form-error", says), says
      end

      assert latest(name) == "1.0.0"
      assert latest(taken) == "1.0.0"
    end

    test "the error clears when another file is chosen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tools")
      upload(view, "#tools-publish-form", "junk")
      view |> form("#tools-publish-form") |> render_submit()
      assert has_element?(view, "#tools-publish-form-error")

      upload(view, "#tools-publish-form", package(unique_name()))
      view |> form("#tools-publish-form") |> render_change()
      refute has_element?(view, "#tools-publish-form-error")
    end

    test "a zip is refused by its contents; nothing over the package limit is taken", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/tools")
      upload(view, "#tools-publish-form", "PK\x03\x04 a zip", "tool.zip")
      view |> form("#tools-publish-form") |> render_submit()
      assert has_element?(view, "#tools-publish-form-error", "that is not a readable .tar.gz")

      {:ok, view, _html} = live(conn, ~p"/tools")
      big = :binary.copy("x", Tools.Package.max_compressed() + 1)

      input =
        file_input(view, "#tools-publish-form", :package, [%{name: "big.tar.gz", content: big}])

      assert {:error, [[_ref, :too_large]]} = render_upload(input, "big.tar.gz")
      assert render(view) =~ "That file is over 10 MB."
    end

    test "the button waits for a file", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tools")
      assert has_element?(view, "#tools-publish-form button[type=submit][disabled]")
    end
  end

  describe "on a Tool's page" do
    setup %{user: user} do
      name = unique_name()
      {:ok, version} = Tools.publish(user, package(name, "1.0.0"))
      %{name: name, tool: version.tool}
    end

    test "the owner publishes the next version and sees it", %{conn: conn, name: name} do
      {:ok, view, _html} = live(conn, ~p"/tools/#{name}")
      assert has_element?(view, "#tool-publish", "higher")

      upload(view, "#tool-publish-form", package(name, "1.1.0", %{"README.md" => "# Newer"}))
      view |> form("#tool-publish-form") |> render_submit()

      assert_patch(view, "/tools/#{name}?version=1.1.0")
      assert render(view) =~ "Published 1.1.0."
      assert has_element?(view, "#tool-header", "version 1.1.0")
      assert has_element?(view, "#tool-readme", "Newer")
      assert has_element?(view, "#tool-versions", "1.0.0")
      assert latest(name) == "1.1.0"
    end

    test "a package of another Tool is refused, and nothing is published", %{
      conn: conn,
      user: user,
      name: name
    } do
      other = unique_name()
      {:ok, view, _html} = live(conn, ~p"/tools/#{name}")

      upload(view, "#tool-publish-form", package(other, "1.0.0"))
      view |> form("#tool-publish-form") |> render_submit()

      assert has_element?(
               view,
               "#tool-publish-form-error",
               "this package is the Tool “#{other}”, not “#{name}”"
             )

      assert {:error, :not_found} = Tools.fetch(user, other)
      assert latest(name) == "1.0.0"
    end

    test "nobody but the owner gets the form, or can publish", %{
      user: user,
      tool: tool,
      name: name
    } do
      friend = user_fixture("publish-friend@example.com")
      {:ok, _} = Tools.share(user, tool, friend)

      {:ok, view, _html} = live(log_in_user(build_conn(), friend), ~p"/tools/#{name}")
      refute has_element?(view, "#tool-publish")

      # A hand-made event changes nothing and the page carries on.
      render_hook(view, "publish_package", %{})
      assert has_element?(view, "#tool-header", "version 1.0.0")
      assert latest(name) == "1.0.0"
    end
  end
end
