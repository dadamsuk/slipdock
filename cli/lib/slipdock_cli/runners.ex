defmodule SlipdockCLI.Runners do
  @moduledoc false

  # Runners on the user's own machines, and the jobs automation rules send
  # them (the `runner` action). Making and revoking runners is the board
  # owner's; anybody who can edit a card can cancel its jobs.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(runner runners runner-stats jobs job job-log cancel-job claim-job job-progress finish-job pause resume)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("runners", [ref], o), do: run("runner", ["ls", ref], o)

  # How the board's runners are doing (#1187), for anyone who can read it.
  def run("runner-stats", [ref], o) do
    HTTP.get("/boards/#{enc(ref)}/runner_stats", days: o[:days])
    |> out(o, &Render.runner_stats(&1["runner_stats"]))
  end

  def run("runner", ["ls", ref], o) do
    HTTP.get("/boards/#{enc(ref)}/runners") |> out(o, &Render.runners(&1["runners"]))
  end

  # The same wizard as the board's Automations panel: a scenario and its
  # options in, the steps to follow out. The shell and PowerShell runners'
  # scenarios (server, windows) were retired for the daemon (#2582), and
  # the server refuses them saying so.
  def run("runner", ["new", ref | _name], o) do
    scenario = o[:scenario] || "daemon"

    if o[:top] && !o[:column],
      do: fail("--top goes with --column LIST: the list whose top card it sends")

    body = setup_answers(scenario, o)

    HTTP.post("/boards/#{enc(ref)}/runners/setup", body) |> out(o, &print_setup/1)
  end

  # One runner and everything known about it, with its latest jobs.
  def run("runner", ["show", ref, runner], o) do
    HTTP.get("/boards/#{enc(ref)}/runners/#{enc(runner)}", limit: o[:limit])
    |> out(o, &Render.runner(&1["runner"]))
  end

  # A runner with a token of its own ran a retired script (#2582): its steps
  # are the move onto a machine. Its answers can no longer be changed.
  def run("runner", ["setup", ref, runner], o) do
    HTTP.get("/boards/#{enc(ref)}/runners/#{enc(runner)}/setup")
    |> out(o, &Render.runner_setup(&1["setup"]))
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
        "usage: slipdock runner ls <board> | show <board> <runner> | new <board> --pool P [--scenario daemon|loop|cloud|chatgpt] | setup <board> <runner> | token <board> <runner> | rm <board> <runner>"
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

  def run("job", [id], o) do
    cond do
      o[:keep_log] -> keep_log(id, o)
      o[:follow] -> run("job-log", [id], o)
      true -> HTTP.get("/jobs/#{enc(id)}") |> out(o, &Render.job(&1["job"]))
    end
  end

  # A job's live log (#1871), one line per message, tool call or result.
  # With --follow it keeps reading, every --interval seconds (10), until the
  # job has ended and the last of its log is printed.
  def run("job-log", [id], o) do
    every =
      if is_integer(o[:interval]) and o[:interval] >= 0, do: o[:interval] * 1000, else: 10_000

    follow_log(id, 0, o, o[:poll_ms] || every)
  end

  def run("job-log", _, _o), do: fail("usage: slipdock job-log <id> [--follow] [--interval SECS]")

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

      %{"job" => nil, "held" => reason} ->
        IO.puts("nothing queued to take: #{reason}")

      %{"job" => nil} ->
        IO.puts("nothing queued")

      %{"job" => j} = r ->
        IO.puts(
          "claimed job ##{j["id"]} (#{j["kind"]}) for card ##{j["card_id"]} #{j["card_url"]}"
        )

        IO.puts(
          "report with `slipdock job-progress #{j["id"]}` between steps (lease #{r["lease_seconds"]}s); end with `slipdock finish-job #{j["id"]} --status done`"
        )

        # The card's profile (#1953), with profiles on.
        if p = j["profile"], do: IO.puts("profile: #{p}")
        if w = r["wait"], do: IO.puts("answered: " <> Render.wait_answer(w))
        if h = r["handoff"], do: IO.puts("left off: " <> (h["next_step"] || ""))

        IO.puts("\n" <> (j["prompt"] || ""))
    end)
  end

  # The brake (#1116): hold the board's tree, or one pool on it, with a
  # reason. The owner's; resuming is a person's, so the server refuses it
  # from a CLI running under an agent (the agent header, see HTTP).
  def run("pause", [ref], o) do
    reason = o[:reason] || fail("pass --reason \"…\": say why it is paused")

    HTTP.post("/boards/#{enc(ref)}/pause", compact(%{"pool" => o[:pool], "reason" => reason}))
    |> out(o, fn %{"pause" => p} -> IO.puts("#{p["scope"]} #{p["line"]}") end)
  end

  def run("resume", [ref], o) do
    HTTP.delete("/boards/#{enc(ref)}/pause", Enum.reject([pool: o[:pool]], &is_nil(elem(&1, 1))))
    |> out(o, fn %{"pause" => p} -> IO.puts("resumed #{p["scope"]}") end)
  end

  # Without an id, the runner job this agent runs under (#1668): a verify
  # job's agent says what it is doing with `--step`, which shows on the job
  # and not on the card.
  def run("job-progress", [], o) do
    case String.trim(System.get_env("SLIPDOCK_JOB_ID") || "") do
      "" -> fail("job-progress needs a job id, or $SLIPDOCK_JOB_ID set by a runner")
      id -> run("job-progress", [id], o)
    end
  end

  # `--message -` pipes the note in, so a Markdown comment can keep its lines.
  def run("job-progress", [id], o) do
    note =
      case o[:message] do
        "-" -> with(t when is_binary(t) <- IO.read(:stdio, :eof), do: t, else: (_ -> nil))
        m -> m
      end

    HTTP.post("/jobs/#{enc(id)}/progress", compact(%{"note" => note, "step" => o[:step]}))
    |> out(o, fn %{"status" => status} -> IO.puts(status) end)
  end

  def run("finish-job", [id], o) do
    body =
      compact(%{
        "outcome" => o[:status] || "done",
        "summary" => o[:summary],
        "wait" => finish_wait(o)
      })

    HTTP.post("/jobs/#{enc(id)}/finish", body)
    |> out(o, fn
      %{"job" => j, "wait" => %{} = w} ->
        IO.puts("job ##{j["id"]} #{j["status"]}: ##{j["card_id"]} " <> Render.wait_line(w))

      %{"job" => j} ->
        IO.puts("job ##{j["id"]} #{j["status"]}")
    end)
  end

  def run(cmd, _args, _o), do: bad_usage(cmd)

  # The wizard's answers among the options given, by the names the server uses.
  # The wizard's answers, as `runner new` sends them.
  defp setup_answers(scenario, o) do
    compact(%{
      "scenario" => scenario,
      "verbosity" => o[:verbosity],
      "instructions" => o[:instructions],
      "before_job" => o[:before_job],
      "after_job" => o[:after_job],
      "hooks" => o[:hooks],
      "in_progress" => o[:in_progress],
      "assign" => o[:assign],
      "commit" => o[:commit],
      "push" => o[:push],
      "move_done" => o[:move_done],
      "complete" => o[:complete],
      "percent_100" => o[:percent_100],
      "pool" => o[:pool],
      "kind" => o[:kind] |> List.wrap() |> List.last(),
      "cwd" => o[:cwd],
      "permission_mode" => o[:permission_mode],
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
  end

  # What `runner new` made, then the steps.
  defp print_setup(r) do
    if r["automation"], do: IO.puts("added the rule “#{r["automation"]["name"]}”")

    if r["alert_automation"],
      do: IO.puts("added the rule “#{r["alert_automation"]["name"]}”")

    if r["enrolment_key"],
      do: IO.puts("its enrolment key is in the steps below, shown this once")

    IO.puts("")
    Render.runner_setup(r["setup"])
  end

  # `--status waiting` asks a person: what is needed, from whom, the choices.
  defp finish_wait(o) do
    case {o[:status], o[:needs]} do
      {"waiting", nil} ->
        fail(~s(--status waiting needs the question: --needs "Which region?"))

      {"waiting", needs} ->
        compact(%{
          "needs" => needs,
          "on" => o[:wait_on],
          "choices" => nonempty(Keyword.get_values(o, :choice))
        })

      {_, nil} ->
        nil

      {_, _} ->
        fail("--needs goes with --status waiting")
    end
  end

  defp follow_log(id, from, o, every) do
    case HTTP.get("/jobs/#{enc(id)}/log", from: from) do
      {:ok, %{"entries" => entries, "next" => next, "job" => job}} ->
        print_entries(entries, o)
        follow_on(job, id, next, o, every)

      other ->
        dropped(other, id, from, o, every)
    end
  end

  # A dropped connection mid-follow is tried again; the log waits on the server.
  defp dropped({:error, :connect, _}, id, from, o, every) when from > 0,
    do: follow_on(%{"open" => true}, id, from, o, every)

  defp dropped(other, _id, _from, o, _every), do: out(other, o, fn _ -> :ok end)

  defp print_entries(entries, o) do
    if o[:json],
      do: Enum.each(entries, &IO.puts(HTTP.encode(&1))),
      else: Enum.each(entries, &IO.puts(&1["line"]))
  end

  # Without --follow, once is enough; with it, read again until the job ends.
  defp follow_on(job, id, next, o, every) do
    cond do
      !o[:follow] ->
        :ok

      job["open"] != true ->
        unless o[:json], do: IO.puts(:stderr, "job ##{job["id"]} #{job["status"]}")

      true ->
        Process.sleep(every)
        follow_log(id, next, o, every)
    end
  end

  # Keep this log (#1872): the ended job's log as a page in the card's folder.
  defp keep_log(id, o) do
    HTTP.post("/jobs/#{enc(id)}/keep", %{})
    |> out(o, fn %{"page" => p} ->
      IO.puts("kept job ##{id}'s log as #{p["code"]} #{p["title"]}  #{p["url"] || ""}")
    end)
  end
end
