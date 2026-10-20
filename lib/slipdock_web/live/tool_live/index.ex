defmodule SlipdockWeb.ToolLive.Index do
  @moduledoc """
  The Tools gallery (#964): the Tools somebody can install here — their own,
  the ones shared with them, and the ones an admin has listed for everyone.
  A package uploaded here publishes a new Tool, or the next version of one
  of theirs (`SlipdockWeb.ToolLive.Publish`).
  """
  use SlipdockWeb, :live_view

  alias Slipdock.Tools
  alias SlipdockWeb.ToolLive.Publish

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Tools", publish_error: nil)
     |> Publish.allow()
     |> load()}
  end

  @impl true
  def handle_event("validate_package", _params, socket),
    do: {:noreply, assign(socket, publish_error: nil)}

  def handle_event("cancel_package", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :package, ref)}

  def handle_event("publish_package", _params, socket) do
    case Publish.consume(socket, socket.assigns.current_user) do
      {:ok, version} ->
        {:noreply,
         socket
         |> put_flash(:info, "Published #{version.tool.slug} #{version.version}.")
         |> push_navigate(to: Publish.path(version))}

      {:error, message} ->
        {:noreply, assign(socket, publish_error: message)}
    end
  end

  defp load(socket) do
    user = socket.assigns.current_user

    own = Tools.list_own(user)
    shared = Tools.list_shared(user)
    seen = MapSet.new(own ++ shared, & &1.id)

    assign(socket,
      sections: [
        {"yours", "Yours", own},
        {"shared", "Shared with you", shared},
        {"listed", "On this server",
         Enum.reject(Tools.list_listed(), &MapSet.member?(seen, &1.id))}
      ],
      installs: user |> Tools.installs() |> Map.new(&{&1.tool_id, &1})
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      waiting_count={@waiting_count}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:tools}
    >
      <:nav>
        <span class="font-semibold">Tools</span>
      </:nav>
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-4xl space-y-8 px-4 py-6 sm:px-6 sm:py-10">
          <div>
            <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Tools</h1>
            <p class="mt-1 max-w-xl text-sm text-base-content/60">
              A Tool is a ready-made way of working: a board Slipdock builds for you, and the
              skills that teach your assistant to use it. Open one to read everything it does
              before you install it.
            </p>
          </div>

          <section :for={{key, title, tools} <- @sections} id={"tools-#{key}"}>
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
              {title}
            </h2>
            <p :if={tools == []} class="mt-2 text-sm text-base-content/50">
              <%= if key == "yours" do %>
                None yet. Publish one below, or with <code>slipdock tools publish &lt;folder&gt;</code>.
              <% else %>
                None.
              <% end %>
            </p>
            <ul class="mt-2 grid gap-3 sm:grid-cols-2">
              <li :for={tool <- tools} id={"tool-card-#{tool.slug}"}>
                <.link
                  navigate={~p"/tools/#{tool.slug}"}
                  class="block h-full rounded-2xl bg-base-100 p-4 shadow-sm ring-1 ring-base-content/10 transition hover:ring-primary/40"
                >
                  <p class="font-semibold">{tool.name}</p>
                  <p class="mt-1 text-sm text-base-content/70">{tool.summary}</p>
                  <p :if={@installs[tool.id]} class="mt-2 text-xs text-success">
                    Installed ({@installs[tool.id].version})
                  </p>
                </.link>
              </li>
            </ul>
          </section>

          <section
            id="tools-publish"
            class="rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <h2 class="text-lg font-semibold">Publish a Tool</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Upload a package: a <code>.tar.gz</code>
              of the Tool's folder (<code>tool.json</code>, <code>README.md</code>, and its <code>skills/</code>), such as
              <code>tar czf my-tool.tgz my-tool</code>
              makes, or one downloaded from a Tool's page. The name in <code>tool.json</code>
              decides what it is: a new Tool, or the next version of one of yours. It is
              yours alone until you share it.
            </p>
            <Publish.form
              id="tools-publish-form"
              upload={@uploads.package}
              error={@publish_error}
              label="Publish"
            />
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
