defmodule SlipdockWeb.ToolLiveTest do
  @moduledoc """
  A Tool's page (#963): the README, everything installing it does with every
  skill file in full, a walkthrough per client, install status, and sharing
  by grant. Somebody it isn't shared with gets a 404.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.Tools

  setup %{user: user} do
    Slipdock.TestConfig.own_uploads_dir()
    name = unique_name()
    {:ok, version} = Tools.publish(user, package(name))
    %{name: name, tool: version.tool}
  end

  defp grantee(tool, owner) do
    friend = user_fixture("tool-friend@example.com")
    {:ok, _} = Tools.share(owner, tool, friend)
    friend
  end

  test "the owner sees the README, the board, every skill file in full, and sharing", %{
    conn: conn,
    name: name
  } do
    {:ok, view, html} = live(conn, ~p"/tools/#{name}")

    assert html =~ "Demo Tool"
    assert html =~ "What it does."
    assert has_element?(view, "#tool-board", "Found")
    assert has_element?(view, "#tool-board", "Config")
    assert has_element?(view, "#tool-board", "hot")
    assert has_element?(view, "#tool-board", "Send cards to a runner")
    assert has_element?(view, "#tool-board", "guide.md")

    # Every file of every skill, contents and all — local files too.
    assert has_element?(view, "#tool-skill-#{name}", "#{name}/SKILL.md")
    assert has_element?(view, "#tool-skill-#{name}", "Run it.")
    assert has_element?(view, "#tool-skill-#{name}", "#{name}/references/notes.md")
    assert has_element?(view, "#tool-skill-#{name}", "echo hi")
    assert has_element?(view, "#tool-skill-#{name}-setup", "Call install_tool.")

    assert has_element?(view, "#tool-sharing")
    assert has_element?(view, "#tool-not-installed")
  end

  test "somebody it's shared with sees the page, without the sharing controls", %{
    user: user,
    tool: tool,
    name: name
  } do
    friend = grantee(tool, user)
    {:ok, view, _html} = live(log_in_user(build_conn(), friend), ~p"/tools/#{name}")

    assert has_element?(view, "#tool-readme", "What it does.")
    refute has_element?(view, "#tool-sharing")
  end

  test "somebody it isn't shared with gets a 404, as for a Tool that doesn't exist", %{
    name: name
  } do
    stranger = user_fixture("tool-page-stranger@example.com")
    conn = log_in_user(build_conn(), stranger)

    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/tools/#{name}") end
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/tools/nothing-here-#{name}") end
  end

  test "each client has its own steps, and every one ends by asking to set it up", %{
    conn: conn,
    name: name
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/#{name}")

    # claude.ai by default: connector, zip per skill, upload, then ask.
    assert has_element?(view, "#tool-steps-claude-ai", "/mcp")
    assert has_element?(view, "#tool-steps-claude-ai a[href*='/download/#{name}/claude.zip']")
    assert has_element?(view, "#tool-steps-claude-ai", "Settings → Capabilities")
    assert has_element?(view, "#tool-steps-claude-ai", "Set up Demo Tool for me.")

    view |> element("#tool-client-claude_code") |> render_click()
    assert has_element?(view, "#tool-install-command", "slipdock tools install #{name}")
    assert has_element?(view, "#tool-steps-claude-code", "#{name}-setup")

    view |> element("#tool-client-chatgpt") |> render_click()
    assert has_element?(view, "#tool-steps-chatgpt a[href*='/download/#{name}/chatgpt.zip']")
    assert has_element?(view, "#tool-steps-chatgpt", "Set up Demo Tool for me.")
    refute has_element?(view, "#tool-steps-claude-ai")
  end

  test "Make the board installs it, and the page then says where it is", %{
    conn: conn,
    user: user,
    tool: tool,
    name: name
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/#{name}")

    view |> element("#tool-install-board") |> render_click()

    install = Tools.current_install(user, tool)
    assert install.board_id
    assert has_element?(view, "#tool-installed a[href='/boards/#{install.board_id}']")
    refute has_element?(view, "#tool-install-board")

    # Coming back shows the same thing.
    {:ok, again, _} = live(conn, ~p"/tools/#{name}")
    assert has_element?(again, "#tool-installed", "version 1.0.0")
  end

  test "the owner shares by email and takes it back", %{conn: conn, tool: tool, name: name} do
    friend = user_fixture("tool-share-friend@example.com")
    {:ok, view, _html} = live(conn, ~p"/tools/#{name}")

    view |> form("#tool-share-form", %{"email" => friend.email}) |> render_submit()
    assert [grant] = Tools.grants(tool)
    assert Tools.visible?(friend, tool)
    assert has_element?(view, "#tool-grant-#{grant.id}")

    view |> element("#tool-grant-#{grant.id} button") |> render_click()
    assert Tools.grants(tool) == []
    refute Tools.visible?(friend, tool)
  end

  test "an older version can be read by number", %{conn: conn, user: user, name: name} do
    {:ok, _} = Tools.publish(user, package(name, "2.0.0", %{"README.md" => "# Second"}))

    {:ok, view, _} = live(conn, ~p"/tools/#{name}?version=1.0.0")
    assert has_element?(view, "#tool-readme", "What it does.")
    assert has_element?(view, "#tool-header", "older version")

    {:ok, view, _} = live(conn, ~p"/tools/#{name}")
    assert has_element?(view, "#tool-readme", "Second")
  end

  describe "skill downloads in the browser" do
    test "the owner and a grantee get the zips; a stranger gets a 404", %{
      conn: conn,
      user: user,
      tool: tool,
      name: name
    } do
      zip = conn |> get("/tools/#{name}/download/#{name}/claude.zip") |> response(200)
      {:ok, files} = :zip.extract(zip, [:memory])
      assert Enum.any?(files, fn {p, _} -> to_string(p) == "#{name}/SKILL.md" end)

      friend = grantee(tool, user)
      friend_conn = log_in_user(build_conn(), friend)
      assert friend_conn |> get("/tools/#{name}/download/#{name}/chatgpt.zip") |> response(200)

      stranger = log_in_user(build_conn(), user_fixture("dl-stranger@example.com"))
      assert stranger |> get("/tools/#{name}/download/#{name}/claude.zip") |> response(404)
      assert conn |> get("/tools/#{name}/download/nope/claude.zip") |> response(404)
    end
  end

  describe "the gallery" do
    test "lists yours and the ones shared with you, and marks what you installed", %{
      conn: conn,
      user: user,
      tool: tool,
      name: name
    } do
      {:ok, view, _} = live(conn, ~p"/tools")
      assert has_element?(view, "#tools-yours #tool-card-#{name}")

      {:ok, _} = Tools.install_board(user, tool)
      {:ok, view, _} = live(conn, ~p"/tools")
      assert has_element?(view, "#tool-card-#{name}", "Installed")

      friend = grantee(tool, user)
      {:ok, view, _} = live(log_in_user(build_conn(), friend), ~p"/tools")
      assert has_element?(view, "#tools-shared #tool-card-#{name}")
      refute has_element?(view, "#tools-yours #tool-card-#{name}")
    end
  end

  describe "listing for everyone" do
    setup %{user: user, name: name} do
      admin =
        "tool-admin@example.com"
        |> user_fixture()
        |> Ecto.Changeset.change(admin: true)
        |> Slipdock.Repo.update!()

      %{admin: admin, admin_conn: log_in_user(build_conn(), admin), owner: user, name: name}
    end

    test "the owner asks, an admin approves in the queue, and everybody then sees it", %{
      conn: conn,
      admin_conn: admin_conn,
      name: name
    } do
      {:ok, view, _} = live(conn, ~p"/tools/#{name}")
      view |> element("#tool-request-listing") |> render_click()
      assert has_element?(view, "#tool-listing", "waiting for an admin")

      {:ok, queue, _} = live(admin_conn, ~p"/admin/tools")
      [version] = Enum.filter(Tools.listing_queue(), &(&1.tool.slug == name))
      assert has_element?(queue, "#listing-#{version.id}", "Demo Tool 1.0.0")
      queue |> element("#listing-#{version.id} button", "Approve") |> render_click()
      refute has_element?(queue, "#listing-#{version.id}")
      assert has_element?(queue, "#listing-listed", "Demo Tool")

      stranger = log_in_user(build_conn(), user_fixture("gallery-stranger@example.com"))
      {:ok, gallery, _} = live(stranger, ~p"/tools")
      assert has_element?(gallery, "#tools-listed #tool-card-#{name}")
      assert {:ok, _page, _} = live(stranger, ~p"/tools/#{name}")

      {:ok, view, _} = live(conn, ~p"/tools/#{name}")
      assert has_element?(view, "#tool-listing", "Listed for everyone: version 1.0.0")
    end

    test "an admin declines with a reason the owner sees", %{
      conn: conn,
      admin_conn: admin_conn,
      name: name
    } do
      {:ok, view, _} = live(conn, ~p"/tools/#{name}")
      view |> element("#tool-request-listing") |> render_click()
      [version] = Enum.filter(Tools.listing_queue(), &(&1.tool.slug == name))

      {:ok, queue, _} = live(admin_conn, ~p"/admin/tools")

      queue
      |> form("#decline-#{version.id}", %{"reason" => "too broad"})
      |> render_submit()

      {:ok, view, _} = live(conn, ~p"/tools/#{name}")
      assert has_element?(view, "#tool-listing", "too broad")
    end

    test "the queue is for admins only", %{conn: conn} do
      assert {:error, {:redirect, _}} = live(conn, ~p"/admin/tools")
    end
  end
end
