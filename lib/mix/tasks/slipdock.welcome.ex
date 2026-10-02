defmodule Mix.Tasks.Slipdock.Welcome do
  @shortdoc "Builds the Getting Started tour board for somebody"

  @moduledoc """
  Builds the “Getting Started” board — the tour a first sign-in makes by
  itself (see `Slipdock.Onboarding`) — for an existing account.

      mix slipdock.welcome you@example.com
      mix slipdock.welcome you@example.com --force   # another one, alongside

  For an account that archived the tour and wants it back, or one that was
  made before the tour existed. The address must already have an account:
  this task does not create people.
  """

  use Mix.Task

  alias Slipdock.{Accounts, Onboarding}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [force: :boolean])

    case rest do
      [email] -> welcome(email, opts)
      _ -> fail("Which account? mix slipdock.welcome you@example.com")
    end
  end

  defp welcome(email, opts) do
    case Accounts.get_user_by_email(email) do
      nil ->
        fail("There is no account for #{email}.")

      user ->
        if Onboarding.exists_for?(user) and not opts[:force] do
          fail("#{email} already has a “#{Onboarding.board_name()}” board — use --force.")
        else
          board = Onboarding.build!(user)

          Mix.shell().info(
            "Built “#{board.name}” (#{board.code}) for #{email}. Sign in to see it."
          )
        end
    end
  end

  defp fail(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
