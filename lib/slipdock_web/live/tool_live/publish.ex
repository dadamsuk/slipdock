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
      <.live_file_input upload={@upload} class="file-input file-input-sm w-full max-w-sm" />
      <div :for={entry <- @upload.entries} class="mt-2 flex items-center gap-3 text-sm">
        <span class="font-mono text-xs">{entry.client_name}</span>
        <button
          type="button"
          phx-click="cancel_package"
          phx-value-ref={entry.ref}
          class="btn btn-ghost btn-xs"
        >
          Remove
        </button>
      </div>
      <p :for={error <- upload_errors(@upload)} class="mt-2 text-sm text-error">
        {error_text(error)}
      </p>
      <p
        :for={error <- Enum.flat_map(@upload.entries, &upload_errors(@upload, &1))}
        class="mt-2 text-sm text-error"
      >
        {error_text(error)}
      </p>
      <p :if={@error} id={"#{@id}-error"} class="mt-2 text-sm text-error">{@error}</p>
      <button type="submit" class="btn btn-primary btn-sm mt-3" disabled={@upload.entries == []}>
        {@label}
      </button>
    </form>
    """
  end

  defp error_text(:too_large),
    do: "That file is over #{div(Tools.Package.max_compressed(), 1024 * 1024)} MB."

  defp error_text(:too_many_files), do: "One package at a time."
  defp error_text(other), do: "That file could not be read (#{inspect(other)})."
end
