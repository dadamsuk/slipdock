defmodule Slipdock.Runners.JobToken do
  @moduledoc """
  A verify job's own token (#3522). The machine's daemon runs a verify job
  in a container with no credentials of the machine's: no CLI login, no
  git or gh login, no keys. What the job gets instead is this token,
  minted when the job is claimed and handed to the daemon in the claim's
  `X-Job-Token`, which the daemon gives the job as `$SLIPDOCK_TOKEN`.

  It belongs to the machine's owner (whose login the verifier used before),
  is confined to the job's tree (`scope_boards`), works only while its job
  is claimed or running, and is labelled `verify job #<id>`, so a decision
  made with it is never the builder's (`Verified.same_actor?`). What it may
  call is `allowed?/4`:

    * always: the verdict on the job's own card (`POST /api/cards/:id/verify`)
      and the job's own progress (`POST /api/jobs/:id/progress`), and the
      tree's handbook rules and garden proposals (`GET
      /api/boards/:board/handbook`, `…/garden`), which the rules step reads,
      and a page's revisions (`GET /api/pages/:id/revisions`), which the
      `Handbook:` line's check reads;
    * for a job judged on the diff and the bar (`diff_only?/1`), nothing
      else: not the card, its comments or any other card;
    * for an audit, or a card with no diff to judge (a spike, a card that
      changes no code, an epic with no pull request of its own), any read
      in its tree too, since what it judges is on the board.

  A token for any other route answers 403. It is never an API token: the
  token list, MCP and the other doors that take one don't take it.
  """

  import Ecto.Query

  alias Slipdock.Accounts.{User, UserToken}
  alias Slipdock.Boards.Card
  alias Slipdock.Repo
  alias Slipdock.Runners.{Job, Runner}

  @context "job"
  # The longest a job may run on any machine (a ceiling's max_timeout_minutes
  # is at most 1440): the token can't outlive it even if the job's row does.
  @life_seconds 24 * 60 * 60

  @doc "The token context a job's token is stored under."
  def context, do: @context

  @doc """
  A fresh token for `job`, claimed by `runner`, or nil: only a verify job on
  a card gets one, and only when the runner has an owner. Any token minted
  for the job before (a claim that was lost and made again) stops working.
  """
  def mint(%Job{kind: "verify", card_id: card_id} = job, %Runner{} = runner)
      when is_integer(card_id) do
    case owner(runner) do
      %User{disabled_at: nil} = user ->
        Repo.delete_all(
          from(t in UserToken, where: t.context == @context and t.job_id == ^job.id)
        )

        {token, row} =
          UserToken.build_hashed_token(user, @context,
            label: "verify job ##{job.id}",
            scope: "write",
            scope_boards: [job.root_board_id || job.board_id],
            expires_at: DateTime.add(DateTime.utc_now(:second), @life_seconds, :second)
          )

        Repo.insert!(%{row | job_id: job.id})
        token

      _ ->
        nil
    end
  end

  def mint(_job, _runner), do: nil

  # Whose login the verifier used before: the machine's owner, else whoever
  # made the runner.
  defp owner(%Runner{machine_id: machine_id}) when is_integer(machine_id) do
    Repo.one(
      from(m in Slipdock.Machines.Machine,
        join: u in User,
        on: u.id == m.user_id,
        where: m.id == ^machine_id,
        select: u
      )
    )
  end

  defp owner(%Runner{created_by_id: id}) when is_integer(id), do: Repo.get(User, id)
  defp owner(_runner), do: nil

  @doc """
  The user, the token row and its job behind `token`, or nil: the token is
  a job's, unexpired, its owner not disabled, and its job still claimed or
  running.
  """
  def authenticate(token) when is_binary(token) do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false),
         hashed = :crypto.hash(:sha256, decoded),
         now = DateTime.utc_now(),
         {%User{disabled_at: nil} = user, %UserToken{} = row, %Job{} = job} <-
           Repo.one(
             from(t in UserToken,
               join: u in User,
               on: u.id == t.user_id,
               join: j in Job,
               on: j.id == t.job_id,
               where: t.token == ^hashed and t.context == @context,
               where: t.expires_at > ^now,
               where: j.status in ~w(claimed running),
               select: {u, t, j}
             )
           ) do
      {user, row, job}
    else
      _ -> nil
    end
  end

  def authenticate(_token), do: nil

  @doc """
  Whether a job's token may make this request: `method` and the path's
  segments (`conn.path_info`). See the moduledoc.
  """
  def allowed?(job, method, path_info, diff_only?)

  def allowed?(%Job{card_id: card_id}, "POST", ["api", "cards", id, "verify"], _),
    do: same_id?(id, card_id)

  def allowed?(%Job{id: job_id}, "POST", ["api", "jobs", id, "progress"], _),
    do: same_id?(id, job_id)

  def allowed?(_job, method, ["api", "boards", _board, what], _)
      when method in ~w(GET HEAD) and what in ~w(handbook garden),
      do: true

  def allowed?(_job, method, ["api", "pages", _page, "revisions"], _)
      when method in ~w(GET HEAD),
      do: true

  def allowed?(_job, method, ["api" | _], false) when method in ~w(GET HEAD), do: true
  def allowed?(_job, _method, _path, _diff_only?), do: false

  defp same_id?(text, id) when is_integer(id), do: text == Integer.to_string(id)
  defp same_id?(_text, _id), do: false

  @doc """
  Whether a verify job is judged on the diff and the bar alone (#3522): a
  verify job, not an audit, whose card has a change to check
  (`Slipdock.Verified.Prompts.diff_only?/2`). Its prompt shows nothing of
  the card but the bar and the evidence's checked fields, and its token
  reads nothing of the board.
  """
  def diff_only?(%Job{kind: "verify", audit: false, card_id: card_id})
      when is_integer(card_id) do
    case Repo.get(Card, card_id) do
      %Card{} = card ->
        Slipdock.Verified.Prompts.diff_only?(card, Slipdock.Verified.Util.board(card))

      nil ->
        false
    end
  end

  def diff_only?(_job), do: false
end
