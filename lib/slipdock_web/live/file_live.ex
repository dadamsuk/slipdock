defmodule SlipdockWeb.FileLive do
  @moduledoc """
  A wiki file that is not a page, shown rather than downloaded: what the
  wiki's tree opens a file in. Which viewer it gets is
  `Slipdock.Wiki.Viewer.kind/1`'s to say:

    * an image is an `<img>`, an SVG too, served with a policy that lets it
      run nothing (`SlipdockWeb.WikiFileController`, `?view=inline`);
    * a PDF is the browser's own PDF viewer, in a frame;
    * JSON is a tree whose objects and arrays fold, or pretty-printed text
      when it is too big to fold, or the line where it stopped being JSON;
    * CSV and TSV are a table, the first row its header;
    * plain text is itself.

  Anything else, and anything too big to read here, says so and offers the
  download, which every viewer also has. Drawings and Meld notes have their
  own openers and never come here from the tree.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, Repo}
  alias Slipdock.Wiki.{Files, Viewer, WikiFile}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {n, ""} <- Integer.parse(id),
         %WikiFile{archived_at: nil} = file <- Files.get(n),
         file = Repo.preload(file, [:board, :folder]),
         true <-
           Access.can_read?(Access.board_permission(socket.assigns.current_user, file.board)) do
      kind = Viewer.kind(file)

      {:ok,
       socket
       |> assign(file: file, kind: kind, page_title: file.name)
       |> assign(content(file, kind))}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That file isn't there, or isn't yours to see.")
         |> push_navigate(to: ~p"/")}
    end
  end

  # What the server reads for the viewer: nothing for what the browser draws.
  defp content(file, kind) when kind in [:json, :csv, :tsv, :text] do
    case Viewer.read(file) do
      {:ok, text} ->
        parsed(kind, text, file.name)

      {:error, :too_large} ->
        %{problem: "It is too big to show here (over #{size(Viewer.max_text())})."}

      {:error, :not_text} ->
        %{problem: "It isn't text this viewer can read."}

      {:error, :missing} ->
        %{problem: "Its contents are missing on the server."}
    end
  end

  defp content(_file, _kind), do: %{}

  defp parsed(:json, text, name) do
    case Viewer.json(text, name) do
      {:ok, tree, pretty} -> %{tree: tree, text: pretty}
      {:error, message} -> %{problem: message, text: text}
    end
  end

  defp parsed(:csv, text, _name), do: %{table: Viewer.csv(text, ?,)}
  defp parsed(:tsv, text, _name), do: %{table: Viewer.csv(text, ?\t)}
  defp parsed(:text, text, _name), do: %{text: text}

  defp back(%WikiFile{board_id: board_id, folder_id: nil}), do: ~p"/boards/#{board_id}/wiki"

  defp back(%WikiFile{board_id: board_id, folder_id: folder_id}),
    do: ~p"/boards/#{board_id}/wiki?#{[folder: folder_id]}"

  defp size(bytes) when bytes < 1_000, do: "#{bytes} bytes"
  defp size(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp size(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp inline_url(file), do: Files.url(file) <> "?view=inline"

  ## Render -------------------------------------------------------------------

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
      nav_active={:wiki}
      page_jumps={@page_jumps}
    >
      <div id="file-viewer" data-kind={@kind} class="flex h-full min-h-0 flex-col">
        <div class="flex items-center gap-3 border-b border-base-300 px-4 py-2">
          <.link navigate={back(@file)} class="btn btn-ghost btn-sm" id="file-back">
            <.icon name="hero-arrow-left" class="size-4" /> {@file.board.name}
          </.link>
          <h1 class="min-w-0 flex-1 truncate text-sm font-semibold">{@file.name}</h1>
          <span class="text-xs text-base-content/60">{size(@file.size)}</span>
          <a href={Files.url(@file)} class="btn btn-ghost btn-sm" id="file-download" download>
            <.icon name="hero-arrow-down-tray" class="size-4" /> Download
          </a>
        </div>
        <div class="min-h-0 flex-1 overflow-auto p-4">
          <.viewer kind={@kind} file={@file} {Map.take(assigns, [:tree, :text, :table, :problem])} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :kind, :atom, required: true
  attr :file, WikiFile, required: true
  attr :tree, :any, default: nil
  attr :text, :string, default: nil
  attr :table, :map, default: nil
  attr :problem, :string, default: nil

  defp viewer(%{problem: problem} = assigns) when is_binary(problem) do
    ~H"""
    <div id="file-problem" class="alert alert-warning mb-4">
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <span>{@problem}</span>
    </div>
    <pre :if={@text} id="file-text" class="text-sm whitespace-pre-wrap break-words">{@text}</pre>
    """
  end

  defp viewer(%{kind: kind} = assigns) when kind in [:image, :svg] do
    ~H"""
    <div class="flex justify-center">
      <img
        id="file-image"
        src={if @kind == :svg, do: inline_url(@file), else: Files.url(@file)}
        alt={@file.name}
        class="max-w-full h-auto bg-[repeating-conic-gradient(#8881_0_25%,transparent_0_50%)] bg-[length:16px_16px]"
      />
    </div>
    """
  end

  defp viewer(%{kind: :pdf} = assigns) do
    ~H"""
    <iframe
      id="file-pdf"
      src={inline_url(@file)}
      title={@file.name}
      class="h-full min-h-[70vh] w-full rounded border border-base-300"
    ></iframe>
    """
  end

  defp viewer(%{kind: :json, tree: tree} = assigns) when not is_nil(tree) do
    ~H"""
    <div id="file-json" class="font-mono text-sm">
      <.json_node node={@tree} depth={0} />
    </div>
    """
  end

  defp viewer(%{kind: kind, table: %{}} = assigns) when kind in [:csv, :tsv] do
    ~H"""
    <p
      :if={@table.total > length(@table.rows)}
      id="file-table-cut"
      class="mb-2 text-xs text-base-content/60"
    >
      Showing the first {length(@table.rows)} of {@table.total} rows. Download it for the rest.
    </p>
    <p :if={@table.header == []} class="text-sm text-base-content/60">This file is empty.</p>
    <table :if={@table.header != []} id="file-table" class="table table-zebra table-pin-rows table-sm">
      <thead>
        <tr>
          <th :for={cell <- @table.header}>{cell}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @table.rows}>
          <td :for={cell <- row} class="whitespace-pre-wrap align-top">{cell}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp viewer(%{text: text} = assigns) when is_binary(text) do
    ~H"""
    <pre id="file-text" class="text-sm whitespace-pre-wrap break-words">{@text}</pre>
    """
  end

  defp viewer(assigns) do
    ~H"""
    <div id="file-none" class="mx-auto max-w-md py-12 text-center text-sm text-base-content/70">
      <.icon name="hero-document" class="size-10 opacity-50" />
      <p class="mt-2">There's no viewer for this kind of file yet.</p>
      <a href={Files.url(@file)} class="btn btn-primary btn-sm mt-4" download>Download it</a>
    </div>
    """
  end

  attr :node, :any, required: true
  attr :depth, :integer, required: true
  attr :key, :string, default: nil

  # A value on one line; an object or array folds, the outer two levels open.
  defp json_node(%{node: {:value, _}} = assigns) do
    ~H"""
    <div class="pl-4">
      <span :if={@key} class="text-primary">{Jason.encode!(@key)}: </span><span class={
        value_class(@node)
      }>{elem(@node, 1)}</span>
    </div>
    """
  end

  defp json_node(%{node: {type, children}} = assigns) do
    assigns = assign(assigns, type: type, children: children)

    ~H"""
    <details open={@depth < 2} class="pl-4" data-json={@type}>
      <summary class="cursor-pointer select-none">
        <span :if={@key} class="text-primary">{Jason.encode!(@key)}: </span><span class="text-base-content/60">{summary(
          @type,
          @children
        )}</span>
      </summary>
      <%= for child <- @children do %>
        <%= if @type == :object do %>
          <.json_node node={elem(child, 1)} key={elem(child, 0)} depth={@depth + 1} />
        <% else %>
          <.json_node node={child} depth={@depth + 1} />
        <% end %>
      <% end %>
    </details>
    """
  end

  defp summary(:object, children),
    do: "{…} #{length(children)} #{if length(children) == 1, do: "key", else: "keys"}"

  defp summary(:array, children),
    do: "[…] #{length(children)} #{if length(children) == 1, do: "item", else: "items"}"

  defp value_class({:value, "\"" <> _}), do: "text-success"
  defp value_class({:value, v}) when v in ["true", "false", "null"], do: "text-warning"
  defp value_class(_), do: "text-info"
end
