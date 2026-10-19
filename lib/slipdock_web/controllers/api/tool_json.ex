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
      kind: tool |> then(&Tools.access(user, &1)) |> kind(),
      installed: installed(Tools.current_install(user, tool))
    }
  end

  defp kind(:owner), do: "mine"
  defp kind(other), do: Atom.to_string(other)

  @doc "One Tool at one version, with what it would install."
  def show(%Tools.Tool{} = tool, %Tools.Version{} = version, user) do
    manifest = version.manifest || %{}
    install = Tools.current_install(user, tool)

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
            skill_md: file_url(tool, "skills/#{skill.name}/SKILL.md", version),
            claude_zip: base <> "/claude.zip?version=#{version.version}",
            chatgpt_zip: base <> "/chatgpt.zip?version=#{version.version}"
          })
        end),
      skills_archive: "/api/tools/#{tool.slug}/skills.tar.gz?version=#{version.version}",
      files:
        Enum.map(manifest["files"] || [], fn f ->
          f
          |> Map.take(["path", "install", "skill"])
          |> Map.put("url", file_url(tool, "files/" <> f["path"], version))
          |> put_board_url(f, install)
        end),
      size: version.size,
      listing: listing(tool, version, user)
    })
  end

  # A board file the caller's install put in the wiki, where it is now: the
  # copy on the board, which is the one a skill reads at run time.
  defp put_board_url(entry, %{"install" => "board", "path" => path}, %Tools.Install{
         board: %{} = board
       }),
       do:
         Map.put(
           entry,
           "board_url",
           "/api/boards/#{board.code || board.id}/files/" <>
             encode(Tools.tool_folder() <> "/" <> path)
         )

  defp put_board_url(entry, _file, _install), do: entry

  defp encode(path),
    do:
      path
      |> String.split("/")
      |> Enum.map_join("/", fn s -> URI.encode(s, &URI.char_unreserved?/1) end)

  # Where one file of the package is read from (#1156). Without `?version=`
  # the same address gives whatever version is newest for the caller.
  defp file_url(tool, path, version),
    do: "/api/tools/#{tool.slug}/files/#{encode(path)}?version=#{version.version}"

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
      upgraded: Map.get(result, :upgraded, false),
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

  # What the owner sees of listing: which version is listed for everyone, and
  # where this one stands. Nobody else is told about requests.
  defp listing(tool, version, user) do
    if Tools.owner?(user, tool) do
      listed = Tools.listed_version(tool)

      %{
        listed_version: listed && listed.version,
        this_version:
          cond do
            version.approved_at -> "approved"
            version.declined_at -> "declined"
            version.listing_requested_at -> "waiting for an admin"
            true -> "not requested"
          end,
        declined_reason: version.declined_reason
      }
    end
  end
end
