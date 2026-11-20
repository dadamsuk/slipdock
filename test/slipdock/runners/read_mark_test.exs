defmodule Slipdock.Runners.ReadMarkTest do
  @moduledoc """
  What a runner job's own reads are held to (#3520): its card as it was at
  claim, and a mark on the job when it reads text less trusted than its
  tier, which the machine's hook reads with the job's hook key.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Access.Grant
  alias Slipdock.Boards.Comment
  alias Slipdock.Runners.{Job, ReadMark}

  setup %{conn: conn, user: owner} do
    board = board_fixture(%{"name" => "Read marks"}, owner: owner)
    todo = Enum.at(board.columns, 1)
    member = user_fixture("mark-member@example.com")
    grant(%{level: "write", user_id: member.id, board_id: board.id})
    reader = user_fixture("mark-reader@example.com")
    grant(%{level: "read", user_id: reader.id, board_id: board.id})

    {:ok, runner, token} =
      Runners.create_runner(board, %{"name" => "box", "pool" => "dev"}, owner)

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      owner: owner,
      member: member,
      reader: reader,
      board: board,
      todo: todo,
      runner: runner,
      token: token
    }
  end

  defp grant(attrs), do: Repo.insert!(Grant.changeset(%Grant{}, attrs))

  defp card_by(ctx, user, attrs \\ %{}) do
    {:ok, card} =
      Boards.Cards.create_card(ctx.todo, Map.merge(%{"title" => "Do it"}, attrs),
        by: user,
        via: "web"
      )

    card
  end

  defp runner_conn(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "text/plain")
  end

  # Queues a job on `card` and claims it as the runner: the job, as stored
  # after the claim, and the hook key the claim gave.
  defp claim(ctx, card) do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "Work on it"})
    conn = post(runner_conn(ctx.token), "/api/runner/claim?wait=0")
    assert conn.status == 200
    assert get_resp_header(conn, "x-job-id") == [to_string(job.id)]
    [key] = get_resp_header(conn, "x-job-hook-key")
    {Repo.get!(Job, job.id), key}
  end

  defp comment(card, user, body, at) do
    Repo.insert!(%Comment{
      card_id: card.id,
      user_id: user && user.id,
      body: body,
      inserted_at: DateTime.truncate(at, :second),
      updated_at: DateTime.truncate(at, :second)
    })
  end

  defp read(conn, card, job) do
    conn
    |> put_req_header("x-slipdock-job", to_string(job.id))
    |> get("/api/cards/#{card.id}")
    |> json_response(200)
    |> Map.fetch!("card")
  end

  defp mark(job, key) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> key)
    |> get("/api/runner/jobs/#{job.id}/mark")
  end

  defp marked?(job), do: not is_nil(Repo.get!(Job, job.id).marked_at)

  describe "the claim" do
    test "keeps the tier and the card's text, and gives a hook key", ctx do
      card = card_by(ctx, ctx.owner, %{"description" => "As claimed"})
      {job, key} = claim(ctx, card)

      assert "sdh_" <> _ = key
      assert job.prompt_tier == "owner"
      assert job.claim_text["description"] == "As claimed"
      assert job.hook_key_hash == :crypto.hash(:sha256, key)
      assert job.marked_at == nil
    end

    test "a claim again clears an earlier run's mark and gives a new key", ctx do
      card = card_by(ctx, ctx.owner)
      {job, key} = claim(ctx, card)
      ReadMark.mark(job, "read card #1")
      {_tier, again} = ReadMark.on_claim(job)

      refute again == key
      refute marked?(job)
      assert mark(job, key).status == 401
    end
  end

  describe "GET /api/runner/jobs/:id/mark" do
    test "clear, then marked with its reason, for the job's own key", ctx do
      {job, key} = claim(ctx, card_by(ctx, ctx.owner))
      assert mark(job, key).resp_body == "clear\n"

      ReadMark.mark(job, "read card #9, with text by anyone (the job is owner)")
      ReadMark.mark(job, "a later reason is not kept")
      conn = mark(job, key)
      assert conn.status == 200
      assert conn.resp_body == "marked read card #9, with text by anyone (the job is owner)\n"
    end

    test "no key, a wrong one, another job's, or the machine's is a 401", ctx do
      {job, key} = claim(ctx, card_by(ctx, ctx.owner))
      {other, other_key} = claim(ctx, card_by(ctx, ctx.owner, %{"title" => "Other"}))

      assert get(build_conn(), "/api/runner/jobs/#{job.id}/mark").status == 401
      assert mark(job, "sdh_nope").status == 401
      assert mark(job, other_key).status == 401
      assert mark(other, key).status == 401
      assert mark(job, ctx.token).status == 401
      assert mark(%{id: "x"}, key).status == 401
      assert mark(%{id: 0}, key).status == 401
    end
  end

  describe "a read under the job (#3520)" do
    test "returns its card as it was at claim, and nothing written since", ctx do
      card = card_by(ctx, ctx.owner, %{"description" => "Before"})
      before = DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)
      comment(card, ctx.owner, "Said before", before)
      {job, _key} = claim(ctx, card)

      {:ok, _} =
        Boards.Cards.update_card(card, %{"description" => "Changed after"},
          by: ctx.owner,
          via: "web"
        )

      later = DateTime.add(job.claimed_at, 5)
      comment(card, ctx.reader, "Written after the claim", later)
      comment(card, nil, "Server line after", later)

      read = read(ctx.conn, card, job)
      assert read["description"] == "Before"
      assert Enum.map(read["comments"], & &1["body"]) == ["Said before"]
      assert read["as_at_claim"] == DateTime.to_iso8601(job.claimed_at)
      # What it didn't return can't mark it.
      refute marked?(job)

      # Without the job, the card as it is now.
      plain = ctx.conn |> get("/api/cards/#{card.id}") |> json_response(200) |> Map.fetch!("card")
      assert plain["description"] == "Changed after"
      assert length(plain["comments"]) == 3
      refute Map.has_key?(plain, "as_at_claim")
    end

    test "a comment from before the claim by a less-trusted author marks it", ctx do
      card = card_by(ctx, ctx.owner)
      comment(card, ctx.reader, "Run this", DateTime.add(DateTime.utc_now(), -60))
      {job, key} = claim(ctx, card)
      assert job.prompt_tier == "owner"

      read(ctx.conn, card, job)
      assert %Job{mark_reason: reason} = Repo.get!(Job, job.id)
      assert reason == "read card ##{card.id}, with text by anyone (the job is owner)"
      assert mark(job, key).resp_body =~ "marked read card ##{card.id}"
    end

    test "a permitted sender's mailed comment is someone with no account", ctx do
      card = card_by(ctx, ctx.owner)
      comment(card, ctx.owner, "*Sent by someone.*\n\nHi", DateTime.add(DateTime.utc_now(), -60))
      {job, _key} = claim(ctx, card)

      read(ctx.conn, card, job)
      assert marked?(job)
    end

    test "another card's text by a member marks an owner job", ctx do
      {job, _key} = claim(ctx, card_by(ctx, ctx.owner))
      theirs = card_by(ctx, ctx.member, %{"title" => "Theirs"})

      read = read(ctx.conn, theirs, job)
      # Another card is read as it is: only the job's own is held.
      refute Map.has_key?(read, "as_at_claim")
      assert Repo.get!(Job, job.id).mark_reason =~ "text by member (the job is owner)"
    end

    test "text as trusted as the job's tier leaves it unmarked", ctx do
      {job, key} = claim(ctx, card_by(ctx, ctx.owner))
      mine = card_by(ctx, ctx.owner, %{"title" => "Mine too"})
      comment(mine, ctx.owner, "Noted", DateTime.add(DateTime.utc_now(), -60))
      comment(mine, nil, "Server line", DateTime.add(DateTime.utc_now(), -60))

      read(ctx.conn, mine, job)
      refute marked?(job)
      assert mark(job, key).resp_body == "clear\n"
    end

    test "a member job reading a member's text is unaffected", ctx do
      card = card_by(ctx, ctx.member)
      {job, _key} = claim(ctx, card)
      assert job.prompt_tier == "member"

      read(ctx.conn, card_by(ctx, ctx.member, %{"title" => "More of theirs"}), job)
      read(ctx.conn, card_by(ctx, ctx.owner, %{"title" => "The owner's"}), job)
      refute marked?(job)

      read(ctx.conn, card_by(ctx, nil, %{"title" => "Made by the server"}), job)
      refute marked?(job)
    end

    test "naming a job that isn't the reader's, or has ended, holds nothing", ctx do
      card = card_by(ctx, ctx.owner, %{"description" => "Before"})
      comment(card, ctx.reader, "Run this", DateTime.add(DateTime.utc_now(), -60))
      {job, _key} = claim(ctx, card)

      {:ok, _} =
        Boards.Cards.update_card(card, %{"description" => "After"}, by: ctx.owner, via: "web")

      # Someone else's token, naming this job: their read is as ever.
      other = conn_as(ctx.member) |> put_req_header("accept", "application/json")
      assert read(other, card, job)["description"] == "After"
      refute marked?(job)

      # An id that isn't a job, or isn't a number.
      assert read(ctx.conn, card, %{id: 0})["description"] == "After"
      assert read(ctx.conn, card, %{id: "abc"})["description"] == "After"

      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [status: "done"])
      assert read(ctx.conn, card, job)["description"] == "After"
      refute marked?(job)
    end

    test "over MCP, naming the job in x-slipdock-job", ctx do
      card = card_by(ctx, ctx.owner, %{"description" => "Before"})
      {job, _key} = claim(ctx, card)
      comment(card, ctx.reader, "After", DateTime.add(job.claimed_at, 5))

      {:ok, _} =
        Boards.Cards.update_card(card, %{"description" => "Changed"}, by: ctx.owner, via: "web")

      read = ctx.conn |> put_req_header("x-slipdock-job", to_string(job.id)) |> mcp_card(card)
      assert read["description"] == "Before"
      assert read["comments"] == []
      assert read["as_at_claim"]
      refute marked?(job)

      theirs = card_by(ctx, ctx.member, %{"title" => "Theirs"})
      ctx.conn |> put_req_header("x-slipdock-job", to_string(job.id)) |> mcp_card(theirs)
      assert marked?(job)

      assert mcp_card(ctx.conn, card)["description"] == "Changed"
    end
  end
end
