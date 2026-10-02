defmodule Slipdock.Accounts.UserNotifier do
  @moduledoc "Emails sent to users. Only the sign-in link and code for now."
  import Swoosh.Email
  require Logger

  alias Slipdock.Mailer

  @doc """
  The sign-in message: a link to click, and the same door as a code to type.

  Both, because neither works everywhere. A link is one click on the machine
  you asked from and useless when the mail arrives on a different one; a code
  survives being read aloud, retyped, or copied out of a terminal.
  """
  def deliver_magic_link(user, url, code \\ nil) do
    minutes = Slipdock.Accounts.UserToken.magic_validity_minutes()

    email =
      new()
      |> to({user.name || user.email, user.email})
      |> from(Mailer.from())
      |> subject(subject_for(code))
      |> text_body("""
      Hi#{if user.name, do: " " <> user.name, else: ""},
      #{if code, do: "\nYour sign-in code is #{code}\n", else: ""}
      Or click this link to sign in to Slipdock:

      #{url}

      Either way it works once and expires in #{minutes} minutes.

      If you didn't ask for this, you can ignore this email.
      """)

    # Handy when no real mail transport is configured (dev / Local adapter).
    Logger.info("Sign-in for #{user.email}: #{if code, do: "code #{code}, ", else: ""}#{url}")

    with {:ok, _} <- Mailer.deliver_configured(email), do: {:ok, email}
  end

  defp subject_for(nil), do: "Your Slipdock sign-in link"
  defp subject_for(code), do: "#{code} is your Slipdock sign-in code"
end
