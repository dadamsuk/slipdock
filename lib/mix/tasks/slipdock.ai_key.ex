defmodule Mix.Tasks.Slipdock.AiKey do
  @moduledoc """
  Reads and writes the per-person OpenRouter keys that the AI features run on
  (see `Slipdock.AI.Keys`), for when nobody can get at the web UI.

      mix slipdock.ai_key                                  # who has a key, masked
      mix slipdock.ai_key you@example.com sk-or-v1-…       # set one
      mix slipdock.ai_key you@example.com --from-env       # take it from OPENROUTER_API_KEY
      mix slipdock.ai_key you@example.com --remove         # delete one
      mix slipdock.ai_key --show you@example.com           # print the key itself

  `--from-env` is how the one key that used to live in `.env` was moved into
  the store: set it for whoever owned it, then take it out of `.env`.
  """
  @shortdoc "Shows or sets a person's OpenRouter API key"

  use Mix.Task

  alias Slipdock.Accounts
  alias Slipdock.AI.Keys

  @switches [remove: :boolean, from_env: :boolean, show: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)

    cond do
      email = opts[:show] ->
        show(email)

      args == [] ->
        list()

      opts[:remove] ->
        remove(hd(args))

      opts[:from_env] ->
        set(hd(args), System.get_env("OPENROUTER_API_KEY"))

      match?([_email, _key], args) ->
        set(hd(args), Enum.at(args, 1))

      true ->
        Mix.raise(
          "Usage: mix slipdock.ai_key [<email> <key> | <email> --remove] (mix help slipdock.ai_key)"
        )
    end
  end

  defp list do
    case Keys.all() do
      empty when empty == %{} ->
        Mix.shell().info("No keys stored (#{Keys.path()}).")

      keys ->
        Mix.shell().info("#{map_size(keys)} key(s) in #{Keys.path()}:")

        for {id, entry} <- Enum.sort_by(keys, fn {_id, e} -> e.email end) do
          Mix.shell().info(
            "  #{entry.email || "user ##{id}"}  #{Keys.masked(entry.api_key)}  set #{entry.updated_at}"
          )
        end
    end

    Mix.shell().info("Unattended work uses: #{Keys.masked(Keys.system_key()) || "no key"}")
  end

  defp show(email) do
    user = find!(email)

    case Keys.get(user) do
      nil -> Mix.shell().info("#{user.email} has no key.")
      key -> Mix.shell().info(key)
    end
  end

  defp set(_email, key) when key in [nil, ""],
    do: Mix.raise("No key given (OPENROUTER_API_KEY is unset?).")

  defp set(email, key) do
    user = find!(email)

    case Keys.put(user, key) do
      :ok -> Mix.shell().info("Stored #{Keys.masked(key)} for #{user.email} in #{Keys.path()}.")
      {:error, message} -> Mix.raise(message)
    end
  end

  defp remove(email) do
    user = find!(email)

    case Keys.delete(user) do
      :ok -> Mix.shell().info("Removed the key for #{user.email}.")
      {:error, message} -> Mix.raise(message)
    end
  end

  defp find!(email) do
    Accounts.get_user_by_email(email) ||
      Mix.raise("No user with the email #{email}.")
  end
end
