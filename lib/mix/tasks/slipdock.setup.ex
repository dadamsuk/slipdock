defmodule Mix.Tasks.Slipdock.Setup do
  @moduledoc """
  Sets this server up without the browser wizard, for a container or any
  install that should never see it.

      mix slipdock.setup --admin you@example.com
      mix slipdock.setup --admin you@example.com --mode allowlist --allow example.com
      mix slipdock.setup --admin you@example.com --mode open --card-limit 20
      mix slipdock.setup --admin you@example.com --smtp-host smtp.example.com \\
        --smtp-from slipdock@example.com --smtp-user u --smtp-password p
      mix slipdock.setup --status            # what this server currently thinks
      mix slipdock.setup --sign-in-link you@example.com   # a fresh way in

  `--admin` is the whole of it: that address becomes the admin, setup is marked
  complete, and `/setup` is gone. Everything else has a sensible default
  (`--mode closed`, no card limit, no mail).

  **It refuses to run twice.** A server that has been set up is already
  somebody's, and quietly re-pointing the admin address from a shell history
  would be a fine way to take one over. Change things in the admin UI, or with
  the other `slipdock.*` tasks.

  The same thing happens on first boot from the environment —
  `SLIPDOCK_ADMIN_EMAIL` and friends seed the settings row and mark setup
  complete, so a `docker compose up` with those set never shows the wizard. This
  task is for when they were not set and you would rather not use a browser.
  """
  @shortdoc "Sets the server up from the command line, instead of the wizard"

  use Mix.Task

  alias Slipdock.Accounts
  alias Slipdock.Settings

  @switches [
    admin: :string,
    mode: :string,
    allow: :keep,
    card_limit: :integer,
    directory: :string,
    invites: :boolean,
    smtp_host: :string,
    smtp_port: :integer,
    smtp_user: :string,
    smtp_password: :string,
    smtp_from: :string,
    smtp_from_name: :string,
    status: :boolean,
    sign_in_link: :string
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)

    unless invalid == [] do
      Mix.raise("Unknown option: #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    cond do
      opts[:status] -> status()
      email = opts[:sign_in_link] -> sign_in_link(email)
      opts[:admin] -> set_up(opts)
      true -> Mix.raise("Nothing to do. Pass --admin you@example.com, or --status.")
    end
  end

  defp set_up(opts) do
    if Settings.setup_complete?() do
      Mix.raise("""
      This server has already been set up; #{Settings.get().admin_email} is the admin.

      Change these in the app under Admin. If you have lost your way in, make a
      sign-in link instead:

          mix slipdock.setup --sign-in-link #{Settings.get().admin_email}
      """)
    end

    attrs =
      %{"admin_email" => opts[:admin]}
      |> put_if(opts[:mode], "signup_mode", &validate_mode/1)
      |> put_if(opts[:card_limit], "free_card_limit")
      |> put_if(opts[:directory], "user_directory", &validate_directory/1)
      |> put_if(opts[:invites], "invites_create_accounts")
      |> put_if(opts[:smtp_host], "smtp_host")
      |> put_if(opts[:smtp_port], "smtp_port")
      |> put_if(opts[:smtp_user], "smtp_username")
      |> put_if(opts[:smtp_password], "smtp_password")
      |> put_if(opts[:smtp_from], "smtp_from_email")
      |> put_if(opts[:smtp_from_name], "smtp_from_name")

    case Settings.complete_setup(attrs) do
      {:ok, settings} ->
        for entry <- Keyword.get_values(opts, :allow), do: Settings.add_allowlist_entry(entry)
        {:ok, user} = Accounts.get_or_create_user_by_email(settings.admin_email)
        {:ok, _} = Accounts.promote(user)

        Mix.shell().info("""
        Set up. #{settings.admin_email} is the admin, registration is #{settings.signup_mode}#{limit_note(settings)}.

        The setup wizard is closed. A way in:

            mix slipdock.setup --sign-in-link #{settings.admin_email}
        """)

      {:error, changeset} ->
        Mix.raise("Could not set up: #{inspect(errors(changeset))}")
    end
  end

  # Not a backdoor: it needs shell access on the server, which is the same
  # access that could read the database anyway. It is the answer to "mail broke
  # and I cannot get in", which is otherwise unanswerable.
  defp sign_in_link(email) do
    case Accounts.get_user_by_email(email) do
      nil ->
        Mix.raise("No account here uses #{email}.")

      user ->
        base = Slipdock.Automations.Runner.base_url()

        case Accounts.deliver_sign_in(user, &"#{base}/login/#{&1}") do
          {:ok, :emailed} -> Mix.shell().info("A sign-in link is on its way to #{email}.")
          {:ok, {:written, path}} -> Mix.shell().info("Sign-in link written to #{path}")
          {:ok, :logged} -> Mix.shell().info("Sign-in link written to the log.")
          {:error, reason} -> Mix.raise("Could not send it: #{inspect(reason)}")
        end
    end
  end

  defp status do
    settings = Settings.get()

    Mix.shell().info("""
    Set up:          #{if Settings.setup_complete?(), do: "yes, #{settings.setup_completed_at}", else: "NO — the wizard is open"}
    Admin address:   #{settings.admin_email || "—"}
    Admins:          #{Enum.map_join(Accounts.list_admins(), ", ", & &1.email)}
    Registration:    #{settings.signup_mode}
    Allowlist:       #{allowlist()}
    Card limit:      #{settings.free_card_limit || "no limit"}
    People visible:  #{settings.user_directory}
    Invites create:  #{settings.invites_create_accounts}
    Mail:            #{if Settings.smtp_configured?(), do: "#{settings.smtp_host}:#{settings.smtp_port || 587}", else: "not configured"}
    Sign-in fallback: #{if Settings.login_fallback_enabled?(), do: Accounts.fallback_path(), else: "off"}
    """)
  end

  defp allowlist do
    case Settings.list_allowlist() do
      [] -> "—"
      entries -> Enum.map_join(entries, ", ", & &1.entry)
    end
  end

  defp limit_note(%{free_card_limit: nil}), do: ""
  defp limit_note(%{free_card_limit: n}), do: ", #{n} cards per person"

  defp put_if(attrs, nil, _key), do: attrs
  defp put_if(attrs, value, key), do: Map.put(attrs, key, value)

  defp put_if(attrs, nil, _key, _validate), do: attrs
  defp put_if(attrs, value, key, validate), do: Map.put(attrs, key, validate.(value))

  defp validate_mode(mode) do
    if mode in ~w(open allowlist approval closed) do
      mode
    else
      Mix.raise("--mode must be one of: open, allowlist, approval, closed")
    end
  end

  defp validate_directory(directory) do
    if directory in ~w(instance shared_only) do
      directory
    else
      Mix.raise("--directory must be instance or shared_only")
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _} -> message end)
  end
end
