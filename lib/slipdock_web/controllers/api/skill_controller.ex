defmodule SlipdockWeb.API.SkillController do
  @moduledoc """
  Serves the agent skills this app ships (see `Slipdock.Skills`).

  No token is needed, for the same reason `/api/guide` needs none: these
  files say how to talk to the API, and nothing about anybody's boards. An
  agent installs them before it has credentials.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Skills
  alias Slipdock.Skills.ChatGPT

  action_fallback SlipdockWeb.API.FallbackController

  # Each skill says where its ChatGPT version is, or null when there is none,
  # so a client asks the server rather than knowing which ones are left out.
  def index(conn, _params) do
    skills =
      Enum.map(Skills.list(), fn skill ->
        zip = if ChatGPT.offered?(skill.name), do: "/api/skills/#{skill.name}/chatgpt.zip"
        Map.put(skill, :chatgpt_zip, zip)
      end)

    json(conn, %{skills: skills})
  end

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

  @doc """
  One skill as ChatGPT takes it: a `.zip` with the skill's folder in it, the
  CLI commands mapped onto the MCP connector (see `Slipdock.Skills.ChatGPT`).
  """
  def chatgpt(conn, %{"name" => name}) do
    case ChatGPT.zip(name, SlipdockWeb.BaseURL.from_conn(conn)) do
      {:ok, bytes} ->
        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}.zip"))
        |> send_resp(200, bytes)

      _ ->
        {:error, :not_found, "a ChatGPT version of skill #{inspect(name)}"}
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
