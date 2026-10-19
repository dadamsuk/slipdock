defmodule SlipdockCLI.Deploy do
  @moduledoc """
  `slipdock deploy` (#1134): recording a project's deploys from CI, so the
  board can show its delivery metrics.

      slipdock deploy run --env production -- ./deploy.sh "$TAG"

  asks the server for the environment's last deployed sha, reads the
  commits since then from the checkout it runs in (`git log prev..HEAD`),
  records the deploy as started, runs the command, records it succeeded or
  failed from the exit code, and exits with that code. `start` and `finish`
  are the same in two steps, for a pipeline whose deploy isn't one command.

  Everything but `token` uses the board's deploy token,
  `$SLIPDOCK_DEPLOY_TOKEN`, and never the API token: CI holds a secret that
  records deploys and can do nothing else. The board comes from the token.

  The work is done in functions that return values (`record_start/1`,
  `run_command/2`, …) so the tests can see it; `run/3` prints and exits.
  """

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP

  @commands ~w(deploy)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  @max_commits 1000

  # -- Commands ---------------------------------------------------------------

  # Issuing the board's deploy token is the owner's, with their API token.
  def run("deploy", ["token", ref], o) do
    if o[:revoke] do
      HTTP.delete("/boards/#{enc(ref)}/deploy-token")
      |> out(o, fn _ -> IO.puts("deploy token revoked: nothing can record deploys for #{ref}") end)
    else
      HTTP.post("/boards/#{enc(ref)}/deploy-token")
      |> out(o, fn r ->
        IO.puts(r["token"])

        IO.puts(
          :stderr,
          "shown once: keep it as the CI secret SLIPDOCK_DEPLOY_TOKEN (any earlier one stops working)" <>
            if(r["delivery_metrics"],
              do: "",
              else:
                "\nnote: delivery metrics are off for #{ref}: deploys are refused until " <>
                  "`slipdock set-board #{ref} --delivery-metrics`"
            )
        )
      end)
    end
  end

  def run("deploy", ["last"], o) do
    case with_deploy_token(fn -> HTTP.get("/deployments/last", environment: env(o)) end) do
      {:ok, %{"sha" => nil}} = r ->
        out(r, o, fn _ -> IO.puts("no succeeded deploy to #{env(o)} yet") end)

      r ->
        out(r, o, fn %{"deployment" => d} ->
          IO.puts("#{d["sha"]}#{tag_text(d["tag"])}  #{env(o)} · #{d["finished_at"]}")
        end)
    end
  end

  def run("deploy", ["start"], o) do
    case record_start(o) do
      {:ok, %{"deployment" => d} = plan} ->
        if o[:json], do: SlipdockCLI.Render.json(d), else: IO.puts(d["id"])
        describe(plan, :stderr)

      {:ok, plan} ->
        describe(plan, :stdio)
        IO.puts("dry run: recorded nothing")

      {:error, message} ->
        fail(message)
    end
  end

  def run("deploy", ["finish"], o) do
    id = o[:id] || System.get_env("SLIPDOCK_DEPLOY_ID") || fail(no_id())
    status = o[:status] || fail("pass --status succeeded or --status failed")

    case record_finish(id, status) do
      {:ok, d} ->
        IO.puts("deploy ##{d["id"]} #{d["status"]}: #{short(d["sha"])} to #{d["environment"]}")

      {:error, message} ->
        fail(message)
    end
  end

  def run("deploy", ["run" | command], o) do
    if command == [], do: fail("nothing to run: slipdock deploy run --env E -- <command…>")
    {code, _} = deploy_run(o, command)
    System.halt(code)
  end

  def run(cmd, _args, _o), do: bad_usage(cmd)

  # -- The work ---------------------------------------------------------------

  @doc """
  Works out what to record: the environment's last sha from the server, the
  commits since it from the checkout, whether it is a rollback. With
  `--dry-run`, stops there and records nothing. `{:ok, plan}` (with
  `"deployment"` once recorded) or `{:error, message}`.
  """
  def record_start(o) do
    with {:ok, token} <- deploy_token(),
         {:ok, head} <- head_sha(o),
         {:ok, last} <- server_last(token, env(o)),
         {:ok, plan} <- plan(o, head, last) do
      if o[:dry_run] do
        {:ok, plan}
      else
        body =
          compact(%{
            "environment" => env(o),
            "sha" => head,
            "tag" => tag(o),
            "previous_sha" => plan["previous_sha"],
            "commits" => plan["commits"],
            "rollback" => plan["rollback"],
            "source" => "cli"
          })

        case HTTP.with_token(token, fn -> HTTP.post("/deployments", body) end) do
          {:ok, %{"deployment" => d}} -> {:ok, Map.put(plan, "deployment", d)}
          error -> {:error, error_text(error)}
        end
      end
    end
  end

  @doc "Records deploy `id` as `status`: `{:ok, deployment}` or `{:error, message}`."
  def record_finish(id, status) do
    with {:ok, token} <- deploy_token() do
      case HTTP.with_token(token, fn ->
             HTTP.patch("/deployments/#{enc(id)}", %{"status" => status})
           end) do
        {:ok, %{"deployment" => d}} -> {:ok, d}
        error -> {:error, error_text(error)}
      end
    end
  end

  @doc """
  `deploy run`: records the start, runs `command`, records how it ended, and
  returns `{exit_code, deployment_or_nil}`. A deploy is worth more than its
  record, so a server that can't be reached (or refuses) is a warning and the
  command runs anyway; a missing token is not, because that is set up wrong.
  `--dry-run` shows the plan and runs nothing.
  """
  def deploy_run(o, command) do
    case record_start(o) do
      {:error, "missing SLIPDOCK_DEPLOY_TOKEN" <> _ = message} ->
        fail(message)

      {:ok, plan} when not is_map_key(plan, "deployment") ->
        describe(plan, :stdio)

        IO.puts(
          "dry run: recorded nothing and ran nothing (would run: #{Enum.join(command, " ")})"
        )

        {0, nil}

      {:ok, %{"deployment" => d} = plan} ->
        describe(plan, :stderr)
        IO.puts(:stderr, "deploy ##{d["id"]} started: #{short(d["sha"])} to #{d["environment"]}")
        code = run_command(command, o)
        status = if code == 0, do: "succeeded", else: "failed"

        case record_finish(d["id"], status) do
          {:ok, done} ->
            IO.puts(:stderr, "deploy ##{d["id"]} #{status}")
            {code, done}

          {:error, message} ->
            IO.puts(:stderr, "warning: deploy ##{d["id"]} not recorded as #{status}: #{message}")
            {code, d}
        end

      {:error, message} ->
        IO.puts(:stderr, "warning: deploy not recorded: #{message}")
        {run_command(command, o), nil}
    end
  end

  @doc """
  Runs `command` with its output passed through, and returns its exit code.
  One argument with spaces in it (`-- "make deploy"`) is run by `sh -c`.
  """
  def run_command([single], o) do
    if String.contains?(single, " "),
      do: run_command(["sh", "-c", single], o),
      else: exec(single, [], o)
  end

  def run_command([cmd | args], o), do: exec(cmd, args, o)

  defp exec(cmd, args, o) do
    exe =
      if String.contains?(cmd, "/"),
        do: Path.expand(cmd, dir(o)),
        else: System.find_executable(cmd)

    if exe && File.exists?(exe) do
      {_, code} =
        System.cmd(exe, args, cd: dir(o), into: IO.stream(:stdio, :line), stderr_to_stdout: true)

      code
    else
      IO.puts(:stderr, "error: #{cmd}: command not found")
      127
    end
  end

  # -- Git ----------------------------------------------------------------------

  @doc """
  What this deploy covers, from the checkout: `%{"previous_sha", "commits",
  "rollback", "range"}`. The first deploy sends HEAD alone. A previous sha
  that HEAD is an ancestor of is a rollback, with no commits of its own.
  """
  def plan(o, head, last) do
    prev = last["sha"]

    base = %{
      "head" => head,
      "previous_sha" => prev,
      "card_ref_pattern" => last["card_ref_pattern"]
    }

    cond do
      is_nil(prev) ->
        with {:ok, commits} <- log(o, [head, "-1"]),
             do:
               {:ok,
                Map.merge(base, %{"commits" => commits, "rollback" => false, "range" => head})}

      prev == head ->
        {:ok,
         Map.merge(base, %{
           "commits" => [],
           "rollback" => false,
           "range" => "#{short(head)} (redeploy)"
         })}

      true ->
        with :ok <- ensure_history(o, prev) do
          if ancestor?(o, head, prev) do
            {:ok,
             Map.merge(base, %{
               "commits" => [],
               "rollback" => true,
               "range" => "#{short(prev)} → #{short(head)} (rollback)"
             })}
          else
            with {:ok, commits} <- log(o, ["#{prev}..#{head}"]) do
              {:ok,
               Map.merge(base, %{
                 "commits" => commits,
                 "rollback" => false,
                 "range" => "#{short(prev)}..#{short(head)}"
               })}
            end
          end
        end
    end
  end

  @doc """
  Makes sure `sha` is in the checkout. A shallow clone (CI's default) is
  deepened, then unshallowed; if it still isn't there the answer says how
  to fix the checkout. A full clone without it (history rewritten) is fine:
  the deploy is recorded from HEAD alone.
  """
  def ensure_history(o, sha) do
    cond do
      has_commit?(o, sha) ->
        :ok

      shallow?(o) ->
        git(o, ["fetch", "--quiet", "--deepen=500"])
        if has_commit?(o, sha), do: :ok, else: unshallow(o, sha)

      true ->
        :ok
    end
  end

  defp unshallow(o, sha) do
    git(o, ["fetch", "--quiet", "--unshallow"])

    if has_commit?(o, sha),
      do: :ok,
      else:
        {:error,
         "this checkout is shallow and the last deployed commit #{short(sha)} isn't in it. " <>
           "Check out the full history: in GitHub Actions `fetch-depth: 0` on actions/checkout, " <>
           "in GitLab `GIT_DEPTH: 0`, else `git fetch --unshallow`"}
  end

  @doc "Whether the checkout is a shallow clone."
  def shallow?(o), do: match?({"true", 0}, git(o, ["rev-parse", "--is-shallow-repository"]))

  defp has_commit?(o, sha), do: match?({_, 0}, git(o, ["cat-file", "-e", sha <> "^{commit}"]))

  @doc "Whether `a` is an ancestor of `b`: deploying `a` after `b` goes back."
  def ancestor?(o, a, b), do: match?({_, 0}, git(o, ["merge-base", "--is-ancestor", a, b]))

  # Missing history is handled before here; a range git can't read is sent
  # as nothing rather than failing the deploy.
  defp log(o, range) do
    case git(o, ["log", "--max-count=#{@max_commits}", "--format=%H%x1f%cI%x1f%B%x1e" | range]) do
      {out, 0} -> {:ok, parse_log(out)}
      {out, _} -> {:error, "git log failed: #{String.trim(out)}"}
    end
  end

  @doc false
  def parse_log(out) do
    out
    |> String.split("\x1e", trim: true)
    |> Enum.flat_map(fn rec ->
      case String.split(String.trim_leading(rec), "\x1f", parts: 3) do
        [sha, at, message] ->
          [%{"sha" => sha, "committed_at" => at, "message" => String.trim(message)}]

        _ ->
          []
      end
    end)
  end

  defp head_sha(o) do
    case o[:sha] do
      sha when is_binary(sha) and sha != "" ->
        {:ok, String.downcase(sha)}

      _ ->
        case git(o, ["rev-parse", "HEAD"]) do
          {sha, 0} -> {:ok, sha}
          {out, _} -> {:error, "not a git checkout (#{dir(o)}): #{String.trim(out)}"}
        end
    end
  end

  defp git(o, args) do
    case System.find_executable("git") do
      nil ->
        {"git is not installed", 127}

      git ->
        {out, code} = System.cmd(git, ["-C", dir(o) | args], stderr_to_stdout: true)
        {String.trim(out), code}
    end
  end

  # -- Bits -------------------------------------------------------------------------

  defp deploy_token do
    case System.get_env("SLIPDOCK_DEPLOY_TOKEN") do
      t when is_binary(t) and t != "" ->
        {:ok, String.trim(t)}

      _ ->
        {:error,
         "missing SLIPDOCK_DEPLOY_TOKEN: the board's deploy token (`slipdock deploy token <board>` " <>
           "issues one), kept as a CI secret. SLIPDOCK_URL says which server."}
    end
  end

  defp with_deploy_token(fun) do
    case deploy_token() do
      {:ok, token} -> HTTP.with_token(token, fun)
      {:error, message} -> fail(message)
    end
  end

  defp server_last(token, environment) do
    case HTTP.with_token(token, fn -> HTTP.get("/deployments/last", environment: environment) end) do
      {:ok, last} -> {:ok, last}
      error -> {:error, error_text(error)}
    end
  end

  defp error_text({:error, :connect, reason}),
    do: "could not reach #{HTTP.base_url()} (#{inspect(reason)})"

  defp error_text({:error, 401, _}),
    do: "the server didn't accept SLIPDOCK_DEPLOY_TOKEN (revoked, or for another server?)"

  defp error_text({:error, status, %{"message" => m}}), do: "#{m} (HTTP #{status})"

  defp error_text({:error, status, %{"error" => e} = d}),
    do: "#{e}#{if d["details"], do: " " <> inspect(d["details"]), else: ""} (HTTP #{status})"

  defp error_text({:error, status, body}), do: "HTTP #{status}: #{inspect(body)}"

  # The range and the cards it names, the way the board will read them.
  defp describe(plan, device) do
    commits = plan["commits"] || []
    regex = card_regex(plan["card_ref_pattern"])
    cards = commits |> Enum.flat_map(&card_refs(regex, &1["message"])) |> Enum.uniq()

    IO.puts(
      device,
      "range: #{plan["range"]} · #{length(commits)} commit#{if length(commits) == 1, do: "", else: "s"}"
    )

    if plan["rollback"],
      do:
        IO.puts(
          device,
          "rollback: #{short(plan["head"])} is behind the last deploy #{short(plan["previous_sha"])}"
        )

    IO.puts(
      device,
      if(cards == [],
        do: "cards: none named",
        else: "cards: " <> Enum.map_join(cards, " ", &"##{&1}")
      )
    )
  end

  @doc false
  def card_regex(pattern) when is_binary(pattern) and pattern != "" do
    case Regex.compile(pattern) do
      {:ok, r} -> r
      _ -> ~r/#(\d+)\b/
    end
  end

  def card_regex(_), do: ~r/#(\d+)\b/

  @doc false
  def card_refs(regex, message) do
    regex
    |> Regex.scan(to_string(message), capture: :all_but_first)
    |> Enum.flat_map(fn [id | _] -> [id] end)
  end

  defp env(o), do: o[:env] || "production"
  defp dir(o), do: o[:dir] || "."
  defp tag(o), do: o |> Keyword.get_values(:tag) |> List.last()
  defp tag_text(nil), do: ""
  defp tag_text(t), do: " (#{t})"
  defp short(nil), do: "-"
  defp short(sha), do: String.slice(sha, 0, 7)

  defp no_id,
    do: "pass --id N (what `slipdock deploy start` printed), or set SLIPDOCK_DEPLOY_ID"
end
