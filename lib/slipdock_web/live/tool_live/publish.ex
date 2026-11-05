defmodule SlipdockWeb.ToolLive.Publish do
  @moduledoc """
  Publishing a Tool from the browser: a package uploaded on the Tools page
  (a new Tool, or the next version of one of yours, as its `tool.json`
  says) or on your Tool's own page (the next version of that Tool only).
  The same `Slipdock.Tools.publish/3` as `slipdock tools publish`, so the
  same checks and the same messages.
  """
  use SlipdockWeb, :html

  import Phoenix.LiveView, only: [allow_upload: 3, consume_uploaded_entries: 3]

  alias Slipdock.Tools

  @doc """
  Lets `socket` take one package upload, as big as a package may be. Any
  file is taken: `.tgz` has no MIME type to filter on and browsers name it
  differently, so the bytes decide — `Package.read/1` refuses anything that
  isn't a readable `.tar.gz`.
  """
  def allow(socket) do
    allow_upload(socket, :package,
      accept: :any,
      max_entries: 1,
      max_file_size: Tools.Package.max_compressed()
    )
  end

  @doc """
  Publishes the uploaded package as `user`: `{:ok, version}`, or
  `{:error, message}` to show. `opts` go to `Tools.publish/3`.
  """
  def consume(socket, user, opts \\ []) do
    case consume_uploaded_entries(socket, :package, fn %{path: path}, _entry ->
           {:ok, Tools.publish(user, File.read!(path), opts)}
         end) do
      [{:ok, version}] -> {:ok, version}
      [{:error, message}] when is_binary(message) -> {:error, message}
      [{:error, :payment_required, _code, message}] -> {:error, message}
      [] -> {:error, "Choose a package first."}
    end
  end

  @doc "Where a just-published version is shown."
  def path(version), do: "/tools/#{version.tool.slug}?version=#{version.version}"

  attr :id, :string, required: true
  attr :upload, :map, required: true
  attr :error, :string, default: nil
  attr :label, :string, required: true

  @doc "The form: a file input, what's chosen, any error, and the button."
  def form(assigns) do
    ~H"""
    <form id={@id} phx-submit="publish_package" phx-change="validate_package" class="mt-3">
      <.file_picker
        id={"#{@id}-file"}
        upload={@upload}
        cancel="cancel_package"
        hint={"A tool package (.tar.gz), up to #{div(Tools.Package.max_compressed(), 1024 * 1024)} MB"}
        class="max-w-md"
      />
      <p :if={@error} id={"#{@id}-error"} class="mt-2 text-sm text-error">{@error}</p>
      <button type="submit" class="btn btn-primary btn-sm mt-3" disabled={@upload.entries == []}>
        {@label}
      </button>
    </form>
    """
  end
end
