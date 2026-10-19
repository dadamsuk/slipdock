defmodule SlipdockWeb.MCP.Tools.ListTools do
  @moduledoc """
  The Tools the caller can see (#964) — their own, the ones shared with
  them, and the ones listed for everyone — with the board each install
  made, so a Tool's skill finds its board by its install rather than by
  searching for a page title. With `tool`, one Tool in full; with `file`
  too, one file of it as text (#1156), so a stub skill can read its
  procedure from the latest version at run time; `skill` is the short way
  to a skill's own files (#1158). With `link: true`, no text: a single-use
  URL for a shell to fetch the skills archive, one skill's zip or one file
  from, without a token (as `download_file` gives one, #1147).
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Tools, TransferLinks}
  alias SlipdockWeb.API.ToolJSON
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Tools.DownloadFile

  # Text of one file, read into a tool result; a bigger one is for the API.
  @max_text 200_000

  @impl true
  def name, do: "list_tools"

  @impl true
  def title, do: "List Tools"

  @impl true
  def description,
    do:
      "Tools on this server you can install (yours, shared, listed), each with the board " <>
        "your install made. With tool: that Tool's board blueprint, skills and files. With " <>
        "tool and file (a path in the package, like skills/<skill>/SKILL.md or " <>
        "files/notes.md): that file's text, from the latest version unless version says. " <>
        "With tool and skill: that skill's SKILL.md, or with file too, the file at that path " <>
        "in the skill's folder (references/x.md). With a shell, link: true instead returns a " <>
        "single-use download_url, good for 10 minutes and needing no token: for the file, " <>
        "the skill's claude.ai zip, or with neither the skills .tar.gz."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        tool: %{type: "string", description: "One Tool's name, for all of it."},
        version: %{type: "string", description: "With tool: a version other than the latest."},
        skill: %{
          type: "string",
          description:
            "With tool: one skill's name, for its SKILL.md (or, with file, a file in its folder)."
        },
        file: %{
          type: "string",
          description:
            "With tool: one file's path in the package, for its text. With skill: a path in " <>
              "that skill's folder."
        },
        link: %{
          type: "boolean",
          description:
            "With tool: send no text, get a single-use download_url (10 minutes, no token) " <>
              "for the file, the skill's zip, or else the skills .tar.gz."
        }
      },
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, %{user: user} = context) do
    with {:ok, ref} <- Args.optional(args, "tool"),
         {:ok, number} <- Args.optional(args, "version"),
         {:ok, skill} <- Args.optional(args, "skill"),
         {:ok, path} <- Args.optional(args, "file"),
         {:ok, link?} <- Args.boolean(args, "link", false) do
      case ref do
        nil when is_binary(path) or is_binary(skill) or link? ->
          {:error, "file, skill and link need tool: the Tool they belong to"}

        nil ->
          {:ok, %{tools: Enum.map(Tools.list_for(user), &ToolJSON.listing(&1, user))}}

        ref ->
          with {:ok, tool} <- Tools.fetch(user, ref),
               %{} = version <- Tools.visible_version(user, tool, number) do
            piece(tool, version, skill, path && clean(path), link?, context)
          else
            _ -> {:error, "no Tool you can see is called #{inspect(ref)} at that version"}
          end
      end
    end
  end

  defp clean(path), do: path |> String.trim() |> String.trim_leading("/")

  defp piece(tool, version, nil, nil, false, %{user: user}),
    do: {:ok, %{tool: ToolJSON.show(tool, version, user)}}

  defp piece(tool, version, nil, nil, true, context),
    do: link(tool, version, "archive", "#{tool.slug}-skills.tar.gz", %{}, context)

  defp piece(tool, version, nil, path, link?, context),
    do: package_file(tool, version, path, link?, context)

  defp piece(tool, version, skill, path, link?, context) do
    with :ok <- skill_exists(tool, version, skill) do
      case {path, link?} do
        {nil, true} ->
          link(tool, version, "claude:" <> skill, "#{skill}.zip", %{skill: skill}, context)

        _ ->
          package_file(
            tool,
            version,
            skill_path(version, skill, path || "SKILL.md"),
            link?,
            context
          )
      end
    end
  end

  defp skill_exists(tool, version, skill) do
    if Enum.any?(Tools.skills(version), &(&1.name == skill)),
      do: :ok,
      else:
        {:error,
         "#{tool.slug} #{version.version} has no skill #{skill} — list_tools with tool gives " <>
           "its skills"}
  end

  # A path in the skill's folder, as the package keeps it: the skill's own
  # files under skills/<skill>/, and the manifest's `local` files, which
  # land beside them, under files/.
  defp skill_path(version, skill, path) do
    own = "skills/#{skill}/#{path}"

    local? =
      Enum.any?(
        version.manifest["files"] || [],
        &(&1["install"] == "local" and &1["skill"] == skill and &1["path"] == path)
      )

    if is_nil(Tools.file(version, own)) and local?, do: "files/" <> path, else: own
  end

  defp package_file(tool, version, path, link?, context) do
    case Tools.file(version, path) do
      nil ->
        {:error,
         "#{tool.slug} #{version.version} has no file #{path} — list_tools with tool gives " <>
           "its skills and files"}

      f when link? ->
        link(
          tool,
          version,
          "file:" <> path,
          Path.basename(path),
          %{path: path, size: f.size, sha256: f.sha256},
          context
        )

      f ->
        text(tool, version, path, f)
    end
  end

  defp text(tool, version, path, %{content: bytes} = f) do
    url = "/api/tools/#{tool.slug}/files/#{path}?version=#{version.version}"

    cond do
      not String.valid?(bytes) ->
        {:error, "#{path} is not text: fetch it with link: true, or from #{url} with a token"}

      byte_size(bytes) > @max_text ->
        {:error,
         "#{path} is #{byte_size(bytes)} bytes, too big to read here: fetch it with " <>
           "link: true, or from #{url} with a token"}

      true ->
        {:ok,
         %{
           tool: tool.slug,
           version: version.version,
           path: path,
           size: f.size,
           sha256: f.sha256,
           text: bytes
         }}
    end
  end

  defp link(tool, version, target, filename, extra, context) do
    {:ok, secret, expires_at} =
      TransferLinks.mint(context.user, context.token, {:tool, version, target})

    url = context.base_url <> "/api/download/" <> secret

    {:ok,
     Map.merge(extra, %{
       tool: tool.slug,
       version: version.version,
       filename: filename,
       download_url: url,
       expires_at: expires_at,
       curl: "curl -fsSo #{DownloadFile.shell_name(filename)} #{url}",
       note: "Works once, for #{div(TransferLinks.ttl_seconds(), 60)} minutes, with no token."
     })}
  end
end
