defmodule Slipdock.ToolsUpgradeTest do
  @moduledoc """
  Installing a newer version over an install (#965): only what the board is
  missing is added, a page the person edited is never overwritten, the
  install's version moves on, and the report says what happened.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Automations, Boards, Repo, Tools, Wiki}
  alias Slipdock.Wiki.Folders

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    user = user_fixture("upgrade-owner@example.com")
    name = unique_name()
    {:ok, v1} = Tools.publish(user, package(name, "1.0.0"))
    {:ok, installed} = Tools.install_board(user, v1.tool)
    %{user: user, name: name, tool: v1.tool, board: installed.board}
  end

  defp v1_board(name), do: Jason.decode!(files(name)["board.json"])

  defp publish_v2(user, name, board, extra \\ %{}) do
    overrides = Map.merge(%{"board.json" => Jason.encode!(board)}, extra)
    {:ok, v2} = Tools.publish(user, package(name, "2.0.0", overrides))
    v2
  end

  defp page(board, title), do: Enum.find(Wiki.list_pages(board), &(&1.title == title))

  test "adds what is missing, refreshes an untouched page and leaves an edited one alone", %{
    user: user,
    name: name,
    tool: tool,
    board: board
  } do
    edited = page(board, "#{name} config")
    {:ok, _} = Wiki.update_page(edited, %{"body" => "My own notes."}, user: user)

    v2_board =
      v1_board(name)
      |> Map.update!("lists", &(&1 ++ [%{"name" => "Archive", "category" => "dropped"}]))
      |> Map.update!("folders", &(&1 ++ ["Runs"]))
      |> Map.update!("tags", &(&1 ++ ["cold"]))
      |> Map.update!("pages", fn pages ->
        Enum.map(pages, &Map.put(&1, "body", "New skeleton.")) ++
          [%{"title" => "Run log", "folder" => "Runs", "body" => "Runs go here."}]
      end)
      |> Map.update!(
        "automations",
        &(&1 ++ [%{"preset" => "follow_list", "params" => %{"column" => "Archive"}}])
      )

    manifest =
      files(name)["tool.json"]
      |> Jason.decode!()
      |> Map.update!("files", &(&1 ++ [%{"path" => "extra.md", "install" => "board"}]))

    publish_v2(user, name, v2_board, %{
      "tool.json" => Jason.encode!(Map.put(manifest, "version", "2.0.0")),
      "files/extra.md" => "More."
    })

    assert {:ok, result} = Tools.install_board(user, tool)
    refute result.created
    assert result.upgraded
    assert result.board.id == board.id

    assert result.report.added["lists"] == ["Archive"]
    assert result.report.added["folders"] == ["Runs"]
    assert result.report.added["tags"] == ["cold"]
    assert result.report.added["pages"] == ["Run log"]
    assert result.report.added["automations"] == ["Followed: Archive"]
    assert result.report.added["files"] == ["extra.md"]
    assert result.report.skipped["pages"] == ["#{name} config"]
    assert "Found" in result.report.skipped["lists"]

    board = Boards.get_board!(board.id)
    assert List.last(board.columns).name == "Archive"
    assert {:ok, _} = Folders.find(board, "Runs")
    assert Repo.reload(edited).body == "My own notes."
    assert page(board, "Run log").body == "Runs go here."
    assert length(Automations.list_rules(board.id)) == 2
    assert Tools.current_install(user, tool).version == "2.0.0"
  end

  test "a page nobody edited takes the new skeleton", %{
    user: user,
    name: name,
    tool: tool,
    board: board
  } do
    v2_board =
      Map.update!(v1_board(name), "pages", fn pages ->
        Enum.map(pages, &Map.put(&1, "body", "Better skeleton."))
      end)

    publish_v2(user, name, v2_board)

    assert {:ok, result} = Tools.install_board(user, tool)
    assert result.report.added["pages"] == ["#{name} config (updated)"]
    assert page(board, "#{name} config").body == "Better skeleton."
  end

  test "a newer version that brings nothing new adds nothing but moves the version on", %{
    user: user,
    name: name,
    tool: tool,
    board: board
  } do
    publish_v2(user, name, v1_board(name))
    before = {length(Boards.get_board!(board.id).columns), length(Wiki.list_pages(board))}

    assert {:ok, result} = Tools.install_board(user, tool)
    assert result.upgraded
    assert Enum.all?(Map.values(result.report.added), &(&1 == []))
    assert {length(Boards.get_board!(board.id).columns), length(Wiki.list_pages(board))} == before
    assert Tools.current_install(user, tool).version == "2.0.0"
  end

  test "the installed version again, or an older one, changes nothing", %{
    user: user,
    name: name,
    tool: tool
  } do
    assert {:ok, %{upgraded: false, report: nil}} = Tools.install_board(user, tool)

    publish_v2(user, name, v1_board(name))
    {:ok, _} = Tools.install_board(user, tool)

    assert {:ok, %{upgraded: false, report: nil}} =
             Tools.install_board(user, tool, version: "1.0.0")

    assert Tools.current_install(user, tool).version == "2.0.0"
  end
end
