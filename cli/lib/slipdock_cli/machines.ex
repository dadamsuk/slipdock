defmodule SlipdockCLI.Machines do
  @moduledoc false

  # Machines running the runner daemon (#2570): the account's own, listed,
  # shown and revoked; a machine's enrolment looked up, approved or refused
  # by the code `slipdock-runner init` shows (as the approval page does);
  # and the one-time enrolment keys for a machine with nobody at its screen.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(machines machine)

  @usage "usage: slipdock machines | machine show|revoke <id> | " <>
           "machine enrolment <code> | machine approve <code> <board>... | " <>
           "machine refuse <code> | machine enrol-key <board>... [--label L]"

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("machines", [], o), do: run("machine", ["ls"], o)

  def run("machine", args, o) do
    case plan(args, o) do
      {:ok, :get, path, render} -> HTTP.get(path) |> out(o, render)
      {:ok, :delete, path, render} -> HTTP.delete(path) |> out(o, render)
      {:ok, :post, path, body, render} -> HTTP.post(path, body) |> out(o, render)
      {:error, usage} -> fail(usage)
    end
  end

  def run(_cmd, _args, _o), do: fail(@usage)

  @doc false
  # What each `machine …` sends, and how its answer is shown; anything else
  # is the usage (a refusal halts, so the tests take it as this value).
  def plan(["ls"], _o), do: {:ok, :get, "/machines", &listing(&1["machines"])}

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

  def plan(_args, _o), do: {:error, @usage}

  @doc false
  def listing([]),
    do: IO.puts(Render.dim("no machines: run `slipdock-runner init` on one to enrol it"))

  def listing(machines) do
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
      {"Revoked", m["revoked_at"]}
    ])
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
