defmodule Slipdock.Accounts.Support do
  @moduledoc """
  Support sessions: an admin's temporary, recorded read access to somebody
  else's boards.

  Its own module because the rules are what matter here — every session says
  why, expires, and is shown to the person it is about — and they are easier to
  keep straight away from the rest of the account code. Reached through
  `Slipdock.Accounts`.
  """
  import Ecto.Query, warn: false

  require Logger
  alias Slipdock.Repo
  alias Slipdock.Accounts
  alias Slipdock.Accounts.{SupportSession, User, UserNotifier}
  alias Slipdock.Settings

  @doc """
  Gives `admin` temporary read access to `subject`'s boards, and records it.

  The access is the easy part — whoever runs the server can read the database
  regardless. What makes this worth having is that it is **visible**: it says
  why, it expires, and `support_sessions_for/1` shows the person it is about
  every one that has ever been opened on them.
  """
  @spec open_support_session(User.t(), User.t(), String.t(), keyword()) ::
          {:ok, SupportSession.t()} | {:error, Ecto.Changeset.t() | :not_admin | :self}
  def open_support_session(%User{} = admin, %User{} = subject, reason, opts \\ []) do
    cond do
      not Accounts.admin?(admin) ->
        {:error, :not_admin}

      admin.id == subject.id ->
        # You can already see your own boards; a record saying otherwise would
        # be noise in the one list that has to stay readable.
        {:error, :self}

      true ->
        attrs = %{
          "admin_id" => admin.id,
          "subject_id" => subject.id,
          "reason" => reason,
          "expires_at" => opts[:expires_at]
        }

        with {:ok, session} <-
               %SupportSession{} |> SupportSession.changeset(attrs) |> Repo.insert() do
          Logger.info(
            "Support access: #{admin.email} may read #{subject.email}'s boards until " <>
              "#{session.expires_at} — #{session.reason}"
          )

          notify_of_support_session(session, admin, subject)
          {:ok, session}
        end
    end
  end

  @doc "Ends one early. Expiry does the same thing on its own."
  def end_support_session(%SupportSession{} = session) do
    session
    |> Ecto.Changeset.change(ended_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  @doc """
  Whether `admin` currently has support access to `subject`'s things.

  `Slipdock.Access` asks this, so the grant behaves like any other read access
  rather than being a separate way in with separate rules.
  """
  @spec support_access?(User.t() | nil, integer() | nil) :: boolean()
  def support_access?(%User{} = admin, subject_id) when is_integer(subject_id) do
    now = DateTime.utc_now()

    # Joined on the admin as they are now, not as they were when it was
    # opened: demoting or disabling them ends it.
    Repo.exists?(
      from(s in SupportSession,
        join: a in User,
        on: a.id == s.admin_id and a.admin == true and is_nil(a.disabled_at),
        where:
          s.admin_id == ^admin.id and s.subject_id == ^subject_id and is_nil(s.ended_at) and
            s.expires_at > ^now
      )
    )
  end

  def support_access?(_, _), do: false

  @doc "Every support session ever opened on this person, newest first."
  def support_sessions_for(%User{} = subject) do
    SupportSession
    |> where([s], s.subject_id == ^subject.id)
    |> order_by([s], desc: s.inserted_at)
    |> preload(:admin)
    |> Repo.all()
  end

  @doc "The ones in force right now, for an admin's own list."
  def live_support_sessions do
    now = DateTime.utc_now()

    SupportSession
    |> where([s], is_nil(s.ended_at) and s.expires_at > ^now)
    |> order_by([s], desc: s.inserted_at)
    |> preload([:admin, :subject])
    |> Repo.all()
  end

  def get_support_session!(id), do: Repo.get!(SupportSession, id)
  def get_support_session(nil), do: nil
  def get_support_session(id), do: Repo.get(SupportSession, id)

  # Telling them is the point. An unannounced look at somebody's boards is the
  # thing this is supposed to make impossible.
  defp notify_of_support_session(session, admin, subject) do
    if Settings.smtp_configured?() do
      UserNotifier.deliver_support_notice(subject, admin, session)
    end
  end
end
