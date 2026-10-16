defmodule SlipdockWeb.API.ToolController do
  @moduledoc """
  Tools (see `Slipdock.Tools`): publishing a package, and reading what one
  holds. A Tool the caller may not see is a 404 whether or not it exists.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Tools
  alias SlipdockWeb.API.ToolJSON

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, _params) do
    user = conn.assigns.current_user
    json(conn, %{tools: Enum.map(Tools.list_for(user), &ToolJSON.listing(&1, user))})
  end

  def show(conn, %{"slug" => slug} = params) do
    user = conn.assigns.current_user

    with {:ok, tool} <- fetch(user, slug),
         %{} = version <- Tools.visible_version(user, tool, params["version"]) || not_found(slug) do
      json(conn, %{tool: ToolJSON.show(tool, version, user)})
    end
  end

  @doc """
  Builds the Tool's board for the caller, or finds the one already built:
  201 with the board's code when it is new, 200 when it was there.
  """
  def install(conn, %{"slug" => slug} = params) do
    user = conn.assigns.current_user

    with :ok <- unscoped(conn.assigns[:api_token]),
         {:ok, tool} <- fetch(user, slug) do
      case Tools.install_board(user, tool, version: params["version"], name: params["name"]) do
        {:ok, result} ->
          conn
          |> put_status(if(result.created, do: :created, else: :ok))
          |> json(%{install: ToolJSON.install(result, SlipdockWeb.BaseURL.from_conn(conn))})

        {:error, :not_found} ->
          {:error, :not_found, "version #{params["version"]} of Tool #{inspect(slug)}"}

        {:error, message} when is_binary(message) ->
          {:error, :unprocessable_entity, message}
      end
    end
  end

  defp unscoped(%{scope_boards: [_ | _]}),
    do: {:error, :forbidden, "this token is confined to some boards, so it can't make one"}

  defp unscoped(_), do: :ok

  @doc """
  Publishes a package: a `.tar.gz` sent as the multipart field `package`, or
  as the whole body with a gzip content type.
  """
  def create(conn, params) do
    with {:ok, bytes} <- package_bytes(conn, params) do
      case Tools.publish(conn.assigns.current_user, bytes) do
        {:ok, version} ->
          conn
          |> put_status(:created)
          |> json(%{tool: ToolJSON.show(version.tool, version, conn.assigns.current_user)})

        {:error, :payment_required, code, message} ->
          {:error, :payment_required, code, message}

        {:error, message} when is_binary(message) ->
          {:error, :unprocessable_entity, message}
      end
    end
  end

  defp package_bytes(_conn, %{"package" => %Plug.Upload{path: path}}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        if size > Tools.Package.max_compressed(),
          do: {:error, :unprocessable_entity, "the package is over 10 MB"},
          else: File.read(path)

      _ ->
        {:error, :bad_request, "the package is empty"}
    end
  end

  defp package_bytes(conn, _params) do
    case conn |> get_req_header("content-type") |> List.first() |> to_string() do
      "application/gzip" <> _ ->
        read_body_all(conn)

      "application/x-gzip" <> _ ->
        read_body_all(conn)

      "application/octet-stream" <> _ ->
        read_body_all(conn)

      _ ->
        {:error, :bad_request,
         "send the package as multipart field “package”, or as an application/gzip body"}
    end
  end

  defp read_body_all(conn, acc \\ "") do
    case Plug.Conn.read_body(conn, length: Tools.Package.max_compressed() + 1) do
      {:ok, body, _conn} -> {:ok, acc <> body}
      {:more, _partial, _conn} -> {:error, :unprocessable_entity, "the package is over 10 MB"}
      {:error, _} -> {:error, :bad_request, "the package could not be read"}
    end
  end

  defp fetch(user, slug) do
    case Tools.fetch(user, slug) do
      {:ok, tool} -> {:ok, tool}
      _ -> not_found(slug)
    end
  end

  defp not_found(slug), do: {:error, :not_found, "Tool #{inspect(slug)}"}
end
