defmodule SlipdockWeb.API.JobMarkController do
  @moduledoc """
  Whether a read marked a runner job (#3520, `Slipdock.Runners.ReadMark`),
  for the `PreToolUse` hook the runner daemon gives the job's agent:

      GET /api/runner/jobs/:id/mark    Authorization: Bearer sdh_…
        → 200 "clear", or 200 "marked <reason>"

  Authenticated with the job's hook key, which the claim gave the daemon
  (`X-Job-Hook-Key`): it reads this one job's mark and nothing else. A
  wrong key, or none, is 401; plain text, as the runner protocol is.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Runners.ReadMark

  def show(conn, %{"id" => id}) do
    case ReadMark.authenticate(id, SlipdockWeb.UserAuth.bearer_token(conn)) do
      {:ok, job} ->
        case ReadMark.state(job) do
          :clear -> reply(conn, 200, "clear")
          {:marked, reason} -> reply(conn, 200, "marked " <> reason)
        end

      {:error, :unauthorized} ->
        reply(conn, 401, "unauthorized: pass the job's hook key as `Authorization: Bearer sdh_…`")
    end
  end

  defp reply(conn, status, text) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, text <> "\n")
  end
end
