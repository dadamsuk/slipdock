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

  @doc "Every skill of the Tool as one `.tar.gz`, laid out for a skills directory."
  def skills_archive(conn, %{"slug" => slug} = params) do
    with {:ok, version} <- version(conn, slug, params),
         {:ok, bytes} <- Tools.skills_tarball(version) do
      send_file_bytes(conn, "application/gzip", "#{slug}-skills.tar.gz", bytes)
    end
  end

  @doc """
  The whole package as a `.tar.gz`, every file at its path in it: what was
  published, ready to read, change and publish again.
  """
  def package(conn, %{"slug" => slug} = params) do
    with {:ok, version} <- version(conn, slug, params),
         {:ok, bytes} <- Tools.package_tarball(version) do
      send_file_bytes(conn, "application/gzip", Tools.package_filename(version), bytes)
    end
  end

  @doc "One skill as the zip claude.ai's skill upload takes."
  def claude_zip(conn, %{"slug" => slug, "skill" => skill} = params) do
    with {:ok, version} <- version(conn, slug, params),
         {:ok, bytes} <- skill_or_404(Tools.claude_zip(version, skill), skill) do
      send_file_bytes(conn, "application/zip", "#{skill}.zip", bytes)
    end
  end

  @doc "One skill as the zip ChatGPT's skill upload takes."
  def chatgpt_zip(conn, %{"slug" => slug, "skill" => skill} = params) do
    base_url = SlipdockWeb.BaseURL.from_conn(conn)

    with {:ok, version} <- version(conn, slug, params),
         {:ok, bytes} <- skill_or_404(Tools.chatgpt_zip(version, skill, base_url), skill) do
      send_file_bytes(conn, "application/zip", "#{skill}.zip", bytes)
    end
  end

  @doc """
  One file of the Tool by its path in the package (`skills/<skill>/SKILL.md`,
  `files/build.py`, `README.md`), from the latest version the caller can
  see unless `version` names one. Text comes back as `text/plain`, anything
  else as a download; either way the headers say which version and sha it
  is, so a skill fetching its procedure at run time knows what it ran.
  """
  def file(conn, %{"slug" => slug, "path" => parts} = params) do
    path = Enum.join(parts, "/")

    with {:ok, version} <- version(conn, slug, params),
         %Tools.File{} = file <-
           Tools.file(version, path) ||
             {:error, :not_found, "#{path} in #{slug} #{version.version}"} do
      conn
      |> put_resp_header("x-tool-version", version.version)
      |> put_resp_header("etag", ~s("#{file.sha256}"))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_tool_file(file)
    end
  end

  # Text is shown as text whatever it is (Markdown, Python, JSON), so it can
  # never run as a page; anything else is a download.
  defp send_tool_file(conn, file) do
    if String.valid?(file.content) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, file.content)
    else
      send_file_bytes(conn, "application/octet-stream", Path.basename(file.path), file.content)
    end
  end

  defp version(conn, slug, params) do
    user = conn.assigns.current_user

    with {:ok, tool} <- fetch(user, slug) do
      case Tools.visible_version(user, tool, params["version"]) do
        nil -> not_found(slug)
        version -> {:ok, version}
      end
    end
  end

  defp skill_or_404({:ok, bytes}, _skill), do: {:ok, bytes}
  defp skill_or_404(_, skill), do: {:error, :not_found, "skill #{inspect(skill)}"}

  defp send_file_bytes(conn, type, filename, bytes) do
    conn
    |> put_resp_content_type(type, nil)
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, bytes)
  end

  @doc """
  The owner asks for a version (the latest, or `version`) to be listed for
  everyone on the server. An admin approves it before it shows.
  """
  def request_listing(conn, %{"slug" => slug} = params) do
    user = conn.assigns.current_user

    with {:ok, version} <- version(conn, slug, params) do
      case Tools.request_listing(user, version) do
        {:ok, version} ->
          json(conn, %{
            tool: ToolJSON.show(Tools.Tool |> Slipdock.Repo.get!(version.tool_id), version, user)
          })

        {:error, message} ->
          {:error, :forbidden, message}
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
