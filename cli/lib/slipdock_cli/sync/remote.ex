defmodule SlipdockCLI.Sync.Remote do
  @moduledoc false

  # The server, as the sync engine talks to it: your wiki as files. A
  # behaviour so the engine can be driven against an in-memory wiki in tests;
  # the one real implementation is the HTTP API (`/api/wiki/sync`). The
  # context is unused here: a person has one wiki, which no address names.
  #
  # Every answer is normalised to `{:ok, map}`, `{:conflict, current}` (the
  # file as the server now has it, content and all) or `{:error, message}`.

  alias SlipdockCLI.HTTP

  @type result :: {:ok, map} | {:conflict, map} | {:error, String.t()}

  @callback list(ctx :: term) :: result
  @callback read(ctx :: term, id :: integer) :: result
  @callback write(ctx :: term, id :: integer | nil, params :: map) :: result
  @callback archive(ctx :: term, id :: integer, base :: String.t() | nil) :: result
  @callback changes(ctx :: term, cursor :: integer | nil) :: result
  @callback read_file(ctx :: term, id :: integer, dest :: Path.t()) ::
              {:ok, String.t()} | {:error, String.t()}
  @callback write_file(ctx :: term, id :: integer | nil, params :: map, source :: Path.t()) ::
              result
  @callback move_file(ctx :: term, id :: integer, params :: map) :: result
  @callback archive_file(ctx :: term, id :: integer, base :: String.t() | nil) :: result

  @behaviour __MODULE__

  @impl true
  # `stubs`: this client writes stubs of what is shared with you (#819).
  def list(_wiki), do: HTTP.get("/wiki/sync", stubs: 1) |> norm(nil)

  @impl true
  def read(_wiki, id), do: HTTP.get("/wiki/sync/pages/#{id}") |> norm("page")

  @impl true
  def write(_wiki, nil, params),
    do: HTTP.put("/wiki/sync/pages", params) |> norm("page")

  def write(_wiki, id, params),
    do: HTTP.put("/wiki/sync/pages/#{id}", params) |> norm("page")

  @impl true
  def archive(_wiki, id, base),
    do: HTTP.delete("/wiki/sync/pages/#{id}", base: base) |> norm("page")

  @impl true
  def changes(_wiki, cursor),
    do: HTTP.get("/wiki/changes", since: cursor) |> norm(nil)

  # A file's bytes go straight to `dest` on disk; the answer is their hash,
  # worked out from what arrived rather than taken on trust.
  @impl true
  def read_file(_wiki, id, dest) do
    case HTTP.download("/wiki/sync/files/#{id}", dest) do
      :ok -> {:ok, SlipdockCLI.Sync.Scan.sha_file(dest)}
      error -> norm(error, nil)
    end
  end

  # Streamed from disk a megabyte at a time (`HTTP.post_multipart/3`), so a
  # 250 MB file is never in memory.
  @impl true
  def write_file(_wiki, id, params, source) do
    path = if id, do: "/wiki/sync/files/#{id}", else: "/wiki/sync/files"
    fields = params |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    name = Path.basename(params["path"] || source)

    HTTP.post_multipart(path, fields, [
      {"file", name, "application/octet-stream", {:path, source}}
    ])
    |> norm("file")
  end

  @impl true
  def move_file(_wiki, id, params),
    do: HTTP.patch("/wiki/sync/files/#{id}", params) |> norm("file")

  @impl true
  def archive_file(_wiki, id, base),
    do: HTTP.delete("/wiki/sync/files/#{id}", base: base) |> norm("file")

  defp norm({:ok, data}, nil), do: {:ok, data}
  defp norm({:ok, data}, key), do: {:ok, data[key]}
  defp norm({:error, 409, %{"current" => current}}, _key), do: {:conflict, current}

  defp norm({:error, :connect, reason}, _key),
    do: {:error, "could not reach the server (#{inspect(reason)})"}

  defp norm({:error, 401, _}, _key), do: {:error, :unauthorized}
  defp norm({:error, status, %{"error" => msg}}, _key), do: {:error, "#{msg} (HTTP #{status})"}
  defp norm({:error, status, data}, _key), do: {:error, "HTTP #{status}: #{inspect(data)}"}
end
