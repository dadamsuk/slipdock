defmodule SlipdockCLI.Sync.Remote do
  @moduledoc false

  # The server, as the sync engine talks to it: a vault as files. A behaviour
  # so the engine can be driven against an in-memory vault in tests; the one
  # real implementation is the HTTP API (`/api/vaults/:id/sync`).
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

  @behaviour __MODULE__

  @impl true
  def list(vault), do: HTTP.get("/vaults/#{vault}/sync") |> norm(nil)

  @impl true
  def read(vault, id), do: HTTP.get("/vaults/#{vault}/sync/pages/#{id}") |> norm("page")

  @impl true
  def write(vault, nil, params),
    do: HTTP.put("/vaults/#{vault}/sync/pages", params) |> norm("page")

  def write(vault, id, params),
    do: HTTP.put("/vaults/#{vault}/sync/pages/#{id}", params) |> norm("page")

  @impl true
  def archive(vault, id, base),
    do: HTTP.delete("/vaults/#{vault}/sync/pages/#{id}", base: base) |> norm("page")

  @impl true
  def changes(vault, cursor),
    do: HTTP.get("/vaults/#{vault}/changes", since: cursor) |> norm(nil)

  defp norm({:ok, data}, nil), do: {:ok, data}
  defp norm({:ok, data}, key), do: {:ok, data[key]}
  defp norm({:error, 409, %{"current" => current}}, _key), do: {:conflict, current}

  defp norm({:error, :connect, reason}, _key),
    do: {:error, "could not reach the server (#{inspect(reason)})"}

  defp norm({:error, 401, _}, _key), do: {:error, :unauthorized}
  defp norm({:error, status, %{"error" => msg}}, _key), do: {:error, "#{msg} (HTTP #{status})"}
  defp norm({:error, status, data}, _key), do: {:error, "HTTP #{status}: #{inspect(data)}"}
end
