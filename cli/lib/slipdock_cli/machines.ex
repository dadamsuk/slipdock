defmodule SlipdockCLI.Machines do
  @moduledoc false

  # Machines running the runner daemon (#2570): the account's own, listed,
  # shown and revoked; a machine's enrolment looked up, approved or refused
  # by the code `slipdock-runner init` shows (as the approval page does);
  # and the one-time enrolment keys for a machine with nobody at its screen.
  # A machine's runners (#2572): added, changed, paused, resumed and removed,
  # each a typed config the machine checks against its own ceiling; and
  # `update`, asking its daemon to look for a newer release now. A runner's
  # probe (#2580): sent, and with --wait followed until it ends, green or
  # red with its log; `show` gives each runner's latest.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(machines machine)

  @usage "usage: slipdock machines | machine show|revoke|update|setup-prompt <id> | " <>
           "machine enrolment <code> | machine approve <code> <board>... | " <>
           "machine refuse <code> | machine enrol-key <board>... [--label L] | " <>
           "machine add-runner <id> <board> --pool P --dir D [config] | " <>
           "machine set-runner <id> <runner> [config] | " <>
           "machine pause-runner|resume-runner|rm-runner <id> <runner> | " <>
           "machine probe <id> <runner> [--wait]"

  # The config switches, as the server's field names.
  @config ~w(agent dir permission_mode timeout_minutes model executor verbosity instructions
             before_hook after_hook probe_hook)a

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("machines", [], o), do: run("machine", ["ls"], o)

  def run("machine", args, o) do
    case plan(args, o) do
      {:ok, :get, path, render} -> HTTP.get(path) |> out(o, render)
      {:ok, :delete, path, render} -> HTTP.delete(path) |> out(o, render)
      {:ok, :post, path, body, render} -> HTTP.post(path, body) |> out(o, render)
      {:ok, :patch, path, body, render} -> HTTP.patch(path, body) |> out(o, render)
      {:ok, :probe_wait, path} -> probe_and_wait(path, o)
      {:error, usage} -> fail(usage)
    end
  end

  def run(_cmd, _args, _o), do: fail(@usage)

  @doc false
  # What each `machine …` sends, and how its answer is shown; anything else
  # is the usage (a refusal halts, so the tests take it as this value).
  def plan(["ls"], _o), do: {:ok, :get, "/machines", &listing/1}

  def plan(["show", id], _o), do: {:ok, :get, "/machines/#{enc(id)}", &show(&1["machine"])}

  def plan(["revoke", id], _o) do
    {:ok, :delete, "/machines/#{enc(id)}",
     fn %{"machine" => m} ->
       IO.puts("revoked machine ##{m["id"]} #{m["name"]}: its key no longer works")
     end}
  end

  def plan(["enrolment", code], _o),
    do: {:ok, :get, "/machines/enrolment?user_code=#{enc(code)}", &enrolment(&1["enrolment"])}

  def plan(["approve", code | boards], _o) when boards != [] do
    {:ok, :post, "/machines/enrolment/approve", %{"user_code" => code, "boards" => boards},
     fn %{"enrolment" => e} ->
       IO.puts("approved #{e["hostname"]}: it collects its machine key within a few seconds")
     end}
  end

  def plan(["refuse", code], _o) do
    {:ok, :post, "/machines/enrolment/refuse", %{"user_code" => code},
     fn %{"enrolment" => e} -> IO.puts("refused #{e["hostname"]}: the machine has been told") end}
  end

  def plan(["enrol-key" | boards], o) when boards != [] do
    {:ok, :post, "/machines/enrolment-keys", compact(%{"boards" => boards, "label" => o[:label]}),
     &key/1}
  end

  def plan(["update", id], _o) do
    {:ok, :post, "/machines/#{enc(id)}/update", %{},
     fn %{"machine" => m} ->
       IO.puts("asked #{m["name"]} to update now: it looks for a newer signed release at once")
     end}
  end

  # Set up this machine with Claude (#2579): the prompt alone, to pipe or
  # paste into Claude Code on the machine.
  def plan(["setup-prompt", id], _o),
    do: {:ok, :get, "/machines/#{enc(id)}/setup-prompt", &IO.write(&1["prompt"])}

  def plan(["add-runner", id, board], o) do
    if o[:pool] && o[:dir] do
      body =
        compact(%{
          "board" => board,
          "pool" => o[:pool],
          "name" => o[:name],
          "config" => config(o)
        })

      {:ok, :post, "/machines/#{enc(id)}/runners", body,
       fn %{"runner" => r} ->
         IO.puts(
           "added runner ##{r["id"]} #{r["name"]} (v#{r["config_version"]}): " <>
             "the machine has it within seconds"
         )
       end}
    else
      {:error, @usage}
    end
  end

  def plan(["set-runner", id, runner], o) do
    body = compact(%{"pool" => o[:pool], "name" => o[:name], "config" => config(o)})

    {:ok, :patch, "/machines/#{enc(id)}/runners/#{enc(runner)}", body,
     fn %{"runner" => r} ->
       IO.puts("runner ##{r["id"]} #{r["name"]} is now v#{r["config_version"]}")
     end}
  end

  def plan([verb, id, runner], _o) when verb in ["pause-runner", "resume-runner"] do
    action = String.trim_trailing(verb, "-runner")

    {:ok, :post, "/machines/#{enc(id)}/runners/#{enc(runner)}/#{action}", %{},
     fn %{"runner" => r} ->
       IO.puts(
         if r["paused"],
           do: "paused #{r["name"]}: it takes no job until resumed",
           else: "#{r["name"]} takes jobs again"
       )
     end}
  end

  def plan(["probe", id, runner], o) do
    path = "/machines/#{enc(id)}/runners/#{enc(runner)}/probe"

    if o[:wait],
      do: {:ok, :probe_wait, path},
      else:
        {:ok, :post, path, %{},
         fn %{"probe" => p} ->
           IO.puts(
             "probe ##{p["id"]} sent: `slipdock machine show #{id}` has its result, " <>
               "or send it with --wait"
           )
         end}
  end

  def plan(["rm-runner", id, runner], _o) do
    {:ok, :delete, "/machines/#{enc(id)}/runners/#{enc(runner)}",
     fn %{"removed" => r} ->
       IO.puts("removed #{r["name"]}: the machine finishes the job it holds, then stops it")
     end}
  end

  def plan(_args, _o), do: {:error, @usage}

  # How long --wait follows a probe, and how often it asks.
  @probe_wait_ms 30 * 60 * 1000
  @probe_poll_ms 2000

  # Sends the probe, then asks after it until it ends: red exits 1.
  defp probe_and_wait(path, o) do
    case HTTP.post(path, %{}) do
      {:ok, %{"probe" => p}} ->
        IO.puts("probe ##{p["id"]} sent; waiting for it to end")
        fn -> HTTP.get(path) end |> await_probe(o) |> waited()

      other ->
        out(other, o, & &1)
    end
  end

  defp waited({:ok, :green}), do: :ok
  defp waited({:ok, _red}), do: System.halt(1)
  defp waited({:error, message}), do: fail(message)

  @doc false
  # Asks `get` (the probe's GET) until the probe ends, then prints it.
  # `o[:poll_ms]` and `o[:wait_ms]` stand in for the defaults in tests.
  def await_probe(get, o) do
    deadline = System.monotonic_time(:millisecond) + (o[:wait_ms] || @probe_wait_ms)
    poll(get, o[:poll_ms] || @probe_poll_ms, deadline)
  end

  defp poll(get, every, deadline) do
    case get.() do
      {:ok, %{"probe" => %{"result" => result} = p}} when result in ["green", "red"] ->
        probe_line(p)
        {:ok, String.to_existing_atom(result)}

      {:ok, %{"probe" => _}} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, "the probe hasn't ended yet: `slipdock machine show` has it when it does"}
        else
          Process.sleep(every)
          poll(get, every, deadline)
        end

      {:error, _, %{"error" => message}} ->
        {:error, message}

      other ->
        {:error, "could not read the probe: #{inspect(other)}"}
    end
  end

  @doc false
  # A probe: green with when it passed, red with how it ended and its log.
  def probe_line(%{"result" => "green"} = p),
    do: IO.puts(Render.green("probe ##{p["id"]} passed") <> "  #{p["finished_at"]}")

  def probe_line(%{"result" => "red"} = p) do
    IO.puts(Render.red("probe ##{p["id"]} #{p["status"]}") <> "  #{p["finished_at"]}")

    case String.trim(p["log"] || "") do
      "" -> IO.puts(Render.dim("  " <> (p["error"] || "no log was sent")))
      log -> log |> String.split("\n") |> Enum.each(&IO.puts("  " <> &1))
    end
  end

  def probe_line(p), do: IO.puts(Render.dim("probe ##{p["id"]} #{p["status"]}"))

  # The config fields given as switches; none given is an empty map, which
  # changes nothing.
  defp config(o) do
    @config
    |> Enum.flat_map(fn key ->
      case o[key] do
        nil -> []
        value -> [{if(key == :dir, do: "directory", else: Atom.to_string(key)), value}]
      end
    end)
    |> Map.new()
    |> worktree(o[:worktree])
  end

  defp worktree(config, nil), do: config
  defp worktree(config, true), do: Map.put(config, "worktree", "on")
  defp worktree(config, false), do: Map.put(config, "worktree", "off")

  @doc false
  # Yours, then the machines serving a board you're on, which you only see.
  def listing(%{"machines" => mine} = body) do
    table(mine)

    case body["shared"] || [] do
      [] ->
        :ok

      shared ->
        IO.puts(
          "\n" <> Render.bold("Serving your boards (you see them; their owners change them)")
        )

        table(shared)
    end
  end

  defp table([]),
    do: IO.puts(Render.dim("no machines: run `slipdock-runner init` on one to enrol it"))

  defp table(machines) do
    Render.table(
      ["ID", "NAME", "SYSTEM", "STATE", "BOARDS", "LAST SEEN"],
      Enum.map(machines, fn m ->
        [
          "##{m["id"]}",
          m["name"],
          system(m),
          m["state"],
          Enum.join(m["boards"] || [], ","),
          m["last_seen_at"] || "never"
        ]
      end)
    )
  end

  @doc false
  def show(m) do
    IO.puts(Render.bold("Machine ##{m["id"]} #{m["name"]}") <> "  #{m["state"]}")

    fields([
      {"Hostname", m["hostname"]},
      {"System", system(m)},
      {"Fingerprint", m["fingerprint"]},
      {"Boards", Enum.join(m["boards"] || [], ", ")},
      {"Enrolled", "#{m["enrolled_at"]} (by #{m["enrolled_via"]})"},
      {"Last seen", m["last_seen_at"] || "never"},
      {"Revoked", m["revoked_at"]},
      {"Update asked", m["update_requested_at"]}
    ])

    ceiling(m["ceiling"])
    runners(m["runners"] || [])
    changes(m["changes"] || [])
  end

  defp ceiling(nil), do: :ok

  defp ceiling(c) do
    IO.puts(
      "\n" <> Render.bold("Ceiling") <> Render.dim("  (set on the machine; read-only here)")
    )

    fields([
      {"Roots", Enum.join(c["roots"] || [], ", ")},
      {"Agents", Enum.join(c["agents"] || [], ", ")},
      {"Max mode", c["max_permission_mode"]},
      {"Max timeout", "#{c["max_timeout_minutes"]} minutes"},
      {"Executors", Enum.join(c["executors"] || [], ", ")}
    ])
  end

  defp runners([]), do: :ok

  defp runners(list) do
    IO.puts("\n" <> Render.bold("Runners"))

    Render.table(
      ["ID", "NAME", "POOL", "AGENT", "DIRECTORY", "MODE", "RUNS AS", "STATE", "PROBE"],
      Enum.map(list, fn r ->
        c = r["config"] || %{}

        [
          "##{r["id"]}",
          r["name"],
          r["pool"],
          c["agent"],
          c["directory"],
          c["permission_mode"],
          c["executor"],
          state(r),
          probe_state(r["probe"])
        ]
        |> Enum.map(&to_string(&1 || ""))
      end)
    )

    for r <- list, r["rejection"] do
      IO.puts(Render.red("#{r["name"]}: v#{r["rejected_version"]} refused: #{r["rejection"]}"))

      for line <- r["outside_ceiling"] || [],
          do: IO.puts(Render.dim("  outside the ceiling: #{line}"))
    end

    # A red probe's log, so the reason is in front of whoever reads it.
    for r <- list, match?(%{"result" => "red"}, r["probe"]) do
      IO.write("#{r["name"]}: ")
      probe_line(r["probe"])
    end
  end

  defp probe_state(nil), do: "never"
  defp probe_state(%{"result" => "green", "finished_at" => at}), do: "green #{at}"
  defp probe_state(%{"result" => "red", "finished_at" => at}), do: "red #{at}"
  defp probe_state(%{"status" => status}), do: status

  defp state(r) do
    cond do
      r["paused"] -> "paused"
      r["rejected_version"] -> "rejected v#{r["rejected_version"]}"
      r["current_job_id"] -> "job ##{r["current_job_id"]}"
      r["accepted_version"] == r["config_version"] -> "ready v#{r["config_version"]}"
      true -> "v#{r["config_version"]} not yet taken"
    end
  end

  defp changes([]), do: :ok

  defp changes(list) do
    IO.puts("\n" <> Render.bold("Changes"))

    for c <- Enum.take(list, 10) do
      reason = if c["reason"], do: ": #{c["reason"]}", else: ""
      IO.puts("  #{c["at"]}  #{c["runner"]} v#{c["version"]} #{c["outcome"]}#{reason}")
    end
  end

  @doc false
  # The machine as it described itself, to check against what init printed.
  def enrolment(e) do
    IO.puts(Render.bold("Machine asking to enrol: #{e["hostname"]}") <> "  #{e["state"]}")

    fields([
      {"System", system(e)},
      {"Fingerprint", e["fingerprint"] || "none given"},
      {"Asked from", e["client_ip"]},
      {"Expires", e["expires_at"]}
    ])

    IO.puts(
      Render.dim(
        "Check the fingerprint matches the one init printed, then: " <>
          "slipdock machine approve <code> <board>..."
      )
    )
  end

  @doc false
  def key(r) do
    IO.puts("Enrolment key (shown once; works once, for #{r["valid_hours"]} hours):")
    IO.puts("  slipdock-runner init --key #{r["enrolment_key"]}")
  end

  defp system(m), do: Enum.join(Enum.reject([m["os"], m["arch"]], &is_nil/1), " ")

  defp fields(pairs) do
    pairs
    |> Enum.reject(fn {_, v} -> Enum.member?([nil, ""], v) end)
    |> Enum.each(fn {k, v} -> IO.puts(String.pad_trailing(k <> ":", 13) <> to_string(v)) end)
  end
end
