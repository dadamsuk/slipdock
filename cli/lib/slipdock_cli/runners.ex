defmodule SlipdockCLI.Runners do
  @moduledoc false

  # Runners on the user's own machines, and the jobs automation rules send
  # them (the `runner` action). Making and revoking runners is the board
  # owner's; anybody who can edit a card can cancel its jobs.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(runner runners jobs job cancel-job claim-job job-progress finish-job)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("runners", [ref], o), do: run("runner", ["ls", ref], o)

  def run("runner", ["ls", ref], o) do
    HTTP.get("/boards/#{enc(ref)}/runners") |> out(o, &Render.runners(&1["runners"]))
  end

  # The same wizard as the board's Automations panel: a scenario and its
  # options in, the steps to follow out — and for a runner of its own, the
  # token, once.
  def run("runner", ["new", ref | name], o) do
    scenario = o[:scenario] || "server"

    if scenario in ~w(server windows) and !o[:pool],
      do: fail("pass --pool P: the pool this runner takes jobs for")

    if o[:top] && !o[:column],
      do: fail("--top goes with --column LIST: the list whose top card it sends")

    body =
      compact(%{
        "scenario" => scenario,
        "verbosity" => o[:verbosity],
        "instructions" => o[:instructions],
        "before_job" => o[:before_job],
        "after_job" => o[:after_job],
        "hooks" => o[:hooks],
        "slipdock_tools" => o[:slipdock_tools],
        "mcp_servers" => o[:mcp_servers],
        "name" => nonblank(Enum.join(name, " ")),
        "pool" => o[:pool],
        "agent" => o[:agent],
        "kind" => o[:kind] |> List.wrap() |> List.last(),
        "command" => o[:command],
        "cwd" => o[:cwd],
        "permission_mode" => o[:permission_mode],
        "timeout" => o[:timeout],
        "service" => o[:service],
        "where" => o[:where],
        "repo" => o[:repo],
        "column" => o[:column] |> List.wrap() |> List.last(),
        # The list's top card, one at a time, rather than every card arriving.
        "feed" => if(o[:top], do: "top"),
        "wait" =>
          case o[:wait_while_doing] do
            true -> "yes"
            false -> "no"
            nil -> nil
          end,
        "requeue" => o[:requeue_stuck],
        "alert" => if(o[:alert], do: "yes")
      })

    HTTP.post("/boards/#{enc(ref)}/runners/setup", body)
    |> out(o, fn r ->
      if r["runner"],
        do:
          IO.puts(
            "made runner ##{r["runner"]["id"]} #{r["runner"]["name"]} for pool #{r["runner"]["pool"]}"
          )

      if r["automation"], do: IO.puts("added the rule “#{r["automation"]["name"]}”")

      if r["alert_automation"],
        do: IO.puts("added the rule “#{r["alert_automation"]["name"]}”")

      if r["token"],
        do: IO.puts("its token is in the steps below, shown this once — keep it on that machine")

      IO.puts("")
      Render.runner_setup(r["setup"])
    end)
  end

  def run("runner", ["setup", ref, runner], o) do
    answers = answers(o)

    cond do
      # The prompt that has Claude write the runner's hooks, as plain text to
      # paste (or pipe) into Claude Code on that machine.
      o[:hook_prompt] ->
        HTTP.get("/boards/#{enc(ref)}/runners/#{enc(runner)}/hook-prompt")
        |> out(o, &IO.write(&1["prompt"]))

      answers == %{} ->
        HTTP.get("/boards/#{enc(ref)}/runners/#{enc(runner)}/setup")
        |> out(o, &Render.runner_setup(&1["setup"]))

      true ->
        # New answers: saved on the runner, and what changes printed first.
        HTTP.put("/boards/#{enc(ref)}/runners/#{enc(runner)}/setup", answers)
        |> out(o, fn r ->
          Render.runner_diff(r["diff"])
          Render.runner_setup(r["setup"])
        end)
    end
  end

  def run("runner", ["token", ref, runner], o) do
    HTTP.post("/boards/#{enc(ref)}/runners/#{enc(runner)}/token", %{})
    |> out(o, fn r ->
      IO.puts("new token for #{r["runner"]["name"]}: the old one no longer works\n")
      Render.runner_setup(r["setup"])
    end)
  end

  def run("runner", ["rm", ref, runner], o) do
    HTTP.delete("/boards/#{enc(ref)}/runners/#{enc(runner)}")
    |> out(o, fn _ -> IO.puts("revoked runner #{runner}: its token no longer works") end)
  end

  def run("runner", _, _o),
    do:
      fail(
        "usage: slipdock runner ls <board> | new <board> <name> --pool P | rm <board> <runner>"
      )

  def run("jobs", [], o) do
    case o[:card] do
      nil -> fail("pass a board (`slipdock jobs <board>`) or --card ID")
      card -> HTTP.get("/cards/#{enc(card)}/jobs") |> out(o, &Render.jobs(&1["jobs"]))
    end
  end

  def run("jobs", [ref], o) do
    HTTP.get("/boards/#{enc(ref)}/jobs", status: o[:status], limit: o[:limit])
    |> out(o, &Render.jobs(&1["jobs"]))
  end

  def run("job", [id], o), do: HTTP.get("/jobs/#{enc(id)}") |> out(o, &Render.job(&1["job"]))

  def run("cancel-job", [id], o) do
    HTTP.post("/jobs/#{enc(id)}/cancel", %{})
    |> out(o, fn %{"job" => j} ->
      if j["status"] == "cancelled",
        do: IO.puts("cancelled job ##{j["id"]}"),
        else: IO.puts("asked the runner to stop job ##{j["id"]} (it hears on its next heartbeat)")
    end)
  end

  # Taking jobs as this session, with this token: the same queue the runners
  # on people's machines take from, so a /loop never races one for a card.

  def run("claim-job", [ref], o) do
    pool = o[:pool] || fail("pass --pool P: the pool to take a job from")

    HTTP.post("/boards/#{enc(ref)}/jobs/claim", %{"pool" => pool})
    |> out(o, fn
      %{"job" => nil, "waiting" => %{"job" => id, "reason" => reason}} ->
        IO.puts("nothing queued to take: job ##{id} waits while #{reason}")

      %{"job" => nil} ->
        IO.puts("nothing queued")

      %{"job" => j} = r ->
        IO.puts(
          "claimed job ##{j["id"]} (#{j["kind"]}) for card ##{j["card_id"]} #{j["card_url"]}"
        )

        IO.puts(
          "report with `slipdock job-progress #{j["id"]}` between steps (lease #{r["lease_seconds"]}s); end with `slipdock finish-job #{j["id"]} --status done`"
        )

        IO.puts("\n" <> (j["prompt"] || ""))
    end)
  end

  def run("job-progress", [id], o) do
    HTTP.post("/jobs/#{enc(id)}/progress", compact(%{"note" => o[:message]}))
    |> out(o, fn %{"status" => status} -> IO.puts(status) end)
  end

  def run("finish-job", [id], o) do
    body = compact(%{"outcome" => o[:status] || "done", "summary" => o[:summary]})

    HTTP.post("/jobs/#{enc(id)}/finish", body)
    |> out(o, fn %{"job" => j} -> IO.puts("job ##{j["id"]} #{j["status"]}") end)
  end

  def run(cmd, _args, _o), do: bad_usage(cmd)

  # The wizard's answers among the options given, by the names the server uses.
  defp answers(o) do
    compact(%{
      "agent" => o[:agent],
      "kind" => o[:kind] |> List.wrap() |> List.last(),
      "command" => o[:command],
      "cwd" => o[:cwd],
      "permission_mode" => o[:permission_mode],
      "timeout" => o[:timeout],
      "service" => o[:service],
      "where" => o[:where],
      "repo" => o[:repo],
      "verbosity" => o[:verbosity],
      "instructions" => o[:instructions],
      "before_job" => o[:before_job],
      "after_job" => o[:after_job],
      "hooks" => o[:hooks],
      "slipdock_tools" => o[:slipdock_tools],
      "mcp_servers" => o[:mcp_servers]
    })
  end
end
