defmodule Slipdock.Skills.ChatGPT do
  @moduledoc """
  The agent skills (see `Slipdock.Skills`) rewritten for ChatGPT, one `.zip`
  per skill, which is what ChatGPT's skill upload takes.

  ChatGPT can't run the `slipdock` CLI: its sandbox has no network. It can
  reach this server as an MCP connector, though, so each skill gets a section
  at the top that maps the commands the skill uses onto the connector's tools.
  The rest of the skill is the same file, so these can't drift from the
  originals: they're built from `priv/skills` each time they're asked for.

  `slipdock-loop` isn't offered. It's about unattended passes that commit,
  push and watch CI, and a ChatGPT conversation can do none of those.
  """

  alias Slipdock.Skills

  @left_out ~w(slipdock-loop)

  # Every `slipdock` command the skills use, and the connector tool that does
  # the same. The tool names are checked against the MCP server's in the tests,
  # so a renamed tool fails the build rather than this table.
  @tools [
    {"whoami", "whoami"},
    {"guide", "get_guide"},
    {"boards / favourites / columns", "list_boards"},
    {"board <board>", "get_board"},
    {"cards <board> [--column, --assignee, --no-assignee, --tag, --q]", "list_cards"},
    {"card <id>", "get_card"},
    {"add <board> <title>, add with a parent card", "create_card"},
    {"edit / flag / tag / blocked-by / check / tick", "update_card"},
    {"move <id> <list>", "move_card"},
    {"comment <id> <text>", "comment"},
    {"attach <id> <file> (up to 10 MB)", "upload_file"},
    {"attachments <id>, then one of the files", "download_file"},
    {"done <id>", "complete_card"},
    {"status <id> <health> [note]", "status_update"},
    {"archive <id>", "archive_card"},
    {"delete <id>", "delete_card"},
    {"new-column", "create_list"},
    {"new-tag <board> <name>", "create_tag"},
    {"new-board", "create_board"},
    {"archive-board / restore-board", "archive_board"},
    {"automations / automation / automation-help / automation-presets", "list_automations"},
    {"new-automation / set-automation / delete-automation", "manage_automation"},
    {"activity", "activity"},
    {"search <query>", "search"},
    {"page ls / page tree / wiki", "list_pages"},
    {"page read / page section", "read_page"},
    {"page new / page edit / page append", "write_page"},
    {"page edit --title / --summary, page pin, page rm", "update_page"},
    {"page links / page sections / vault wanted", "page_info"},
    {"page history / page diff", "page_history"},
    {"page revert", "revert_page"},
    {"vault ls / vault show / vault locate / vault resolve", "list_vaults"},
    {"vault new / rename / rm / map / unmap", "manage_vault"},
    {"claim-job", "claim_job"},
    {"job-progress", "job_progress"},
    {"finish-job", "finish_job"},
    {"capture new <board> --transcript", "capture_meeting"},
    {"capture show / capture preview", "get_capture"},
    {"capture resolve", "resolve_capture_question"},
    {"capture commit", "commit_capture"}
  ]

  @doc "The connector tool names the mapping uses, for the tests to check."
  def tool_names, do: Enum.map(@tools, &elem(&1, 1))

  @doc "The skills offered for ChatGPT: every skill but the ones left out."
  def list, do: Enum.reject(Skills.list(), &(&1.name in @left_out))

  @doc "Whether `name` is offered for ChatGPT."
  def offered?(name), do: Enum.any?(list(), &(&1.name == name))

  @doc """
  A skill's `SKILL.md` for ChatGPT: the front matter with a description that
  names the connector rather than the CLI, then the ChatGPT section, then the
  skill as it is. `base_url` is this server's address, for the connector.
  """
  def skill_md(name, base_url) do
    with true <- offered?(name),
         {:ok, text} <- Skills.read(name) do
      {front, body} = split_front_matter(text)
      {:ok, front <> preamble(base_url) <> body}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  One skill as a `.zip` holding `<name>/SKILL.md` and its `references/`, which
  is the layout ChatGPT's skill upload expects.
  """
  def zip(name, base_url) do
    with {:ok, skill_md} <- skill_md(name, base_url),
         %{files: files} <- Skills.get(name) do
      files
      |> Enum.map(fn
        "SKILL.md" ->
          {"SKILL.md", skill_md}

        file ->
          {:ok, text} = Skills.read(name, file)
          {file, text}
      end)
      |> then(&zip_files(name, &1))
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  A skill that is not one of this server's own — one a Tool carries (see
  `Slipdock.Tools`) — as ChatGPT's upload takes it: `files` as `{path,
  contents}` within the skill's folder. Its `SKILL.md` gets a short note on
  reaching the board through the connector, since a Tool's skill may talk in
  CLI commands or in tool names.
  """
  def zip_skill(name, files, base_url) do
    files
    |> Enum.map(fn
      {"SKILL.md", text} ->
        {front, body} = split_front_matter(text)
        {"SKILL.md", front <> connector_note(base_url) <> body}

      other ->
        other
    end)
    |> then(&zip_files(name, &1))
  end

  @doc "`files` (`{path, contents}`) as a `.zip` with them under `<name>/`."
  def zip_files(name, files) do
    entries = for {file, text} <- files, do: {String.to_charlist(Path.join(name, file)), text}

    case :zip.create(~c"#{name}.zip", entries, [:memory]) do
      {:ok, {_, bytes}} -> {:ok, bytes}
      _ -> {:error, :unavailable}
    end
  end

  defp connector_note(base_url) do
    """

    ## Using this in ChatGPT

    Everything this skill does on the board goes through the **Slipdock
    connector**, at `#{base_url}/mcp`. If its tools aren't available, ask the
    person to add it (Settings → Apps & Connectors, with that address) and
    sign in when Slipdock asks. Read any `slipdock …` command below as the
    connector tool that does the same thing; `get_guide` lists them.
    """
  end

  # The front matter stays first, because that's where ChatGPT reads the name
  # and description from. Only the description changes: the original says the
  # skill works "with the `slipdock` CLI", which here it doesn't.
  defp split_front_matter("---\n" <> rest = text) do
    case String.split(rest, "\n---\n", parts: 2) do
      [front, body] -> {"---\n" <> connector_description(front) <> "\n---\n", body}
      _ -> {"", text}
    end
  end

  defp split_front_matter(text), do: {"", text}

  defp connector_description(front) do
    front
    |> String.replace("with the `slipdock` CLI", "through the Slipdock connector")
    |> String.replace("with the `slipdock page` commands", "through the Slipdock connector")
  end

  defp preamble(base_url) do
    rows =
      Enum.map_join(@tools, "\n", fn {command, tool} -> "| `#{command}` | `#{tool}` |" end)

    """

    ## Using this in ChatGPT

    This skill was written for agents with a shell, and talks in `slipdock`
    commands. Here there is no shell that can reach the board: everything goes
    through the **Slipdock connector** instead, at `#{base_url}/mcp`. If its
    tools aren't available, ask the person to add it (Settings → Apps &
    Connectors, with that address) and sign in when Slipdock asks.

    Read every `slipdock …` command below as the connector tool that does the
    same thing. Each tool says what it takes; its arguments are mostly the
    command's flags in snake case (`--no-assignee` is `no_assignee`).

    | Command | Connector tool |
    |---|---|
    #{rows}

    The `capture` tools are there only while the server's admin has meeting
    mode on.

    A few things the skill mentions have no tool: running an automation now, its callbacks and alerts, runners and
    their setup, views, swimlanes, files over 10 MB (meeting recordings,
    mostly — send a transcript instead) and transcribing them, folders, tags on a board, `slipdock
    auth` and anything under `slipdock admin`. For those, say
    what you would have done and point the person to the board in the web app,
    at #{base_url}. Don't pretend a write landed when there was no tool to make
    it.

    Anything about installing the CLI, tokens in `~/.config/slipdock`, git, CI
    or running tests applies to agents with a machine of their own, not here.
    """
  end
end
