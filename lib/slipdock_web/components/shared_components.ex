defmodule SlipdockWeb.SharedComponents do
  @moduledoc """
  The **Shared with me** tree (#817), as `Slipdock.Wiki.SharedTree` builds
  it: grouped by owner, a shared folder open to its whole subtree. Drawn on
  the Shared view and under every wiki and vault tree of the person things
  were shared with. Pages open in the Shared view; files and drawings in
  their own.
  """
  use SlipdockWeb, :html

  alias Slipdock.Accounts.User
  alias Slipdock.Wiki.{Excalidraw, Files}

  attr :groups, :list, required: true
  attr :current, :any, default: nil
  attr :id, :string, default: "shared-tree"

  def shared_tree(assigns) do
    ~H"""
    <nav :if={@groups != []} id={@id} aria-label="Shared with me" class="space-y-3 text-sm">
      <.link
        navigate={~p"/shared"}
        class="flex items-center gap-1.5 px-2 text-xs font-semibold uppercase tracking-wide text-base-content/50 hover:text-base-content/80"
      >
        <.icon name="hero-users" class="size-3.5" /> Shared with me
      </.link>
      <div :for={group <- @groups} data-owner={group.owner.id} class="space-y-0.5">
        <p class="px-2 text-xs text-base-content/60">From {User.display_name(group.owner)}</p>
        <ul class="space-y-0.5">
          <.shared_item :for={item <- group.items} item={item} current={@current} />
        </ul>
      </div>
    </nav>
    """
  end

  attr :item, :map, required: true
  attr :current, :any, default: nil

  defp shared_item(%{item: %{kind: :page}} = assigns) do
    ~H"""
    <li>
      <.page_link page={@item.page} current={@current} />
    </li>
    """
  end

  defp shared_item(%{item: %{kind: :folder}} = assigns) do
    ~H"""
    <li>
      <details open class="group" data-key={"folder:#{@item.folder.id}"}>
        <summary class="flex cursor-pointer list-none items-center gap-1 rounded-lg px-2 py-1 hover:bg-base-200">
          <.icon
            name="hero-chevron-right"
            class="size-3 shrink-0 text-base-content/40 transition-transform group-open:rotate-90"
          />
          <.link
            navigate={~p"/shared/folders/#{@item.folder.id}"}
            class={[
              "flex min-w-0 flex-1 items-center gap-1.5 font-medium",
              @current == "folder:#{@item.folder.id}" && "text-primary"
            ]}
          >
            <.icon name="hero-folder" class="size-3.5 shrink-0 text-base-content/50" />
            <span class="truncate">{@item.folder.name}</span>
          </.link>
        </summary>
        <ul class="ml-3 space-y-0.5 border-l border-base-300 pl-1">
          <.shared_item
            :for={inner <- @item.folders}
            item={inner}
            current={@current}
          />
          <li :for={page <- @item.pages}>
            <.page_link page={page} current={@current} />
          </li>
          <li :for={file <- @item.files}>
            <.link
              navigate={Files.open_path(file)}
              data-key={"file:#{file.id}"}
              class="flex items-center gap-1.5 rounded-lg px-2 py-1 hover:bg-base-200"
            >
              <.icon name="hero-paper-clip" class="size-3.5 shrink-0 text-base-content/50" />
              <span class="truncate">{file.name}</span>
            </.link>
          </li>
        </ul>
      </details>
    </li>
    """
  end

  attr :page, :any, required: true
  attr :current, :any, default: nil

  defp page_link(assigns) do
    ~H"""
    <.link
      navigate={
        if Excalidraw.page?(@page),
          do: ~p"/drawings/page/#{@page.id}",
          else: ~p"/shared/pages/#{@page.id}"
      }
      data-key={"page:#{@page.id}"}
      class={[
        "flex items-center gap-1.5 rounded-lg px-2 py-1 hover:bg-base-200",
        @current == "page:#{@page.id}" && "bg-base-200 font-medium"
      ]}
    >
      <.icon name="hero-document-text" class="size-3.5 shrink-0 text-base-content/50" />
      <span class="truncate">{@page.title}</span>
    </.link>
    """
  end
end
