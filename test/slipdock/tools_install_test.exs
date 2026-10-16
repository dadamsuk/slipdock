defmodule Slipdock.ToolsInstallTest do
  @moduledoc """
  install_tool's server side (#961): the board a Tool comes with is built by
  the server from its blueprint, its board files land in a Tool folder, and
  the install is recorded so asking again finds the same board.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Automations, Boards, Repo, Tools, Wiki}
  alias Slipdock.Wiki.Folders

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    owner = user_fixture("tool-owner@example.com")
    name = unique_name()
    {:ok, version} = Tools.publish(owner, package(name))
    %{owner: owner, tool: version.tool, name: name}
  end

  defp owned_boards(user),
    do: Repo.aggregate(from(b in Boards.Board, where: b.owner_id == ^user.id), :count)

  test "a fresh install builds the whole board and records it", %{
    owner: owner,
    tool: tool,
    name: name
  } do
    assert {:ok, result} = Tools.install_board(owner, tool, name: "My demo")
    assert result.created
    board = result.board

    assert board.name == "My demo"
    assert board.owner_id == owner.id
    assert Enum.map(board.columns, & &1.name) == ["Found", "Doing", "Closed"]
    roles = SlipdockWeb.APIGuide.list_roles(board.columns)
    assert {roles.ready.name, roles.doing.name, roles.done.name} == {"Found", "Doing", "Closed"}

    assert {:ok, config} = Folders.find(board, "Config")
    assert [page] = board |> Wiki.list_pages() |> Enum.filter(&(&1.title == "#{name} config"))
    assert page.folder_id == config.id
    assert [%{name: "hot"}] = Boards.list_tags(board.id)
    assert [rule] = Automations.list_rules(board.id)
    assert rule.spec["trigger"]["column"] == "Doing"

    # Board files go in the Tool folder; local ones stay off the board.
    assert {:ok, tool_folder} = Folders.find(board, "Tool")
    files = Repo.all(from(f in Slipdock.Wiki.WikiFile, where: f.board_id == ^board.id))
    assert [%{name: "guide.md", folder_id: folder_id}] = files
    assert folder_id == tool_folder.id

    assert result.report.added["files"] == ["guide.md"]
    assert result.report.added["pages"] == ["#{name} config"]

    install = Tools.current_install(owner, tool)
    assert install.board_id == board.id
    assert install.version == "1.0.0"
  end

  test "installing again returns the same board and makes nothing", %{owner: owner, tool: tool} do
    {:ok, first} = Tools.install_board(owner, tool)
    count = owned_boards(owner)

    assert {:ok, again} = Tools.install_board(owner, tool, name: "Another name")
    refute again.created
    assert again.board.id == first.board.id
    assert owned_boards(owner) == count
    assert length(Tools.installs(owner)) == 1
  end

  test "somebody the Tool isn't shared with can't install it", %{tool: tool, name: name} do
    stranger = user_fixture("tool-stranger@example.com")

    assert {:error, :not_found} = Tools.fetch(stranger, name)
    assert {:error, :not_found} = Tools.install_board(stranger, tool)
    assert owned_boards(stranger) == 0
    assert Tools.installs(stranger) == []
  end

  test "a version that is not the latest installs that version's board", %{
    owner: owner,
    tool: tool,
    name: name
  } do
    newer =
      files(name, "1.1.0", %{
        "board.json" =>
          Jason.encode!(%{"lists" => [%{"name" => "Inbox", "role" => "ready"}, "Done"]})
      })

    {:ok, _} = Tools.publish(owner, tarball(newer))

    assert {:ok, result} = Tools.install_board(owner, tool, version: "1.0.0")
    assert Enum.map(result.board.columns, & &1.name) == ["Found", "Doing", "Closed"]
    assert Tools.current_install(owner, tool).version == "1.0.0"

    assert {:error, :not_found} =
             Tools.install_board(user_fixture("x@example.com"), tool, version: "9.9.9")
  end

  test "a version that doesn't exist is not found", %{owner: owner, tool: tool} do
    assert {:error, :not_found} = Tools.install_board(owner, tool, version: "9.9.9")
  end

  test "after the board is deleted, installing makes a new one", %{owner: owner, tool: tool} do
    {:ok, first} = Tools.install_board(owner, tool)
    {:ok, _} = Boards.delete_board(first.board)

    assert {:ok, again} = Tools.install_board(owner, tool)
    assert again.created
    assert again.board.id != first.board.id
    assert Tools.current_install(owner, tool).board_id == again.board.id
  end

  test "a Tool with no board.json has no board to install", %{owner: owner} do
    name = unique_name()
    {:ok, v} = Tools.publish(owner, tarball(files(name, "1.0.0", %{"board.json" => nil})))

    assert {:error, message} = Tools.install_board(owner, v.tool)
    assert message =~ "no board to install"
    assert Tools.current_install(owner, v.tool) == nil
  end
end
