defmodule SlipdockWeb.API.ToolJSON do
  @moduledoc "How a Tool and its versions look over the API and MCP."

  alias Slipdock.Tools

  @doc "A Tool in a list: enough to choose one."
  def listing(%Tools.Tool{} = tool, user) do
    version = Tools.visible_version(user, tool)

    %{
      name: tool.slug,
      title: tool.name,
      summary: tool.summary,
      version: version && version.version,
      mine: Tools.owner?(user, tool),
      installed: installed(Tools.current_install(user, tool))
    }
  end

  @doc "One Tool at one version, with what it would install."
  def show(%Tools.Tool{} = tool, %Tools.Version{} = version, user) do
    manifest = version.manifest || %{}

    tool
    |> listing(user)
    |> Map.merge(%{
      version: version.version,
      sha: version.sha,
      author: manifest["author"],
      requires: manifest["requires"],
      published_at: version.inserted_at,
      versions: tool |> Tools.versions() |> Enum.map(& &1.version),
      readme: version.readme,
      board: version.board,
      skills:
        Enum.map(Tools.skills(version), fn skill ->
          base = "/api/tools/#{tool.slug}/skills/#{skill.name}"

          Map.merge(skill, %{
            claude_zip: base <> "/claude.zip?version=#{version.version}",
            chatgpt_zip: base <> "/chatgpt.zip?version=#{version.version}"
          })
        end),
      skills_archive: "/api/tools/#{tool.slug}/skills.tar.gz?version=#{version.version}",
      files: Enum.map(manifest["files"] || [], &Map.take(&1, ["path", "install", "skill"])),
      size: version.size
    })
  end

  @doc "What an install answers: the board and what was made on it."
  def install(
        %{board: board, created: created, version: version, install: install} = result,
        base_url
      ) do
    %{
      board: board.code,
      board_id: board.id,
      board_name: board.name,
      url: base_url <> "/boards/#{board.id}",
      created: created,
      version: version.version,
      installed_version: install.version,
      added: result.report && result.report.added,
      skipped: result.report && result.report.skipped
    }
  end

  @doc "The caller's install of a Tool, or nil."
  def installed(nil), do: nil
  def installed(%Tools.Install{board: nil} = i), do: %{version: i.version, board: nil}

  def installed(%Tools.Install{board: board} = i),
    do: %{version: i.version, board: board.code, board_id: board.id, board_name: board.name}
end
