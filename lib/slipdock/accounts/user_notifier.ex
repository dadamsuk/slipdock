defmodule Slipdock.Accounts.UserNotifier do
  @moduledoc "Emails sent to users. Only the magic sign-in link for now."
  import Swoosh.Email
  require Logger

  alias Slipdock.Mailer

  def deliver_magic_link(user, url) do
    from = Application.get_env(:slipdock, :mail_from, {"Slipdock", "slipdock@localhost"})

    email =
      new()
      |> to({user.name || user.email, user.email})
      |> from(from)
      |> subject("Your Slipdock sign-in link")
      |> text_body("""
      Hi#{if user.name, do: " " <> user.name, else: ""},

      Click the link below to sign in to Slipdock. It works once and expires in
      #{Slipdock.Accounts.UserToken.magic_validity_minutes()} minutes.

      #{url}

      If you didn't ask for this, you can ignore this email.
      """)

    # Handy when no real mail transport is configured (dev / Local adapter).
    Logger.info("Magic sign-in link for #{user.email}: #{url}")

    with {:ok, _} <- Mailer.deliver(email), do: {:ok, email}
  end
end
