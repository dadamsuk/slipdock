defmodule SlipdockWeb.WikiMountDressLiveTest do
  @moduledoc """
  A board mounted in a vault wears an icon and a colour in the vault's tree
  (#797), as a board's own folders do (#792). A whole board mounted there
  has no folder to hold them, so they are its mapping's, and only the
  vault's owner sets them.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  alias Slipdock.Vaults

  setup %{user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kbmd"}, owner: user)
    jobs = board_fixture(%{"name" => "Job Hunt", "code" => "jobsmd"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, mapping} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: jobs})
    page_fixture(jobs, %{"title" => "Acme application"})
    %{kb: kb, jobs: jobs, vault: vault, mapping: mapping}
  end

  test "a mounted board's row carries its mapping, and wears nothing until dressed", %{
    conn: conn,
    kb: kb,
    mapping: mapping
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    row = row(tree_load(view), "root", "Jobs")
    assert %{mount: true, mapping: id} = row
    assert id == mapping.id
    refute Map.has_key?(row, :icon)
    refute Map.has_key?(row, :tint)
  end

  test "the vault's owner dresses it from the tree's menu, and the tree wears it", %{
    conn: conn,
    kb: kb,
    vault: vault,
    mapping: mapping
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    render_hook(view, "dress_mount", %{"mapping" => to_string(mapping.id)})
    assert has_element?(view, "#mount-modal", "/Jobs")
    assert has_element?(view, "#mount-dress input[name='icon'][value='briefcase']")

    view
    |> element("#mount-form")
    |> render_submit(%{"icon" => "briefcase", "color" => "amber"})

    refute has_element?(view, "#mount-modal")
    assert {:ok, %{icon: "briefcase", color: "amber"}} = Vaults.find_mapping(vault, "/Jobs")

    row = row(tree_load(view), "root", "Jobs")
    assert row.icon == "hero-briefcase"
    assert row.tint =~ "amber"

    # Opened again, it shows what it wears, and None takes it off.
    render_hook(view, "dress_mount", %{"mapping" => to_string(mapping.id)})
    assert has_element?(view, "#mount-dress input[name='icon'][value='briefcase'][checked]")
    view |> element("#mount-form") |> render_submit(%{"icon" => "", "color" => ""})
    assert {:ok, %{icon: nil, color: nil}} = Vaults.find_mapping(vault, "/Jobs")
  end

  test "an icon not in the set is refused and nothing changes", %{
    conn: conn,
    kb: kb,
    vault: vault,
    mapping: mapping
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")
    render_hook(view, "dress_mount", %{"mapping" => to_string(mapping.id)})

    html = render_hook(view, "save_mount", %{"icon" => "skull", "color" => "amber"})
    assert html =~ "couldn"
    assert {:ok, %{icon: nil, color: nil}} = Vaults.find_mapping(vault, "/Jobs")
  end

  test "the board's switch for icons in the tree hides them on mounts too", %{
    conn: conn,
    kb: kb,
    vault: vault
  } do
    {:ok, _} = Vaults.dress_mapping(vault, "/Jobs", %{icon: "briefcase", color: "amber"})
    {:ok, _} = Slipdock.Wiki.set_tree_icons(kb, false)
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    refute Map.has_key?(row(tree_load(view), "root", "Jobs"), :icon)
  end

  test "somebody else reading the vault's board can't dress its mounts", %{
    kb: kb,
    jobs: jobs,
    vault: vault,
    mapping: mapping
  } do
    other = user_fixture("writer797@example.com")
    share_fixture(kb, other)
    share_fixture(jobs, other)
    conn = log_in_user(build_conn(), other)
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    render_hook(view, "dress_mount", %{"mapping" => to_string(mapping.id)})
    refute has_element?(view, "#mount-modal")

    render_hook(view, "save_mount", %{"icon" => "star"})
    assert {:ok, %{icon: nil}} = Vaults.find_mapping(vault, "/Jobs")
  end

  test "a mapping that isn't this vault's opens nothing", %{conn: conn, kb: kb, user: user} do
    lone = board_fixture(%{"name" => "Elsewhere", "code" => "elsemd"}, owner: user)
    {:ok, other_vault} = Vaults.create_vault(user, %{"name" => "Other"})
    {:ok, theirs} = Vaults.add_mapping(other_vault, user, %{path: "/", board: lone})
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    render_hook(view, "dress_mount", %{"mapping" => to_string(theirs.id)})
    refute has_element?(view, "#mount-modal")
  end
end
