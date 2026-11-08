defmodule Slipdock.SkillRegistryStub do
  @moduledoc """
  A fake GitHub, and any other web server, for the skills registry's fetches
  (`Slipdock.SkillRegistry.Fetch`), through `Req.Test`. Nothing leaves the
  machine.

      SkillRegistryStub.start(%{
        "octo/skills" => %{files: %{"grill/SKILL.md" => "---\\nname: grill\\n---\\n…"}}
      })

  A repository is `%{files: %{path => body}}`, plus optionally `licence`
  (an SPDX id), `sha`, `default_branch`, `truncated`. A key with no `/` in a
  leading position — a full path like `"/skills/SKILL.md"` — is a plain file
  any other host serves, either a body or `%{body:, etag:, status:}`.
  `put/2` changes what is served, so a refresh can find something new.
  Every request is recorded; `requests/0` gives their paths.

  Egress pins each request to the address it checked, so every host is the
  stub's public address here and the stub tells them apart by path, as
  GitHub's API (`/repos/…`), its raw files (`/<owner>/<repo>/<sha>/<path>`)
  and plain files do.
  """

  @sha "0123456789abcdef0123456789abcdef01234567"

  def sha, do: @sha

  @doc "Routes the registry's requests here for this test."
  def start(world) do
    {:ok, agent} = Agent.start_link(fn -> %{world: world, requests: []} end)
    Process.put(__MODULE__, agent)

    Slipdock.TestConfig.put(:skill_registry,
      req_options: [plug: {Req.Test, Slipdock.SkillRegistry}]
    )

    Req.Test.stub(Slipdock.SkillRegistry, fn conn -> serve(agent, conn) end)
    agent
  end

  @doc "Replaces (or adds) what one key serves."
  def put(key, value), do: Agent.update(agent(), &put_in(&1, [:world, key], value))

  @doc "The paths requested so far, in order."
  def requests, do: Agent.get(agent(), &Enum.reverse(&1.requests))

  defp agent, do: Process.get(__MODULE__)

  defp serve(agent, conn) do
    path = conn.request_path
    world = Agent.get_and_update(agent, &{&1.world, %{&1 | requests: [path | &1.requests]}})

    case route(world, path, conn.query_string) do
      {:json, data} -> Req.Test.json(conn, data)
      {:text, body} -> Plug.Conn.send_resp(conn, 200, body)
      {:file, %{} = file} -> file(conn, file)
      {:file, body} -> Plug.Conn.send_resp(conn, 200, body)
      :not_found -> Plug.Conn.send_resp(conn, 404, "Not Found")
    end
  end

  defp file(conn, file) do
    conn =
      if file[:etag], do: Plug.Conn.put_resp_header(conn, "etag", file.etag), else: conn

    Plug.Conn.send_resp(conn, file[:status] || 200, file[:body] || "")
  end

  defp route(world, path, query) do
    case Map.fetch(world, path) do
      {:ok, file} ->
        {:file, file}

      :error ->
        path |> String.split("/", trim: true) |> Enum.map(&URI.decode/1) |> github(world, query)
    end
  end

  defp github(["repos", owner, repo], world, _query) do
    with {:ok, r} <- repo(world, owner, repo) do
      licence = if r[:licence], do: %{"spdx_id" => r.licence}, else: nil

      {:json,
       %{
         "full_name" => "#{owner}/#{repo}",
         "default_branch" => r[:default_branch] || "main",
         "license" => licence
       }}
    end
  end

  defp github(["repos", owner, repo, "commits", _ref], world, _query) do
    with {:ok, r} <- repo(world, owner, repo), do: {:text, r[:sha] || @sha}
  end

  defp github(["repos", owner, repo, "git", "trees", _sha], world, _query) do
    with {:ok, r} <- repo(world, owner, repo) do
      tree =
        for {path, body} <- r.files,
            do: %{"path" => path, "type" => "blob", "size" => byte_size(body_of(body))}

      {:json, %{"tree" => tree, "truncated" => r[:truncated] == true}}
    end
  end

  defp github([owner, repo, _sha | path], world, _query) when path != [] do
    with {:ok, r} <- repo(world, owner, repo),
         {:ok, body} <- Map.fetch(r.files, Enum.join(path, "/")) do
      {:file, body}
    else
      _ -> :not_found
    end
  end

  defp github(_segments, _world, _query), do: :not_found

  defp repo(world, owner, repo) do
    case Map.fetch(world, "#{owner}/#{repo}") do
      {:ok, r} -> {:ok, r}
      :error -> :not_found
    end
  end

  defp body_of(%{body: body}), do: body
  defp body_of(body), do: body
end
