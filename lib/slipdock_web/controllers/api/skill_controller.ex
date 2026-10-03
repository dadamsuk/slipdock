defmodule SlipdockWeb.API.SkillController do
  @moduledoc """
  Serves the agent skills this app ships (see `Slipdock.Skills`).

  No token is needed, for the same reason `/api/guide` needs none: these
  files say how to talk to the API, and nothing about anybody's boards. An
  agent installs them before it has credentials.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Skills

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, _params), do: json(conn, %{skills: Skills.list()})

  @doc """
  Every skill as one `.tar.gz`, for a client that has `curl` and `tar` and
  nothing else (see `/install.sh`).
  """
  def archive(conn, _params) do
    case Skills.tarball() do
      {:ok, bytes} ->
        conn
        |> put_resp_content_type("application/gzip")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="slipdock-skills.tar.gz")
        )
        |> send_resp(200, bytes)

      _ ->
        {:error, :not_found, "the skills archive"}
    end
  end

  def show(conn, %{"name" => name} = params) do
    file = file_of(params)

    with %{} = skill <- Skills.get(name),
         {:ok, text} <- Skills.read(name, file) do
      json(conn, %{skill: skill, file: file, content: text})
    else
      _ -> {:error, :not_found, "skill #{inspect(name)}"}
    end
  end

  defp file_of(%{"file" => segments}) when is_list(segments), do: Enum.join(segments, "/")
  defp file_of(%{"file" => file}), do: to_string(file)
  defp file_of(_), do: "SKILL.md"
end
