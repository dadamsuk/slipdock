defmodule Slipdock.Runners.AgentWriteTierTest do
  @moduledoc """
  An agent's writes to a card's text count at its job's tier, not at its
  login's (#3534): an agent using the owner's login can't make another card
  owner-tier, and a person's own edit is unchanged.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Runners}
  alias Slipdock.Access.Grant
  alias Slipdock.Runners.{Job, TrustTier}

  setup do
    owner = user_fixture("agent-tier-owner@example.com")
    board = board_fixture(%{"name" => "Agent tiers"}, owner: owner)
    member = user_fixture("agent-tier-member@example.com")

    Repo.insert!(
      Grant.changeset(%Grant{}, %{level: "write", user_id: member.id, board_id: board.id})
    )

    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"}, owner)
    {token, _} = Accounts.create_api_token(owner, "cli")

    api =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("x-slipdock-client", "cli")

    %{
      owner: owner,
      member: member,
      board: board,
      todo: Enum.at(board.columns, 1),
      runner: runner,
      api: api
    }
  end

  defp card_by(ctx, user, attrs \\ %{}) do
    {:ok, card} =
      Boards.Cards.create_card(ctx.todo, Map.merge(%{"title" => "Do it"}, attrs),
        by: user,
        via: "web"
      )

    card
  end

  # A job of the owner's, claimed by the owner's runner, on a card whose text
  # `writer` wrote: so its tier is `writer`'s.
  defp live_job(ctx, writer) do
    card = card_by(ctx, writer, %{"description" => "Work"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "work", prompt: "go"})
    %Job{} = job = Runners.claim(ctx.runner)
    job
  end

  defp tier(card) do
    {:ok, job} = Runners.queue(card, %{pool: "other", kind: "work", prompt: "go"})
    TrustTier.of(job)
  end

  defp agent_edit(ctx, card, job_id, kind \\ "agent") do
    actor = %{Actor.runner(ctx.owner, job_id, "cli") | kind: kind, via: "cli"}

    {:ok, card} =
      Boards.Cards.update_card(card, %{"description" => "Rewritten"}, actor: actor)

    card
  end

  test "a member-tier job's agent, with the owner's login, leaves the card below owner", ctx do
    job = live_job(ctx, ctx.member)
    assert TrustTier.of(job) == "member"
    target = card_by(ctx, ctx.owner)
    assert tier(target) == "owner"

    resp =
      ctx.api
      |> put_req_header("x-slipdock-agent", "1")
      |> put_req_header("x-slipdock-job", to_string(job.id))
      |> patch(~p"/api/cards/#{target.id}", %{"description" => "Do something else"})

    assert json_response(resp, 200)
    target = Repo.reload!(target)
    assert target.text_by == [ctx.owner.id, -1]
    assert tier(target) == "member"
  end

  test "an anyone-tier job's agent leaves it at anyone", ctx do
    outsider = user_fixture()

    Repo.insert!(
      Grant.changeset(%Grant{}, %{level: "write", user_id: outsider.id, board_id: ctx.board.id})
    )

    job = live_job(ctx, outsider)
    Repo.delete_all(from(g in Grant, where: g.user_id == ^outsider.id))
    assert TrustTier.of(job) == "anyone"

    target = agent_edit(ctx, card_by(ctx, ctx.owner), job.id)
    assert target.text_by == [ctx.owner.id, 0]
    assert tier(target) == "anyone"
  end

  test "an owner-tier job's agent keeps the card owner-tier", ctx do
    job = live_job(ctx, ctx.owner)
    assert TrustTier.of(job) == "owner"

    target = agent_edit(ctx, card_by(ctx, ctx.owner), job.id)
    assert target.text_by == [ctx.owner.id]
    assert tier(target) == "owner"
  end

  test "an agent with no job counts as a member at most", ctx do
    resp =
      ctx.api
      |> put_req_header("x-slipdock-agent", "1")
      |> patch(~p"/api/cards/#{card_by(ctx, ctx.owner).id}", %{"title" => "Renamed"})

    %{"card" => %{"id" => id}} = json_response(resp, 200)
    target = Repo.get!(Boards.Card, id)
    assert target.text_by == [ctx.owner.id, -1]
    assert tier(target) == "member"
  end

  test "a request carrying a job id counts as the job's even as a person", ctx do
    job = live_job(ctx, ctx.member)
    target = agent_edit(ctx, card_by(ctx, ctx.owner), job.id, "human")
    assert tier(target) == "member"
  end

  test "an owner-tier job id that isn't live or isn't the person's counts for nothing", ctx do
    finished = live_job(ctx, ctx.owner)
    Repo.update_all(from(j in Job, where: j.id == ^finished.id), set: [status: "done"])
    assert tier(agent_edit(ctx, card_by(ctx, ctx.owner), finished.id)) == "member"

    # A live owner-tier job of someone else's, on their own board.
    other = user_fixture()
    other_board = board_fixture(%{"name" => "Theirs"}, owner: other)

    {:ok, other_runner, _} =
      Runners.create_runner(other_board, %{"name" => "x", "pool" => "dev"}, other)

    other_card = card_by(%{todo: Enum.at(other_board.columns, 1)}, other)
    {:ok, _} = Runners.queue(other_card, %{pool: "dev", kind: "work", prompt: "go"})
    %Job{} = theirs = Runners.claim(other_runner)
    assert TrustTier.of(theirs) == "owner"
    assert tier(agent_edit(ctx, card_by(ctx, ctx.owner), theirs.id)) == "member"

    assert tier(agent_edit(ctx, card_by(ctx, ctx.owner), 999_999_999)) == "member"
  end

  # A live job on `runner`, on a card whose text `writer` wrote.
  defp job_on(ctx, runner, pool, writer) do
    card = card_by(ctx, writer, %{"description" => "Work"})
    {:ok, _} = Runners.queue(card, %{pool: pool, kind: "work", prompt: "go"})
    %Job{} = job = Runners.claim(runner)
    job
  end

  # A runner the member made on the owner's board. Taking work from it needs a
  # pool grant, so it is made by the owner and then put in the member's name.
  defp members_runner(ctx) do
    {:ok, runner, _} =
      Runners.create_runner(ctx.board, %{"name" => "theirs", "pool" => "m"}, ctx.owner)

    Repo.update_all(from(r in Runners.Runner, where: r.id == ^runner.id),
      set: [created_by_id: ctx.member.id]
    )

    runner
  end

  defp edit_as(user, card, job_id) do
    {:ok, card} =
      Boards.Cards.update_card(card, %{"description" => "Rewritten"},
        actor: %{Actor.runner(user, job_id, "cli") | via: "cli"}
      )

    card
  end

  test "an agent's person losing access after the write leaves the card at anyone", ctx do
    runner = members_runner(ctx)

    job = job_on(ctx, runner, "m", ctx.member)
    assert TrustTier.of(job) == "member"

    target = edit_as(ctx.member, card_by(ctx, ctx.owner), job.id)
    assert target.text_by == [ctx.owner.id, ctx.member.id, -1]
    assert tier(target) == "member"

    Repo.delete_all(from(g in Grant, where: g.user_id == ^ctx.member.id))
    assert tier(target) == "anyone"
  end

  test "a live job on a runner the person made, on a board they don't own, is theirs", ctx do
    runner = members_runner(ctx)

    job = job_on(ctx, runner, "m", ctx.owner)
    assert TrustTier.of(job) == "owner"

    target = edit_as(ctx.member, card_by(ctx, ctx.owner), job.id)
    # The job's tier, owner, adds no cap: only the member's own id.
    assert target.text_by == [ctx.owner.id, ctx.member.id]
    assert tier(target) == "member"
  end

  test "a live job on a runner someone else made, in a tree the person owns, is theirs", ctx do
    {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "shared", "pool" => "s"})
    job = job_on(ctx, runner, "s", ctx.owner)
    assert TrustTier.of(job) == "owner"

    target = edit_as(ctx.owner, card_by(ctx, ctx.owner), job.id)
    assert target.text_by == [ctx.owner.id]
    assert tier(target) == "owner"
  end

  test "a person's own CLI edit is unchanged", ctx do
    target = card_by(ctx, ctx.owner)

    resp = patch(ctx.api, ~p"/api/cards/#{target.id}", %{"description" => "Mine still"})
    assert json_response(resp, 200)
    target = Repo.reload!(target)
    assert target.text_by == [ctx.owner.id]
    assert tier(target) == "owner"
  end

  test "an agent's edit that leaves the text alone records nothing", ctx do
    target = card_by(ctx, ctx.owner)

    {:ok, target} =
      Boards.Cards.update_card(target, %{"priority" => "high"},
        actor: Actor.runner(ctx.owner, nil, "cli")
      )

    assert target.text_by == [ctx.owner.id]
  end
end
