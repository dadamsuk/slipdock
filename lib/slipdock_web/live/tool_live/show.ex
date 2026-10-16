defmodule SlipdockWeb.ToolLive.Show do
  @moduledoc """
  A Tool's page (#963): its README, everything installing it would do —
  the board it builds, the files, and every skill file in full, readable
  before anything is installed — and how to install it from each client,
  written so somebody who has never opened a terminal can follow it.

  A Tool the viewer can't see is a 404, exactly as one that doesn't exist.
  Its owner can share it with people and groups here.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.Automations.Presets
  alias Slipdock.Tools
  alias SlipdockWeb.RichText

  @clients ~w(claude_ai claude_code chatgpt)

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Tools.fetch(user, slug) do
      {:ok, tool} ->
        {:ok,
         socket
         |> assign(
           page_title: tool.name,
           tool: tool,
           base_url: SlipdockWeb.BaseURL.from_socket(socket),
           client: "claude_ai",
           share_email: "",
           just_installed: nil
         )
         |> load(nil)}

      _ ->
        raise Ecto.NoResultsError, queryable: Tools.Tool
    end
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, load(socket, params["version"])}

  defp load(socket, number) do
    user = socket.assigns.current_user
    tool = socket.assigns.tool

    case Tools.visible_version(user, tool, number) || Tools.visible_version(user, tool) do
      nil ->
        raise Ecto.NoResultsError, queryable: Tools.Tool

      version ->
        latest = Tools.visible_version(user, tool)
        files = Tools.files(version)

        assign(socket,
          version: version,
          latest: latest,
          versions: Tools.versions(tool),
          skills: Tools.skills(version),
          skill_files: Map.new(Tools.skill_trees(version)),
          board_files: board_files(version, files),
          install: Tools.current_install(user, tool),
          owner?: Tools.owner?(user, tool),
          grants: if(Tools.owner?(user, tool), do: Tools.grants(tool), else: [])
        )
    end
  end

  defp board_files(version, files) do
    for %{"install" => "board", "path" => path} <- version.manifest["files"] || [],
        f = Enum.find(files, &(&1.path == "files/" <> path)),
        do: %{path: path, size: f.size}
  end

  ## Events ---------------------------------------------------------------------

  @impl true
  def handle_event("client", %{"client" => client}, socket) when client in @clients,
    do: {:noreply, assign(socket, client: client)}

  def handle_event("install", _params, socket) do
    %{current_user: user, tool: tool, version: version} = socket.assigns

    case Tools.install_board(user, tool, version: version.version) do
      {:ok, result} ->
        message =
          if result.created,
            do: "Made the board “#{result.board.name}”.",
            else: "You already have this Tool's board, “#{result.board.name}”."

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign(just_installed: result.board)
         |> load(version.version)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That version is no longer there.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("share", %{"email" => email}, socket) do
    %{current_user: user, tool: tool} = socket.assigns

    case Tools.share(user, tool, String.trim(email)) do
      {:ok, _grant} ->
        {:noreply,
         socket
         |> put_flash(:info, "Shared with #{String.trim(email)}.")
         |> assign(share_email: "")
         |> load(socket.assigns.version.version)}

      {:error, message} when is_binary(message) ->
        {:noreply, socket |> put_flash(:error, message) |> assign(share_email: email)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That couldn't be shared.")}
    end
  end

  def handle_event("unshare", %{"id" => id}, socket) do
    %{current_user: user, tool: tool} = socket.assigns

    case Tools.unshare(user, tool, String.to_integer(id)) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "No longer shared.") |> load(socket.assigns.version.version)}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  ## Helpers ----------------------------------------------------------------------

  defp preset_title(key), do: (Presets.get(key) || %{title: key}).title

  defp role_label(%{"role" => role}) when is_binary(role), do: role
  defp role_label(%{"category" => c}) when is_binary(c), do: c
  defp role_label(_), do: nil

  defp tag_name(%{"name" => n}), do: n
  defp tag_name(n), do: n

  defp download(tool, skill, kind, version),
    do: "/tools/#{tool.slug}/download/#{skill}/#{kind}.zip?version=#{version.version}"

  defp subject_name(%{user: %{} = u}), do: u.name || u.email
  defp subject_name(%{group: %{} = g}), do: "group #{g.name}"
  defp subject_name(_), do: "someone"

  defp kb(bytes) when bytes < 1024, do: "#{bytes} B"
  defp kb(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"

  defp setup_skill(skills) do
    Enum.find(skills, &String.ends_with?(&1.name, "-setup")) || List.first(skills)
  end

  ## Render -------------------------------------------------------------------------

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, default: "Copy"

  # As on Account → Agent: selectable, and a button that copies it.
  defp copy_block(assigns) do
    ~H"""
    <div class="mt-2">
      <code
        id={@id}
        class="block select-all whitespace-pre-wrap break-words rounded-xl bg-base-200 px-3 py-2 font-mono text-xs leading-relaxed"
        phx-no-format
      >{@text}</code>
      <button
        type="button"
        id={"#{@id}-copy"}
        class="btn btn-ghost btn-xs mt-1 gap-1"
        phx-hook="CopyText"
        data-target={@id}
      >
        <.icon name="hero-clipboard" class="size-3.5" /> <span data-label>{@label}</span>
      </button>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
    >
      <:nav>
        <.link navigate={~p"/tools"} class="text-base-content/60 hover:text-base-content">Tools</.link>
        <span class="mx-1 text-base-content/40">/</span>
        <span class="font-semibold">{@tool.name}</span>
      </:nav>
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-4xl space-y-6 px-4 py-6 sm:px-6 sm:py-10">
          <header id="tool-header" class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">{@tool.name}</h1>
              <p class="mt-1 max-w-xl text-base-content/70">{@tool.summary}</p>
              <p class="mt-2 text-xs text-base-content/50">
                <code>{@tool.slug}</code> · version {@version.version}
                <span :if={@version.manifest["author"]}>· by {@version.manifest["author"]}</span>
                <span :if={@owner?} class="badge badge-sm badge-ghost ml-1">yours</span>
              </p>
              <p :if={@latest && @latest.id != @version.id} class="mt-2 text-sm text-warning">
                This is an older version. The latest is <.link
                  patch={~p"/tools/#{@tool.slug}"}
                  class="link"
                >{@latest.version}</.link>.
              </p>
            </div>
            <div :if={length(@versions) > 1} id="tool-versions" class="text-sm">
              <label class="text-xs text-base-content/60">Version</label>
              <div class="flex flex-wrap gap-1">
                <.link
                  :for={v <- @versions}
                  patch={~p"/tools/#{@tool.slug}?version=#{v.version}"}
                  class={["badge", if(v.id == @version.id, do: "badge-primary", else: "badge-ghost")]}
                >
                  {v.version}
                </.link>
              </div>
            </div>
          </header>

          <section
            id="tool-status"
            class="rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <%= if @install && @install.board do %>
              <p id="tool-installed" class="text-sm">
                <.icon name="hero-check-circle" class="size-4 text-success" />
                You have this Tool's board:
                <.link navigate={~p"/boards/#{@install.board.id}"} class="link font-medium">
                  {@install.board.name}
                </.link>
                (version {@install.version}).
              </p>
            <% else %>
              <p id="tool-not-installed" class="text-sm text-base-content/70">
                You haven't installed this Tool yet.
                <span :if={@version.board}>
                  Its board is built for you by Slipdock, exactly as described below — your agent
                  then fills it in with you.
                </span>
              </p>
              <button
                :if={@version.board}
                id="tool-install-board"
                class="btn btn-primary btn-sm mt-3"
                phx-click="install"
                phx-disable-with="Building the board…"
              >
                Make the board
              </button>
            <% end %>
          </section>

          <section
            id="tool-steps"
            class="rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <h2 class="text-lg font-semibold">How to install it</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Pick the assistant you use. Each way ends the same: you ask it to set the Tool up.
            </p>
            <div class="mt-3 flex flex-wrap gap-2" role="tablist">
              <button
                :for={
                  {key, label} <- [
                    {"claude_ai", "Claude (website or app)"},
                    {"claude_code", "Claude Code"},
                    {"chatgpt", "ChatGPT"}
                  ]
                }
                id={"tool-client-#{key}"}
                role="tab"
                aria-selected={to_string(@client == key)}
                class={["btn btn-sm", if(@client == key, do: "btn-primary", else: "btn-ghost")]}
                phx-click="client"
                phx-value-client={key}
              >
                {label}
              </button>
            </div>

            <ol
              :if={@client == "claude_ai"}
              id="tool-steps-claude-ai"
              class="mt-4 list-decimal space-y-3 pl-5 text-sm"
            >
              <li>
                Connect Claude to Slipdock, if you haven't already: in Claude, open <b>Settings → Connectors</b>, choose <b>Add custom connector</b>, and paste <code class="select-all">{@base_url}/mcp</code>. Sign in when Slipdock asks.
              </li>
              <li>
                Download each skill below. Each is one file; don't unzip it.
                <ul class="mt-2 space-y-1">
                  <li :for={skill <- @skills}>
                    <.link
                      href={download(@tool, skill.name, "claude", @version)}
                      class="link font-medium"
                      download
                    >
                      {skill.name}.zip
                    </.link>
                    <span class="text-base-content/50">— {skill.description}</span>
                  </li>
                </ul>
              </li>
              <li>
                In Claude, open <b>Settings → Capabilities</b>, find <b>Skills</b>, choose <b>Upload skill</b>, and pick each file you downloaded.
              </li>
              <li>{ask_line(assigns)}</li>
            </ol>

            <ol
              :if={@client == "claude_code"}
              id="tool-steps-claude-code"
              class="mt-4 list-decimal space-y-3 pl-5 text-sm"
            >
              <li>
                If you don't have the <code>slipdock</code>
                command yet, see <.link navigate={~p"/account/agent"} class="link">Account → Agent</.link>.
              </li>
              <li>
                Install the skills with one command:
                <.copy_block
                  id="tool-install-command"
                  text={"slipdock tools install #{@tool.slug}"}
                  label="Copy command"
                />
              </li>
              <li>{ask_line(assigns)}</li>
            </ol>

            <ol
              :if={@client == "chatgpt"}
              id="tool-steps-chatgpt"
              class="mt-4 list-decimal space-y-3 pl-5 text-sm"
            >
              <li>
                Connect ChatGPT to Slipdock: open <b>Settings → Apps &amp; Connectors</b>, add a
                connector, and paste <code class="select-all">{@base_url}/mcp</code>. Sign in
                when Slipdock asks.
              </li>
              <li>
                Download each skill below — these versions say how to use the connector:
                <ul class="mt-2 space-y-1">
                  <li :for={skill <- @skills}>
                    <.link
                      href={download(@tool, skill.name, "chatgpt", @version)}
                      class="link font-medium"
                      download
                    >
                      {skill.name}.zip
                    </.link>
                  </li>
                </ul>
              </li>
              <li>Upload each one in ChatGPT's skills settings.</li>
              <li>{ask_line(assigns)}</li>
            </ol>
          </section>

          <section
            id="tool-readme"
            class="rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <div class="prose prose-sm max-w-none">{RichText.markdown(@version.readme)}</div>
          </section>

          <section
            id="tool-contents"
            class="rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <h2 class="text-lg font-semibold">What installing it does</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Everything is here to read before you install. A Tool's skills are instructions
              your assistant follows with your access, so read them as you would anything you
              let act for you. Installing touches only the new board it makes.
            </p>

            <div :if={@version.board} id="tool-board" class="mt-4 space-y-2 text-sm">
              <h3 class="font-semibold">A new board</h3>
              <p>
                Lists:
                <span :for={{list, i} <- Enum.with_index(@version.board["lists"])}>
                  <span :if={i > 0} class="text-base-content/40">→</span>
                  <b>{list["name"]}</b><span
                    :if={role_label(list)}
                    class="text-xs text-base-content/50"
                  > ({role_label(list)})</span>
                </span>
              </p>
              <p :if={@version.board["folders"] != []}>
                Wiki folders: {Enum.join(@version.board["folders"], ", ")}
              </p>
              <p :if={@version.board["tags"] != []}>
                Tags: {Enum.map_join(@version.board["tags"], ", ", &tag_name/1)}
              </p>
              <div :if={@version.board["pages"] != []}>
                Pages to fill in:
                <ul class="list-disc pl-5">
                  <li :for={page <- @version.board["pages"]}>
                    {page["title"]}<span :if={page["folder"]} class="text-base-content/50"> in {page[
                      "folder"
                    ]}</span>
                  </li>
                </ul>
              </div>
              <div :if={@version.board["automations"] != []}>
                Automation rules:
                <ul class="list-disc pl-5">
                  <li :for={rule <- @version.board["automations"]}>
                    {rule["name"] || preset_title(rule["preset"])}
                    <span class="text-base-content/50">
                      ({Enum.map_join(rule["params"], ", ", fn {k, v} -> "#{k}: #{v}" end)})
                    </span>
                  </li>
                </ul>
              </div>
              <p :if={@board_files != []}>
                Files, in the board's <b>{Tools.tool_folder()}</b>
                folder: {Enum.map_join(@board_files, ", ", &"#{&1.path} (#{kb(&1.size)})")}
              </p>
            </div>

            <div id="tool-skills" class="mt-6 space-y-4">
              <h3 class="text-sm font-semibold">Skills, in full</h3>
              <div :for={skill <- @skills} id={"tool-skill-#{skill.name}"} class="space-y-2">
                <p class="text-sm">
                  <b>{skill.name}</b>
                  <span class="text-base-content/60">— {skill.description}</span>
                  <code class="ml-1 text-xs text-base-content/40">{skill.sha}</code>
                </p>
                <div
                  :for={{path, content} <- @skill_files[skill.name]}
                  class="rounded-lg ring-1 ring-base-content/10"
                >
                  <p class="border-b border-base-content/10 px-3 py-1 text-xs font-mono text-base-content/60">
                    {skill.name}/{path}
                  </p>
                  <pre class="max-h-96 overflow-auto whitespace-pre-wrap px-3 py-2 text-xs"><%= if String.valid?(content), do: content, else: "(#{kb(byte_size(content))} of binary data)" %></pre>
                </div>
              </div>
            </div>
          </section>

          <section
            :if={@owner?}
            id="tool-sharing"
            class="rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <h2 class="text-lg font-semibold">Who can see it</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Only you, and the people you share it with here. They can read it and install it.
            </p>
            <ul class="mt-3 space-y-1 text-sm">
              <li :for={g <- @grants} id={"tool-grant-#{g.id}"} class="flex items-center gap-2">
                {subject_name(g)}
                <button class="btn btn-ghost btn-xs" phx-click="unshare" phx-value-id={g.id}>Remove</button>
              </li>
            </ul>
            <form id="tool-share-form" phx-submit="share" class="mt-3 flex gap-2">
              <input
                type="email"
                name="email"
                value={@share_email}
                placeholder="their email address"
                class="input input-sm w-64"
                required
              />
              <button class="btn btn-sm">Share</button>
            </form>
            <p class="mt-4 text-xs text-base-content/50">
              Publish a new version with <code>slipdock tools publish &lt;folder&gt;</code>; versions
              never change once published.
            </p>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp ask_line(assigns) do
    assigns = assign(assigns, :setup, setup_skill(assigns.skills))

    ~H"""
    Start a new chat and ask: <b>“Set up {@tool.name} for me.”</b>
    <span :if={@setup}>
      The <code>{@setup.name}</code> skill takes it from there: it has Slipdock build the board,
      then asks you what it needs to fill it in.
    </span>
    """
  end
end
