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

  @doc "The code that proves a new admin address can actually receive mail."
  def deliver_admin_email_change(address, code, by) do
    email =
      new()
      |> to(address)
      |> from(Mailer.from())
      |> subject("#{code} confirms you as the Slipdock admin address")
      |> text_body("""
      #{Slipdock.Accounts.User.display_name(by)} (#{by.email}) wants this address to be
      the admin address for their Slipdock server.

      Your code is #{code}

      Type it under Admin to confirm. Nothing changes until you do — if you were
      not expecting this, ignore it and nothing will.
      """)

    Logger.info("Admin address change to #{address} requested by #{by.email}: code #{code}")

    with {:ok, _} <- Mailer.deliver_configured(email), do: {:ok, email}
  end

  @doc """
  Warns the address being replaced. Somebody quietly repointing a server at
  their own address should be visible, not silent.
  """
  def deliver_admin_email_warning(old_address, new_address, by) do
    email =
      new()
      |> to(old_address)
      |> from(Mailer.from())
      |> subject("Somebody is changing your Slipdock admin address")
      |> text_body("""
      #{Slipdock.Accounts.User.display_name(by)} (#{by.email}) has asked to change the
      admin address of your Slipdock server from this one to #{new_address}.

      It will not change unless somebody at that address confirms a code. If this
      was not you, sign in and check who has admin rights under Admin → People.
      """)

    with {:ok, _} <- Mailer.deliver_configured(email), do: {:ok, email}
  end

  @doc """
  Tells somebody that an admin has been given access to their boards.

  Sent when it is opened, not afterwards. Support access that the person finds
  out about later is the thing this whole mechanism exists to prevent.
  """
  def deliver_support_notice(subject, admin, session) do
    email =
      new()
      |> to({subject.name || subject.email, subject.email})
      |> from(Mailer.from())
      |> subject("Somebody has been given access to your Slipdock boards")
      |> text_body("""
      #{Slipdock.Accounts.User.display_name(admin)} (#{admin.email}), an admin of this
      Slipdock server, has been given read access to your boards until
      #{session.expires_at} UTC.

      The reason given was: #{session.reason}

      If that is not what you expected, reply to this message and ask.
      """)

    Logger.info("Told #{subject.email} that #{admin.email} has support access.")

    with {:ok, _} <- Mailer.deliver_configured(email), do: {:ok, email}
  end
end
