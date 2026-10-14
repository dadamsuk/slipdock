defmodule SlipdockWeb.RecordingController do
  @moduledoc """
  A meeting page's recording, streamed from Google Drive (W-1690): what the
  player's `<audio>` points at.

  The browser names only the page. Which file is played comes from the
  page's own front matter (`recording`, `recording_drive_id`), resolved under
  its vault's recordings folder through the vault owner's Drive connection
  (`Slipdock.Recordings`) — so being able to read a board never becomes
  being able to read its owner's Drive.

  The bytes go from Drive to the reader as they arrive, a chunk at a time:
  nothing is buffered whole and nothing touches the disk. The reader's
  `Range` is passed on and Drive's answer relayed (200 or 206 with its
  `Content-Range`), so the player can seek.

  A failure is a status and a JSON `reason` the player puts in words:
  409 `not_connected` / `revoked` / `no_folder`, 403 `outside_folder` /
  `not_audio`, 404 `not_found` / `no_recording`, 502 `unavailable`.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Recordings, Repo, Vaults, Wiki}
  alias Slipdock.Google.Drive
  alias Slipdock.Wiki.{FrontMatter, Page}

  # Drive's headers worth handing on; everything else is Google's business.
  @relayed ~w(content-type content-length content-range accept-ranges etag last-modified)

  def show(conn, %{"id" => id}) do
    with {n, ""} <- Integer.parse(id),
         %Page{archived_at: nil} = page <- Wiki.get_page(n),
         page = Repo.preload(page, :board),
         true <- Access.can_read?(Access.board_permission(conn.assigns.current_user, page.board)) do
      yaml = FrontMatter.yaml(page.front_matter)
      recording = string(FrontMatter.get(yaml, "recording"))
      drive_id = string(FrontMatter.get(yaml, "recording_drive_id"))

      case {recording, Vaults.for_board(page.board_id)} do
        {nil, _} -> refuse(conn, 404, :no_recording)
        {_, nil} -> refuse(conn, 409, :no_folder)
        {recording, vault} -> play(conn, vault, recording, drive_id)
      end
    else
      _ -> refuse(conn, 404, :not_found)
    end
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  defp play(conn, vault, recording, drive_id) do
    case Recordings.resolve(vault, recording, drive_id) do
      {:ok, file} ->
        stream(conn, vault, recording, file)

      {:error, reason} ->
        refuse(conn, status(reason), reason)
    end
  end

  defp stream(conn, vault, recording, file) do
    headers = Enum.filter([range: List.first(get_req_header(conn, "range"))], &elem(&1, 1))

    case Drive.download(vault.user_id, file.id, headers, &relay(conn, &1, &2)) do
      {:ok, %{status: status} = response} when status in [200, 206] ->
        # Sent as it arrived; an empty file never reached `relay/3`.
        Req.Response.get_private(response, :conn) || start(conn, response, "")

      {:ok, %{status: 416} = response} ->
        conn
        |> relay_headers(response)
        |> send_resp(416, "")

      {:ok, %{status: 404}} ->
        # Remembered under a path it no longer has: look again next time.
        Recordings.forget(vault, recording)
        refuse(conn, 404, :not_found)

      {:ok, %{status: status}} when status >= 500 ->
        refuse(conn, 502, :unavailable)

      {:ok, %{status: _}} ->
        refuse(conn, 502, :unavailable)

      {:error, reason} when is_atom(reason) ->
        refuse(conn, status(reason), reason)
    end
  end

  # Req's `into:`: each chunk of Drive's answer as it comes. The first sends
  # the status and headers; an error's body is Drive's and is not passed on.
  defp relay(conn, {:data, data}, {req, %{status: status} = response})
       when status in [200, 206] do
    conn = Req.Response.get_private(response, :conn) || start_chunked(conn, response)

    case chunk(conn, data) do
      {:ok, conn} -> {:cont, {req, Req.Response.put_private(response, :conn, conn)}}
      # The reader went away (a seek, a closed tab): stop asking Drive.
      {:error, _} -> {:halt, {req, Req.Response.put_private(response, :conn, conn)}}
    end
  end

  defp relay(_conn, {:data, _data}, acc), do: {:cont, acc}

  defp start_chunked(conn, response) do
    conn
    |> relay_headers(response)
    |> send_chunked(response.status)
  end

  defp start(conn, response, body) do
    conn
    |> relay_headers(response)
    |> send_resp(response.status, body)
  end

  defp relay_headers(conn, response) do
    conn =
      Enum.reduce(@relayed, conn, fn name, conn ->
        case Req.Response.get_header(response, name) do
          [value | _] -> put_resp_header(conn, name, value)
          [] -> conn
        end
      end)

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp refuse(conn, status, reason) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(%{reason: reason})
  end

  defp status(reason) when reason in [:not_connected, :revoked, :no_folder], do: 409
  defp status(reason) when reason in [:outside_folder, :not_audio, :invalid], do: 403
  defp status(:not_found), do: 404
  defp status(_), do: 502
end
