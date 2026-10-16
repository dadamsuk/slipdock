defmodule SlipdockWeb.ToolLive.Index do
  @moduledoc """
  The Tools gallery (#964): the Tools somebody can install here — their own,
  the ones shared with them, and the ones an admin has listed for everyone.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.Tools

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Tools") |> load()}
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
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
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
                None yet. Publish one with <code>slipdock tools publish &lt;folder&gt;</code>.
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
        </div>
      </div>
    </Layouts.app>
    """
  end
end
