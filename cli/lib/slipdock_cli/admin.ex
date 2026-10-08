defmodule SlipdockCLI.Admin do
  @moduledoc false

  # `slipdock admin …`: what the server allows and who is on it.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(admin)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  # Administering the server. Needs a token made with the `admin` scope — an
  # ordinary read/write token is deliberately not enough, because those are the
  # ones that end up in agents and CI.
  def run("admin", ["settings"], o), do: HTTP.get("/admin/settings") |> out(o, &render_admin/1)

  def run("admin", ["build"], o),
    do: HTTP.get("/admin/settings") |> out(o, &IO.puts(render_build(&1["build"])))

  def run("admin", ["set" | pairs], o) when pairs != [] do
    body =
      Enum.reduce(pairs, %{}, fn pair, acc ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, admin_value(key, value))
          _ -> fail("settings are key=value, e.g. signup_mode=closed")
        end
      end)

    HTTP.patch("/admin/settings", body) |> out(o, &render_admin/1)
  end

  def run("admin", ["allow", entry], o),
    do: HTTP.post("/admin/allowlist", %{entry: entry}) |> out(o, &render_admin/1)

  def run("admin", ["disallow", entry], o),
    do: HTTP.delete("/admin/allowlist", entry: entry) |> out(o, &render_admin/1)

  def run("admin", ["users"], o), do: HTTP.get("/admin/users") |> out(o, &render_admin_users/1)

  def run("admin", ["promote", email], o), do: admin_user(email, %{admin: true}, o)
  def run("admin", ["demote", email], o), do: admin_user(email, %{admin: false}, o)
  def run("admin", ["disable", email], o), do: admin_user(email, %{disabled: true}, o)
  def run("admin", ["enable", email], o), do: admin_user(email, %{disabled: false}, o)

  def run("admin", ["limit", email, limit], o) do
    value = if limit in ["", "none", "-"], do: nil, else: limit
    admin_user(email, %{card_limit: value}, o)
  end

  def run("admin", ["paid", email, until], o) do
    value = if until in ["", "none", "-"], do: nil, else: until
    admin_user(email, %{paid_until: value}, o)
  end

  def run("admin", ["unlimited", email, switch], o) do
    case switch do
      s when s in ["on", "yes", "true"] -> admin_user(email, %{unlimited: true}, o)
      s when s in ["off", "no", "false"] -> admin_user(email, %{unlimited: false}, o)
      _ -> fail("admin unlimited <email> on|off")
    end
  end

  def run("admin", ["signups"], o),
    do: HTTP.get("/admin/signups") |> out(o, &render_admin_signups/1)

  def run("admin", ["approve", email], o), do: admin_signup(email, "approve", o)
  def run("admin", ["reject", email], o), do: admin_signup(email, "reject", o)

  def run("admin", _args, _o) do
    fail("""
    admin settings                      what this server allows
    admin build                         the commit and build time now running
    admin set key=value...              signup_mode, free_card_limit, user_directory,
                                        invites_create_accounts, login_fallback_enabled,
                                        posthog_key, posthog_host (empty to turn off),
                                        ai_system_user=<admin email> (empty to clear)
    admin allow <entry> | disallow <entry>
    admin users                         who is here
    admin promote|demote|disable|enable <email>
    admin limit <email> <n|none>        their own card limit
    admin paid <email> <date|none>      paid up to a date
    admin unlimited <email> on|off      off the free tier for good (ceilings still apply)
    admin signups                       who is waiting
    admin approve|reject <email>

    Needs a token made with the admin scope (Account → API tokens).
    Mail settings and the admin address are deliberately not here: both have to
    prove something first, and a PATCH would skip that.
    """)
  end

  def run(cmd, _args, _o), do: bad_usage(cmd)

  ## Helpers ------------------------------------------------------------------

  defp admin_user(email, change, o) do
    with {:ok, %{"users" => users}} <- HTTP.get("/admin/users"),
         %{"id" => id} <- Enum.find(users, &(&1["email"] == String.downcase(email))) do
      HTTP.patch("/admin/users/#{enc(id)}", change) |> out(o, &render_admin_user/1)
    else
      nil -> fail("no account here uses #{email}")
      other -> out(other, o, &render_admin_user/1)
    end
  end

  defp admin_signup(email, decision, o) do
    with {:ok, %{"requests" => requests}} <- HTTP.get("/admin/signups"),
         %{"id" => id} <- Enum.find(requests, &(&1["email"] == String.downcase(email))) do
      HTTP.post("/admin/signups/#{enc(id)}/#{enc(decision)}")
      |> out(o, fn _ -> IO.puts("#{decision}d #{email}") end)
    else
      nil -> fail("nobody with that address is waiting")
      other -> out(other, o, fn _ -> :ok end)
    end
  end

  # Numbers and booleans have to arrive as themselves, not as strings, or the
  # server rejects "20" where it wants 20.
  defp admin_value(key, value)
       when key in [
              "free_card_limit",
              "board_limit",
              "item_limit",
              "storage_limit_mb",
              "trial_days"
            ] do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp admin_value(key, value)
       when key in [
              "invites_create_accounts",
              "login_fallback_enabled",
              "board_limit_enabled",
              "item_limit_enabled",
              "storage_limit_enabled",
              "trial_enabled"
            ],
       do: value in ["1", "true", "yes", "on"]

  defp admin_value(_key, value), do: value

  defp render_admin(%{"settings" => s} = body) do
    IO.puts("""
    Build:            #{render_build(body["build"])}
    Registration:     #{s["signup_mode"]}#{allowlist_note(s)}
    Free allowance:   #{s["free_card_limit"] || "no limit"} (cards, pages and files)
    Free trial:       #{render_limit(s["limits"]["trial"], "days", "days")}
    Board ceiling:    #{render_limit(s["limits"]["boards"], "limit", "boards")}
    Item ceiling:     #{render_limit(s["limits"]["items"], "limit", "items")}
    File ceiling:     #{render_limit(s["limits"]["storage"], "limit_mb", "MB")}
    People visible:   #{s["user_directory"]}
    Invites create:   #{s["invites_create_accounts"]}
    Admin address:    #{s["admin_email"] || "—"}
    Mail:             #{if s["smtp"]["configured"], do: "#{s["smtp"]["host"]}:#{s["smtp"]["port"] || 587}", else: "not configured"}
    Sign-in fallback: #{if s["login_fallback"]["enabled"], do: s["login_fallback"]["path"], else: "off"}
    Analytics:        #{render_analytics(s["analytics"])}
    Search & rules AI:#{render_ai(s["ai"])}
    Waiting:          #{s["pending_signups"]}\
    """)
  end

  # PostHog, on only while a key is set; an unset host is PostHog's US cloud.
  defp render_analytics(%{"posthog_key" => key} = a) when is_binary(key) and key != "",
    do: "PostHog #{key} → #{a["posthog_host"] || "https://us.i.posthog.com"}"

  defp render_analytics(_), do: "off"

  # Whose AI settings unattended work runs on, and why that person's.
  defp render_ai(%{"source" => "none"} = ai),
    do: " off — no admin's AI settings to use#{chosen_note(ai)}"

  defp render_ai(%{"source" => "server_key"}), do: " the shared OPENROUTER_API_KEY"
  defp render_ai(%{"source" => "chosen", "using" => who}), do: " #{who} (chosen here)"

  defp render_ai(%{"source" => "environment"} = ai),
    do: " #{ai["using"] || "?"} (SLIPDOCK_AI_SYSTEM_USER)#{chosen_note(ai)}"

  defp render_ai(%{"source" => "sole_admin"} = ai),
    do: " #{ai["using"]} (the only admin with a key)#{chosen_note(ai)}"

  defp render_ai(_), do: " —"

  # A choice that is saved but not in effect: demoted, disabled or keyless.
  defp chosen_note(%{"system_user" => who}) when is_binary(who),
    do: "; #{who} is chosen but has no AI settings or is no longer an admin"

  defp chosen_note(_), do: ""

  # A limit is a number and a switch; a switch that is off means no limit at
  # all, whatever number is remembered behind it.
  defp render_limit(%{"enabled" => false}, _key, _unit), do: "off"
  defp render_limit(%{} = limit, key, unit), do: "#{limit[key]} #{unit}"
  defp render_limit(_limit, _key, _unit), do: "—"

  # The commit and the time it was compiled, which is what "which build is
  # running" means — see `Slipdock.Build` on the server.
  defp render_build(%{} = b) do
    "#{b["git_short_sha"]}#{if b["git_dirty"], do: "+modified"} built #{b["built_at"]} UTC (v#{b["version"]})"
  end

  defp render_build(_), do: "unknown"

  defp allowlist_note(%{"signup_mode" => "allowlist", "allowlist" => list}),
    do: " (#{if list == [], do: "nobody listed", else: Enum.join(list, ", ")})"

  defp allowlist_note(_), do: ""

  defp render_admin_users(%{"users" => users}) do
    for u <- users do
      flags =
        [
          u["admin"] && "admin",
          u["unlimited"] && "unlimited",
          u["disabled"] && "disabled",
          u["invited"] && "invited"
        ]
        |> Enum.filter(& &1)

      cards =
        case u["cards"] do
          %{"limited?" => true, "used" => used, "limit" => limit} -> "#{used}/#{limit} items"
          %{"used" => used} -> "#{used} items"
          _ -> ""
        end

      IO.puts(
        "#{u["email"]}  #{cards}#{standing(u)}  #{u["last_signed_in_at"] || "never seen"}#{if flags == [], do: "", else: "  [" <> Enum.join(flags, " ") <> "]"}"
      )
    end
  end

  # Paid up to a date, or how much trial is left — whichever applies.
  defp standing(%{"paid_until" => until}) when is_binary(until),
    do: "  paid to #{String.slice(until, 0, 10)}"

  defp standing(%{"limits" => %{"trial" => %{"applies?" => true} = trial}}),
    do: if(trial["expired?"], do: "  trial over", else: "  trial #{trial["days_left"]}d left")

  defp standing(_user), do: ""

  defp render_admin_user(%{"user" => u}), do: render_admin_users(%{"users" => [u]})
  defp render_admin_user(other), do: Render.json(other)

  defp render_admin_signups(%{"requests" => []}), do: IO.puts("Nobody is waiting.")

  defp render_admin_signups(%{"requests" => requests}) do
    for r <- requests do
      IO.puts(
        "#{r["email"]}  asked #{r["asked_at"]}#{if r["note"] in [nil, ""], do: "", else: "  “" <> r["note"] <> "”"}"
      )
    end
  end
end
