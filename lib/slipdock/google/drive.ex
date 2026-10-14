defmodule Slipdock.Google.Drive do
  @moduledoc """
  The few Drive v3 calls Slipdock makes, each as a person (`user` is a
  `%User{}` or an id) through their connection (`Slipdock.Google`).

  Every call asks `Slipdock.Google.access_token/2` for a token. When Drive
  turns one down (401) the token is traded in once and the call made again,
  so a token revoked or expired early costs one round trip, not an error.

  Errors come back as atoms the callers map to words: `:not_connected`,
  `:revoked`, `:not_found`, `:unavailable` (Google could not be reached, or
  answered 5xx), or `{:status, code}` for anything else.
  """

  alias Slipdock.Google

  @api "https://www.googleapis.com/drive/v3"
  @folder_mime "application/vnd.google-apps.folder"
  @file_fields "id,name,mimeType,size,parents,trashed"

  def folder_mime, do: @folder_mime

  @doc "A file's metadata: `%{\"id\", \"name\", \"mimeType\", \"size\", \"parents\", \"trashed\"}`."
  def file(user, id) when is_binary(id) do
    get(user, "/files/" <> URI.encode(id, &URI.char_unreserved?/1),
      fields: @file_fields,
      supportsAllDrives: true
    )
  end

  @doc """
  The one child of folder `parent_id` (`"root"` for My Drive) called `name`,
  not in the trash: `{:ok, file}`, or `{:error, :not_found}`. When two share
  a name, the one Drive lists first wins, as it would in Drive's own search.
  """
  def child(user, parent_id, name) when is_binary(parent_id) and is_binary(name) do
    q = "name = '#{escape(name)}' and '#{escape(parent_id)}' in parents and trashed = false"

    case get(user, "/files", q: q, fields: "files(#{@file_fields})", pageSize: 10) do
      {:ok, %{"files" => [file | _]}} -> {:ok, file}
      {:ok, _} -> {:error, :not_found}
      error -> error
    end
  end

  # Drive's query language quotes with ' and escapes with \.
  defp escape(text), do: text |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")

  @doc """
  The bytes of file `id`, sent `into` a Req `into:` destination as they
  arrive rather than read whole (see `SlipdockWeb.RecordingController`).
  `headers` are passed on to Drive (`range`). `{:ok, response}` once the body
  has gone, or an error as for any other call.
  """
  def download(user, id, headers, into) when is_binary(id) do
    request(user,
      method: :get,
      url: Google.api_url(@api <> "/files/" <> URI.encode(id, &URI.char_unreserved?/1)),
      params: [alt: "media", supportsAllDrives: true],
      headers: headers,
      into: into,
      decode_body: false,
      # The bytes as Drive keeps them: a player wants audio, not gzip.
      compressed: false
    )
  end

  defp get(user, path, params) do
    case request(user, method: :get, url: Google.api_url(@api <> path), params: params) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} when status >= 500 -> {:error, :unavailable}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, _} = error -> error
    end
  end

  # One call, with one retry on a fresh token if Drive says the token is bad.
  defp request(user, opts) do
    with {:ok, token} <- Google.access_token(user),
         {:ok, %{status: 401}} <- send_request(opts, token),
         {:ok, token} <- Google.access_token(user, force: true) do
      send_request(opts, token)
    end
  end

  defp send_request(opts, token) do
    case Req.request(Google.req(), [auth: {:bearer, token}] ++ opts) do
      {:ok, response} -> {:ok, response}
      {:error, _} -> {:error, :unavailable}
    end
  end
end
