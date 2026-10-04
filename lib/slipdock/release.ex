defmodule Slipdock.Release do
  @moduledoc """
  The handful of administrative jobs that have to work in a release, where
  there is no Mix and so no `mix slipdock.*` tasks — the Docker image above all.

  The container's entrypoint calls these:

      docker compose run --rm slipdock migrate
      docker compose run --rm slipdock ai-key you@example.com sk-or-…
      docker compose run --rm slipdock ai-endpoint you@example.com http://llm.local:1234/v1
      docker compose run --rm slipdock reindex
      docker compose run --rm slipdock welcome you@example.com

  Each starts only as much of the app as it needs. Migrations in normal
  operation are not run from here: a release migrates itself on boot (see
  `Slipdock.Application`), and this is for doing it by hand.
  """

  @app :slipdock
  @batch 20

  @doc "Runs any pending migrations against the configured database."
  def migrate do
    load()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls `repo` back to `version`. Only ever run this deliberately."
  def rollback(repo, version) do
    load()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  The release's `mix slipdock.ai_key`: with no arguments, who has a key (masked);
  with an email and a key, stores it; with an email and `--remove`, deletes it.
  """
  def ai_key(args \\ []) do
    start()

    case args do
      [] -> list_keys()
      [email, "--remove"] -> remove_key(email)
      [email, key] -> put_key(email, key)
      _ -> puts("Usage: ai-key [<email> <key> | <email> --remove]")
    end
  end

  @doc """
  Points somebody at a model of their own: an OpenAI-compatible endpoint, and
  optionally which model on it. `--remove` sends them back to the server's.

      ai-endpoint you@example.com http://llm.local:1234/v1
      ai-endpoint you@example.com http://llm.local:1234/v1 qwen/qwen3.5-9b
      ai-endpoint you@example.com --remove
  """
  def ai_endpoint(args \\ []) do
    start()

    case args do
      [] -> list_keys()
      [email, "--remove"] -> put_settings(email, %{base_url: "", model: ""})
      [email, url] -> put_settings(email, %{base_url: url})
      [email, url, model] -> put_settings(email, %{base_url: url, model: model})
      _ -> puts("Usage: ai-endpoint <email> [<url> [<model>] | --remove]")
    end
  end

  @doc """
  The release's `mix slipdock.setup`: sets the server up without the browser
  wizard, says what it currently thinks, or makes a sign-in link when mail has
  broken and there is no other way in.

      docker compose run --rm slipdock setup --admin you@example.com
      docker compose run --rm slipdock setup --status
      docker compose run --rm slipdock setup --sign-in-link you@example.com
      docker compose run --rm slipdock setup --make-admin you@example.com

  The container case is usually covered by `SLIPDOCK_ADMIN_EMAIL`, which seeds
  the settings on first boot and skips the wizard entirely. This is for when it
  was not set, and for the day mail stops working.
  """
  def setup(args \\ []) do
    start()

    case args do
      ["--status"] ->
        setup_status()

      ["--sign-in-link", email] ->
        setup_sign_in_link(email)

      ["--make-admin", email] ->
        setup_make_admin(email)

      ["--admin", email | rest] ->
        do_setup(email, rest)

      _ ->
        puts(
          "Usage: setup [--admin <email> [--mode <mode>] [--allow <entry>]… | " <>
            "--make-admin <email> | --status | --sign-in-link <email>]"
        )
    end
  end

  defp setup_status do
    settings = Slipdock.Settings.get()

    puts("""
    Set up:           #{if Slipdock.Settings.setup_complete?(), do: "yes, #{settings.setup_completed_at}", else: "NO — the wizard is open"}
    Admin address:    #{settings.admin_email || "—"}
    Admins:           #{Enum.map_join(Slipdock.Accounts.list_admins(), ", ", & &1.email)}
    Registration:     #{settings.signup_mode}
    Free allowance:   #{settings.free_card_limit || "no limit"} (cards, pages and files)
    Free trial:       #{if settings.trial_enabled, do: "#{settings.trial_days} days", else: "off"}
    Board ceiling:    #{if settings.board_limit_enabled, do: settings.board_limit, else: "off"}
    Item ceiling:     #{if settings.item_limit_enabled, do: settings.item_limit, else: "off"}
    File ceiling:     #{if settings.storage_limit_enabled, do: "#{settings.storage_limit_mb} MB", else: "off"}
    People visible:   #{settings.user_directory}
    Invites create:   #{settings.invites_create_accounts}
    Mail:             #{if Slipdock.Settings.smtp_configured?(), do: settings.smtp_host, else: "not configured"}
    Sign-in fallback: #{if Slipdock.Settings.login_fallback_enabled?(), do: Slipdock.Accounts.fallback_path(), else: "off"}
    """)
  end

  # For a server that is set up but has nobody who can get into it: makes the
  # account, makes it an admin, and hands over a way in. The usual cause is an
  # install whose admin address was named but never given an account.
  defp setup_make_admin(email) do
    {:ok, user} = Slipdock.Accounts.get_or_create_user_by_email(email)

    case Slipdock.Accounts.restore_admin(user) do
      {:ok, user} ->
        puts("#{user.email} is an admin here.")
        setup_sign_in_link(user.email)

      {:error, reason} ->
        puts("Could not make #{email} an admin: #{inspect(reason)}")
    end
  end

  defp setup_sign_in_link(email) do
    case Slipdock.Accounts.get_user_by_email(email) do
      nil ->
        puts("No account here uses #{email}.")

      user ->
        base = Slipdock.Automations.Runner.base_url()

        case Slipdock.Accounts.deliver_sign_in(user, &"#{base}/login/#{&1}") do
          {:ok, :emailed} -> puts("A sign-in link is on its way to #{email}.")
          {:ok, {:written, path}} -> puts("Sign-in link written to #{path}")
          {:ok, :logged} -> puts("Sign-in link written to the log.")
          {:error, reason} -> puts("Could not send it: #{inspect(reason)}")
        end
    end
  end

  defp do_setup(email, rest) do
    if Slipdock.Settings.setup_complete?() do
      puts("""
      This server has already been set up; #{Slipdock.Settings.get().admin_email} is the admin.
      Change these under Admin, or make a way in with: setup --sign-in-link <email>
      """)
    else
      {attrs, allow} = setup_attrs(rest, %{"admin_email" => email}, [])

      case Slipdock.Settings.complete_setup(attrs) do
        {:ok, settings} ->
          for entry <- allow, do: Slipdock.Settings.add_allowlist_entry(entry)
          {:ok, user} = Slipdock.Accounts.get_or_create_user_by_email(settings.admin_email)
          {:ok, _} = Slipdock.Accounts.promote(user)

          puts(
            "Set up. #{settings.admin_email} is the admin, registration is #{settings.signup_mode}."
          )

          puts("A way in: setup --sign-in-link #{settings.admin_email}")

        {:error, changeset} ->
          puts("Could not set up: #{inspect(changeset.errors)}")
      end
    end
  end

  defp setup_attrs([], attrs, allow), do: {attrs, Enum.reverse(allow)}

  defp setup_attrs(["--allow", value | rest], attrs, allow),
    do: setup_attrs(rest, attrs, [value | allow])

  defp setup_attrs(["--mode", value | rest], attrs, allow),
    do: setup_attrs(rest, Map.put(attrs, "signup_mode", value), allow)

  defp setup_attrs(["--card-limit", value | rest], attrs, allow),
    do: setup_attrs(rest, Map.put(attrs, "free_card_limit", value), allow)

  defp setup_attrs(["--trial-days", value | rest], attrs, allow),
    do:
      setup_attrs(
        rest,
        attrs |> Map.put("trial_days", value) |> Map.put("trial_enabled", true),
        allow
      )

  defp setup_attrs(["--board-limit", value | rest], attrs, allow),
    do: setup_attrs(rest, Map.put(attrs, "board_limit", value), allow)

  defp setup_attrs(["--item-limit", value | rest], attrs, allow),
    do: setup_attrs(rest, Map.put(attrs, "item_limit", value), allow)

  defp setup_attrs(["--storage-limit-mb", value | rest], attrs, allow),
    do: setup_attrs(rest, Map.put(attrs, "storage_limit_mb", value), allow)

  defp setup_attrs(["--no-board-limit" | rest], attrs, allow),
    do: setup_attrs(rest, Map.put(attrs, "board_limit_enabled", false), allow)

  defp setup_attrs(["--no-item-limit" | rest], attrs, allow),
    do: setup_attrs(rest, Map.put(attrs, "item_limit_enabled", false), allow)

  defp setup_attrs(["--no-storage-limit" | rest], attrs, allow),
    do: setup_attrs(rest, Map.put(attrs, "storage_limit_enabled", false), allow)

  defp setup_attrs(["--directory", value | rest], attrs, allow),
    do: setup_attrs(rest, Map.put(attrs, "user_directory", value), allow)

  defp setup_attrs(["--smtp-host", value | rest], attrs, allow),
    do: setup_attrs(rest, Map.put(attrs, "smtp_host", value), allow)

  defp setup_attrs(["--smtp-from", value | rest], attrs, allow),
    do: setup_attrs(rest, Map.put(attrs, "smtp_from_email", value), allow)

  defp setup_attrs([unknown | rest], attrs, allow) do
    puts("Ignoring unknown option #{unknown}")
    setup_attrs(rest, attrs, allow)
  end

  @doc """
  The release's `mix slipdock.welcome`: builds the "Getting Started" tour board
  (see `Slipdock.Onboarding`) for an account that has signed in before, and so
  never had one built for it.

      docker compose run --rm slipdock welcome you@example.com
      docker compose run --rm slipdock welcome you@example.com --force

  For the account that archived the tour and wants it back, or one made before
  the tour existed. It will not make the account: they sign in first.
  """
  def welcome(args \\ []) do
    start()

    case args do
      [email] -> build_welcome(email, false)
      [email, "--force"] -> build_welcome(email, true)
      _ -> puts("Usage: welcome <email> [--force]")
    end
  end

  defp build_welcome(email, force?) do
    alias Slipdock.Onboarding

    with_user(email, fn user ->
      if Onboarding.exists_for?(user) and not force? do
        puts("#{user.email} already has a “#{Onboarding.board_name()}” board — pass --force.")
      else
        case Onboarding.build(user) do
          {:ok, board} -> puts("Built “#{board.name}” (#{board.code}) for #{user.email}.")
          {:error, reason} -> puts(Onboarding.refusal_message(user, reason))
        end
      end
    end)
  end

  @doc """
  The release's `mix slipdock.reindex`, in its plain form: walk every card and
  wiki page and embed what changed. The options the mix task takes (`--force`,
  `--dry-run`, `--stats`) are not here; this is the one that matters when you
  have just restored a database.
  """
  def reindex(_args \\ []) do
    start()
    alias Slipdock.Search

    if Slipdock.AI.Embeddings.configured?() do
      started = System.monotonic_time(:millisecond)

      totals =
        %{embedded: 0, unchanged: 0, removed: 0}
        |> walk("cards", Search.all_card_ids(), &Search.load_cards/1, &Search.index_cards/1)
        |> walk("wiki pages", Search.all_page_ids(), &Search.load_pages/1, &Search.index_pages/1)

      seconds = Float.round((System.monotonic_time(:millisecond) - started) / 1000, 1)

      puts(
        "Done in #{seconds}s. embedded: #{totals.embedded}, " <>
          "unchanged: #{totals.unchanged}, removed: #{totals.removed}"
      )
    else
      puts(
        "No AI key or endpoint is available for unattended work, so nothing can " <>
          "be embedded. Set one for somebody (ai-key, ai-endpoint), and name them " <>
          "with SLIPDOCK_AI_SYSTEM_USER if more than one person has one."
      )
    end
  end

  # ── the small print ────────────────────────────────────────────────────

  defp walk(totals, what, ids, load, index) do
    total = length(ids)

    if total == 0 do
      totals
    else
      puts("Walking #{total} #{what}…")

      ids
      |> Enum.chunk_every(@batch)
      |> Enum.reduce(totals, fn batch, acc ->
        case batch |> load.() |> index.() do
          {:ok, counts} -> Map.merge(acc, counts, fn _k, a, b -> a + b end)
          {:error, reason} -> raise "Embedding failed: #{reason}"
        end
      end)
    end
  end

  defp list_keys do
    alias Slipdock.AI.Keys

    case Keys.all() do
      empty when empty == %{} ->
        puts("No keys stored (#{Keys.path()}).")

      keys ->
        puts("#{map_size(keys)} key(s) in #{Keys.path()}:")

        for {id, entry} <- keys do
          puts(
            "  #{entry.email || "user ##{id}"}  #{Keys.masked(entry.api_key) || "no key"}" <>
              "  #{entry.base_url || "default endpoint"}  #{entry.model || "default model"}" <>
              "  set #{entry.updated_at}"
          )
        end
    end

    puts(
      "Unattended work uses: #{Slipdock.AI.Keys.masked(Slipdock.AI.Keys.system_key()) || "no key"}"
    )
  end

  defp put_key(email, key) do
    with_user(email, fn user ->
      case Slipdock.AI.Keys.put(user, key) do
        :ok -> puts("Stored #{Slipdock.AI.Keys.masked(key)} for #{user.email}.")
        {:error, message} -> puts(message)
      end
    end)
  end

  defp put_settings(email, attrs) do
    with_user(email, fn user ->
      case Slipdock.AI.Keys.put_settings(user, attrs) do
        :ok ->
          settings = Slipdock.AI.Keys.settings(user)

          puts(
            "#{user.email}: #{settings.base_url || "the server's endpoint"}" <>
              "#{if settings.model, do: ", model #{settings.model}"}."
          )

        {:error, message} ->
          puts(message)
      end
    end)
  end

  defp remove_key(email) do
    with_user(email, fn user ->
      :ok = Slipdock.AI.Keys.delete(user)
      puts("Removed the key for #{user.email}.")
    end)
  end

  defp with_user(email, fun) do
    case Slipdock.Accounts.get_user_by_email(email) do
      nil -> puts("No user with the email #{email}. They must sign in once first.")
      user -> fun.(user)
    end
  end

  # `eval` runs without the app started, which is what migrations want; the
  # other jobs need the repo and the config, so they start it.
  defp load, do: Application.load(@app)

  defp start do
    {:ok, _} = Application.ensure_all_started(@app)
    :ok
  end

  defp repos do
    load()
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp puts(text), do: IO.puts(text)
end
