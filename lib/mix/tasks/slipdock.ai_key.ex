defmodule Mix.Tasks.Slipdock.AiKey do
  @moduledoc """
  Reads and writes the per-person AI settings the features run on — key,
  endpoint, model (see `Slipdock.AI.Keys`) — for when nobody can get at the
  web UI.

      mix slipdock.ai_key                                  # who has what, keys masked
      mix slipdock.ai_key you@example.com sk-or-v1-…       # set a key
      mix slipdock.ai_key you@example.com --from-env       # take it from OPENROUTER_API_KEY
      mix slipdock.ai_key you@example.com --remove         # delete everything of theirs
      mix slipdock.ai_key --show you@example.com           # print the key itself

  A model of their own, instead of (or as well as) a key — any
  OpenAI-compatible endpoint, which usually wants no key at all:

      mix slipdock.ai_key you@example.com --endpoint http://llm.local:1234/v1
      mix slipdock.ai_key you@example.com --models        # what that endpoint can run
      mix slipdock.ai_key you@example.com --model qwen/qwen3.5-9b
      mix slipdock.ai_key you@example.com --endpoint ""   # back to the server's own

  `--from-env` is how the one key that used to live in `.env` was moved into
  the store: set it for whoever owned it, then take it out of `.env`.
  """
  @shortdoc "Shows or sets a person's AI key, endpoint and model"

  use Mix.Task

  alias Slipdock.Accounts
  alias Slipdock.AI.Keys

  @switches [
    remove: :boolean,
    from_env: :boolean,
    show: :string,
    endpoint: :string,
    model: :string,
    embed_model: :string,
    models: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)

    cond do
      email = opts[:show] ->
        show(email)

      args == [] and not settings?(opts) ->
        list()

      opts[:remove] ->
        remove(hd(args))

      args != [] and opts[:models] ->
        models(hd(args))

      args != [] and settings?(opts) ->
        set_settings(hd(args), opts)

      opts[:from_env] ->
        set(hd(args), System.get_env("OPENROUTER_API_KEY"))

      match?([_email, _key], args) ->
        set(hd(args), Enum.at(args, 1))

      true ->
        Mix.raise(
          "Usage: mix slipdock.ai_key [<email> <key> | <email> --endpoint <url> | " <>
            "<email> --model <id> | <email> --models | <email> --remove] " <>
            "(mix help slipdock.ai_key)"
        )
    end
  end

  defp settings?(opts),
    do: Enum.any?([:endpoint, :model, :embed_model, :models], &Keyword.has_key?(opts, &1))

  defp set_settings(email, opts) do
    user = find!(email)

    attrs =
      [{:base_url, opts[:endpoint]}, {:model, opts[:model]}, {:embed_model, opts[:embed_model]}]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Keys.put_settings(user, attrs) do
      :ok ->
        settings = Keys.settings(user)

        Mix.shell().info(
          "#{user.email}: #{settings.base_url || "the server's endpoint"}, " <>
            "model #{settings.model || "the server's"}" <>
            "#{if settings.embed_model, do: ", embedding #{settings.embed_model}"}."
        )

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp models(email) do
    user = find!(email)

    case Slipdock.AI.models(user: user) do
      {:ok, models} ->
        Mix.shell().info("#{length(models)} model(s):")

        for m <- models,
            do: Mix.shell().info("  #{m.id}#{if m.embedding?, do: "  (embedding)"}")

      {:error, message} ->
        Mix.raise(message)
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
            "  #{entry.email || "user ##{id}"}  #{Keys.masked(entry.api_key) || "no key"}" <>
              "  #{entry.base_url || "default endpoint"}" <>
              "  #{entry.model || "default model"}  set #{entry.updated_at}"
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
      :ok -> Mix.shell().info("Removed the AI settings for #{user.email}.")
      {:error, message} -> Mix.raise(message)
    end
  end

  defp find!(email) do
    Accounts.get_user_by_email(email) ||
      Mix.raise("No user with the email #{email}.")
  end
end
