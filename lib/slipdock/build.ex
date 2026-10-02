defmodule Slipdock.Build do
  @moduledoc """
  Which build is actually running.

  Both values are frozen at compile time, which is the point: an admin looking
  at a server that is behaving oddly wants to know what came out of the
  compiler, not what `git` says in whatever directory the release happens to
  sit next to now.

  In a container there is no `.git` to ask, so the Dockerfile passes the hash
  in as `SLIPDOCK_GIT_SHA`. Failing both, the hash is `unknown` — honest, and
  better than a number that is quietly wrong.
  """

  @timestamp DateTime.utc_now() |> DateTime.truncate(:second)

  @sha (case System.get_env("SLIPDOCK_GIT_SHA") do
          sha when is_binary(sha) and sha != "" ->
            String.trim(sha)

          _ ->
            case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
              {out, 0} -> String.trim(out)
              _ -> "unknown"
            end
        end)

  @dirty? (case System.get_env("SLIPDOCK_GIT_SHA") do
             sha when is_binary(sha) and sha != "" ->
               false

             _ ->
               case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
                 {out, 0} -> String.trim(out) != ""
                 _ -> false
               end
           end)

  @version Mix.Project.config()[:version]

  @doc "When this build was compiled, UTC."
  def timestamp, do: @timestamp

  @doc "The full commit hash this build was compiled from, or `\"unknown\"`."
  def sha, do: @sha

  @doc "The first seven characters of `sha/0`, for showing to people."
  def short_sha, do: String.slice(@sha, 0, 7)

  @doc "True when there were uncommitted changes at compile time."
  def dirty?, do: @dirty?

  @doc "The release version from `mix.exs`."
  def version, do: @version

  @doc """
  The build time as a person reads it, rather than the ISO8601 that templates
  would otherwise produce for a `DateTime`.
  """
  def built_at_string, do: Calendar.strftime(@timestamp, "%Y-%m-%d %H:%M:%S")

  @doc "Everything at once, for the API and the CLI."
  def info do
    %{
      version: @version,
      git_sha: @sha,
      git_short_sha: short_sha(),
      git_dirty: @dirty?,
      built_at: @timestamp
    }
  end
end
