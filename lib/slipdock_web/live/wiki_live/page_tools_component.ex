defmodule SlipdockWeb.WikiLive.PageToolsComponent do
  @moduledoc """
  The AI tools beside a wiki page (#1539), reading or editing it. Each tool is
  `Slipdock.Wiki.PageTools`, run in a task because it asks a model, over the
  `text` it is given: the saved page when reading, the editor's text when
  editing.

  Keyed on the page, so another page starts with a clean panel, and going from
  reading to editing keeps the answer. Nothing is written unless the reader
  says: the answer goes into the editor by `wiki-editor:insert`, or an action
  becomes a card, which only a saved page being read offers, because making a
  card can write the card's number into the page.
  """
  use SlipdockWeb, :live_component

  alias Slipdock.{Boards, Wiki}
  alias Slipdock.Wiki.PageTools
  alias SlipdockWeb.Markdown

  @impl true
  def mount(socket) do
    {:ok, assign(socket, busy: nil, answer: nil, error: nil, made: %{})}
  end

  @impl true
  def handle_event("run", %{"tool" => tool}, %{assigns: %{busy: nil}} = socket) do
    %{title: title, text: text, current_user: user} = socket.assigns

    {:noreply,
     socket
     |> assign(busy: tool, answer: nil, error: nil, made: %{})
     |> start_async(:run, fn -> PageTools.run(tool, %{title: title, body: text}, user) end)}
  end

  def handle_event("run", _params, socket), do: {:noreply, socket}

  def handle_event("insert", _params, %{assigns: %{editing: true, answer: %{} = answer}} = socket) do
    {:noreply, push_event(socket, "wiki-editor:insert", %{text: answer.text})}
  end

  def handle_event("insert", _params, socket), do: {:noreply, socket}

  def handle_event("make_card", %{"index" => index}, socket) do
    index = String.to_integer(index)

    with %{answer: %{items: items}} = assigns <- socket.assigns,
         true <- cards?(assigns),
         nil <- assigns.made[index],
         text when is_binary(text) <- Enum.at(items, index),
         [column | _] <- Boards.get_board!(assigns.board.id).columns,
         {:ok, card} <-
           Wiki.create_card_from_selection(assigns.page, column, text, write(assigns)) do
      send(self(), {:page_tool_card, assigns.page})
      {:noreply, assign(socket, made: Map.put(assigns.made, index, card.id))}
    else
      [] -> {:noreply, assign(socket, error: "That board has no lists to put a card in.")}
      {:error, _} -> {:noreply, assign(socket, error: "That card couldn't be made.")}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:run, {:ok, {:ok, answer}}, socket) do
    {:noreply, assign(socket, busy: nil, answer: answer)}
  end

  def handle_async(:run, {:ok, {:error, _status, message}}, socket) do
    {:noreply, assign(socket, busy: nil, error: message)}
  end

  def handle_async(:run, {:exit, reason}, socket) do
    require Logger
    Logger.warning("Page tool crashed: #{inspect(reason)}")
    {:noreply, assign(socket, busy: nil, error: "That didn't work; please try again.")}
  end

  defp write(assigns), do: [user: assigns.current_user, via: "web"]

  defp cards?(assigns), do: assigns.can_write and not assigns.editing and not is_nil(assigns.page)

  # Rewriting the page means something only while it is being written.
  defp tools(true), do: PageTools.tools()
  defp tools(false), do: Enum.reject(PageTools.tools(), &(elem(&1, 0) == "improve"))

  defp label(tool), do: List.keyfind(PageTools.tools(), tool, 0) |> elem(1)

  # Written out here, where Tailwind's scan finds the icon classes.
  defp tool_icon("summarise"), do: "hero-bars-3-bottom-left"
  defp tool_icon("key_points"), do: "hero-list-bullet"
  defp tool_icon("actions"), do: "hero-check-circle"
  defp tool_icon("titles"), do: "hero-tag"
  defp tool_icon("improve"), do: "hero-pencil"

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        cards?: cards?(assigns),
        tools: tools(assigns.editing),
        limit: PageTools.page_chars()
      )

    ~H"""
    <aside
      id={@id}
      aria-label="AI tools"
      class="kanban-scroll fixed inset-0 z-50 flex flex-col gap-3 overflow-y-auto bg-base-100 p-4 lg:static lg:z-auto lg:w-80 lg:shrink-0 lg:border-l lg:border-base-300"
    >
      <div class="flex items-center justify-between gap-2">
        <h2 class="flex items-center gap-1.5 text-sm font-semibold">
          <.icon name="hero-sparkles" class="size-4" /> AI tools
        </h2>
        <button
          type="button"
          id="page-tools-close"
          phx-click="toggle_page_tools"
          class="btn btn-ghost btn-xs btn-square"
          title="Close"
          aria-label="Close the AI tools"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <p class="text-xs text-base-content/60">
        {if @editing, do: "Works on what is in the editor now.", else: "Works on the saved page."}
      </p>

      <div class="flex flex-col gap-1">
        <button
          :for={{tool, label} <- @tools}
          type="button"
          id={"page-tool-#{tool}"}
          phx-click="run"
          phx-value-tool={tool}
          phx-target={@myself}
          disabled={not is_nil(@busy)}
          class="btn btn-ghost btn-sm justify-start gap-2"
        >
          <.icon name={tool_icon(tool)} class="size-4" />
          {if @busy == tool, do: "Working…", else: label}
        </button>
      </div>

      <p :if={@error} id="page-tools-error" role="alert" class="text-sm text-error">{@error}</p>

      <section :if={@answer} id="page-tools-answer" class="space-y-2">
        <h3 class="text-xs font-medium text-base-content/60">{label(@answer.tool)}</h3>

        <p :if={@answer.tool == "actions" and @answer.items == []} class="text-sm">
          The page doesn't ask anyone to do anything.
        </p>

        <ul
          :if={@answer.tool == "actions" and @answer.items != []}
          id="page-tools-actions"
          class="space-y-1.5"
        >
          <li
            :for={{item, index} <- Enum.with_index(@answer.items)}
            class="flex items-start gap-2 text-sm"
          >
            <span class="min-w-0 flex-1">{item}</span>
            <span :if={@made[index]} class="shrink-0 text-xs text-success">#{@made[index]}</span>
            <button
              :if={@cards? and is_nil(@made[index])}
              type="button"
              id={"page-tools-card-#{index}"}
              phx-click="make_card"
              phx-value-index={index}
              phx-target={@myself}
              class="btn btn-ghost btn-xs shrink-0"
            >
              Make a card
            </button>
          </li>
        </ul>

        <div
          :if={@answer.tool != "actions"}
          id="page-tools-text"
          class="ai-prose rounded-xl bg-base-200/50 p-3 text-sm leading-relaxed"
          phx-no-format
        >{Markdown.render(@answer.text)}</div>

        <p :if={@answer.truncated} class="text-xs text-base-content/60">
          Only the first {@limit} characters were read.
        </p>
        <p :if={@answer.concealed} class="text-xs text-base-content/60">
          Encrypted passages were left out.
        </p>

        <div class="flex flex-wrap items-center gap-1">
          <button
            :if={@editing and @answer.text != ""}
            type="button"
            id="page-tools-insert"
            phx-click="insert"
            phx-target={@myself}
            class="btn btn-ghost btn-xs gap-1"
          >
            <.icon name="hero-arrow-down-on-square" class="size-3.5" /> Add to the page
          </button>
          <button
            :if={@answer.text != ""}
            type="button"
            id="page-tools-copy"
            phx-hook="CopyText"
            data-target={
              if @answer.tool == "actions", do: "page-tools-actions", else: "page-tools-text"
            }
            class="btn btn-ghost btn-xs gap-1"
          >
            <.icon name="hero-clipboard" class="size-3.5" /> <span data-label>Copy</span>
          </button>
        </div>
      </section>
    </aside>
    """
  end
end
