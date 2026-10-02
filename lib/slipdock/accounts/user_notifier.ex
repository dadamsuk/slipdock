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

  @doc """
  Tells an admin that somebody is waiting for an account.

  Without this, `approval` mode is a queue nobody looks at — which is why
  choosing that mode without working mail is refused.
  """
  def deliver_signup_request(admin, request) do
    email =
      new()
      |> to({admin.name || admin.email, admin.email})
      |> from(Mailer.from())
      |> subject("#{request.email} would like a Slipdock account")
      |> text_body("""
      #{request.email} has asked for an account on your Slipdock server.
      #{if request.note && request.note != "", do: "\nThey said: #{request.note}\n", else: ""}
      Approve or turn it down under Admin → People.

      #{Slipdock.Automations.Runner.base_url()}/admin/signups
      """)

    Logger.info("#{request.email} asked for an account; told #{admin.email}.")

    with {:ok, _} <- Mailer.deliver_configured(email), do: {:ok, email}
  end

  @doc """
  Tells somebody that an account has been made for them, and by whom.

  Before this, an invited account appeared out of nothing: the person had a
  Slipdock login they had never asked for and no way of knowing.
  """
  def deliver_invitation(user, inviter, to, base_url) do
    who = Slipdock.Accounts.User.display_name(inviter)

    email =
      new()
      |> to({user.name || user.email, user.email})
      |> from(Mailer.from())
      |> subject("#{who} has shared something with you on Slipdock")
      |> text_body("""
      #{who} (#{inviter.email}) has given you access to#{if to, do: " " <> to, else: " something"}
      on their Slipdock board.

      That means you now have an account here. Sign in at:

      #{base_url}/login

      Ask for a code with this address — #{user.email} — and you are in.

      If you were not expecting this, you can ignore it: an account nobody
      signs in to does nothing.
      """)

    Logger.info("Invited #{user.email} on behalf of #{inviter.email}.")

    with {:ok, _} <- Mailer.deliver_configured(email), do: {:ok, email}
  end
end
