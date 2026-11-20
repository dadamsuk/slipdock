defmodule SlipdockWeb.QuarantineJobViewsTest do
  @moduledoc """
  The reads of an `anyone`-tier job's card text outside its claim (#3535).

  - Every job view (`API.JSON.job/2`) leaves an `anyone`-tier job's prompt
    and card title out for a reader below the board's owner, and for a read
    made under a runner job; the owner sees them, and owner and member jobs
    are unchanged.
  - A card read naming such a job (`x-slipdock-job`, #3520) returns, for
    the job's own card, the fields its claim quoted, never the card's text.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{AIStub, Boards, Repo, Runners}
  alias Slipdock.Access.Grant
  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Runners.{Job, Transcript}

  @asked "The export button saves the board as CSV."
  @secrets ["Outsider title", "SECRET-DESC", "SECRET-PROMPT", "SECRET-COMMENT"]

  setup %{conn: conn, user: owner} do
    board = board_fixture(%{"name" => "Quarantined views"}, owner: owner)
    todo = Enum.at(board.columns, 1)
    member = user_fixture("views-member@example.com")

    Repo.insert!(
      Grant.changeset(%Grant{}, %{level: "write", user_id: member.id, board_id: board.id})
    )

    {:ok, runner, token} =
      Runners.create_runner(board, %{"name" => "box", "pool" => "dev"}, owner)

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      member_conn: conn_as(member) |> put_req_header("accept", "application/json"),
      owner: owner,
      member: member,
      board: board,
      todo: todo,
      runner: runner,
      token: token
    }
  end

  # A card whose text someone with no account here wrote: tier `anyone`.
  defp anyone_card(ctx) do
    card =
      card_fixture(ctx.todo, %{
        "title" => "Outsider title",
        "description" => @asked <> "\n\nSECRET-DESC"
      })

    Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [text_by: [0]])
    Repo.reload!(card)
  end

  defp card_by(ctx, user, title) do
    {:ok, card} = Boards.Cards.create_card(ctx.todo, %{"title" => title}, by: user, via: "web")
    card
  end

  defp queue(card, prompt \\ "Build: Outsider title SECRET-PROMPT") do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: prompt})
    job
  end

  defp job_json(conn, job), do: conn |> get("/api/jobs/#{job.id}") |> json_response(200)

  defp refute_secrets(body) do
    text = if is_binary(body), do: body, else: Jason.encode!(body)
    for secret <- @secrets, do: refute(text =~ secret, "#{secret} leaked")
  end

  defp assert_withheld(view) do
    assert view["prompt"] == nil
    assert view["card"] == nil
    assert view["text_withheld"] == true
    refute_secrets(view)
  end

  # `title`: the card's title where the view loads it (the board's list
  # and a runner's), nil where it never did.
  defp assert_whole(view, title) do
    assert view["prompt"] =~ "Build:"
    assert view["card"] == title
    assert view["text_withheld"] == false
  end

  describe "a job view" do
    test "GET /api/jobs/:id leaves an anyone job's prompt and title out below the owner", ctx do
      job = queue(anyone_card(ctx))

      ctx.member_conn |> job_json(job) |> Map.fetch!("job") |> assert_withheld()
      ctx.conn |> job_json(job) |> Map.fetch!("job") |> assert_whole(nil)
    end

    test "a read under a runner job gets it without the text, the owner's too", ctx do
      job = queue(anyone_card(ctx))

      ctx.conn
      |> put_req_header("x-slipdock-job", to_string(job.id))
      |> job_json(job)
      |> Map.fetch!("job")
      |> assert_withheld()
    end

    test "a job that was anyone at claim stays withheld after its text is the owner's", ctx do
      card = card_by(ctx, ctx.owner, "Owner title")
      job = queue(card, "Build: Owner title")
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [prompt_tier: "anyone"])

      ctx.member_conn |> job_json(job) |> Map.fetch!("job") |> assert_withheld()
    end

    test "owner and member jobs are unchanged for a reader below the owner", ctx do
      owners = queue(card_by(ctx, ctx.owner, "Owner title"), "Build: Owner title")
      members = queue(card_by(ctx, ctx.member, "Member title"), "Build: Member title")

      ctx.member_conn |> job_json(owners) |> Map.fetch!("job") |> assert_whole(nil)
      ctx.member_conn |> job_json(members) |> Map.fetch!("job") |> assert_whole(nil)

      listed =
        ctx.member_conn
        |> get("/api/boards/#{ctx.board.code}/jobs")
        |> json_response(200)
        |> Map.fetch!("jobs")
        |> Map.new(&{&1["id"], &1})

      assert_whole(listed[owners.id], "Owner title")
      assert_whole(listed[members.id], "Member title")
    end

    test "the board's and the card's job lists withhold it job by job", ctx do
      anyone = queue(anyone_card(ctx))
      owners = queue(card_by(ctx, ctx.owner, "Owner title"), "Build: Owner title")

      listed =
        ctx.member_conn
        |> get("/api/boards/#{ctx.board.code}/jobs")
        |> json_response(200)
        |> Map.fetch!("jobs")
        |> Map.new(&{&1["id"], &1})

      assert_withheld(listed[anyone.id])
      assert_whole(listed[owners.id], "Owner title")

      [on_card] =
        ctx.member_conn
        |> get("/api/cards/#{anyone.card_id}/jobs")
        |> json_response(200)
        |> Map.fetch!("jobs")

      assert_withheld(on_card)

      [owner_sees] =
        ctx.conn
        |> get("/api/cards/#{anyone.card_id}/jobs")
        |> json_response(200)
        |> Map.fetch!("jobs")

      assert_whole(owner_sees, nil)

      ctx.conn
      |> get("/api/boards/#{ctx.board.code}/jobs")
      |> json_response(200)
      |> Map.fetch!("jobs")
      |> Enum.find(&(&1["id"] == anyone.id))
      |> assert_whole("Outsider title")
    end

    test "a cancel answers the job without its text below the owner", ctx do
      job = queue(anyone_card(ctx))

      ctx.member_conn
      |> post("/api/jobs/#{job.id}/cancel")
      |> json_response(200)
      |> Map.fetch!("job")
      |> assert_withheld()
    end

    test "a runner's details withhold its jobs' text under a runner job", ctx do
      job = queue(anyone_card(ctx))
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [runner_id: ctx.runner.id])

      path = "/api/boards/#{ctx.board.code}/runners/#{ctx.runner.id}"

      [recent] = ctx.conn |> get(path) |> json_response(200) |> get_in(["runner", "recent_jobs"])
      assert recent["card"] == "Outsider title"

      [recent] =
        ctx.conn
        |> put_req_header("x-slipdock-job", to_string(job.id))
        |> get(path)
        |> json_response(200)
        |> get_in(["runner", "recent_jobs"])

      assert recent["card"] == nil
      assert recent["text_withheld"] == true
    end

    test "MCP keep_job_log answers the job without its text below the owner", ctx do
      card = card_by(ctx, ctx.owner, "Outsider title")
      queue(card)
      job = Runners.claim(ctx.runner)

      {:ok, 1} =
        Transcript.append(
          ctx.runner,
          job.id,
          0,
          ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}\n)
        )

      {:ok, _} = Runners.finish(ctx.runner, job.id, %{exit: "0"})
      # Its text is an outsider's now.
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [text_by: [0]])

      ctx.member_conn |> keep(job) |> Map.fetch!("job") |> assert_withheld()
      ctx.conn |> keep(job) |> Map.fetch!("job") |> assert_whole(nil)
    end
  end

  defp keep(conn, job) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "keep_job_log", arguments: %{job: job.id}}
      })
    )
    |> json_response(200)
    |> get_in(["result", "content", Access.at(0), "text"])
    |> Jason.decode!()
  end

  ## A card read under the job ---------------------------------------------------

  defp runner_claim(ctx, card) do
    job = queue(card)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> put_req_header("content-type", "text/plain")
      |> post("/api/runner/claim?wait=0")

    assert conn.status == 200
    assert get_resp_header(conn, "x-job-id") == [to_string(job.id)]
    Repo.get!(Job, job.id)
  end

  defp stub_read do
    AIStub.reply_with(%{
      "requirement" => @asked,
      "files" => [],
      "expected_behaviour" => [],
      "acceptance" => [],
      "context" => [],
      "open_questions" => [],
      "agent_directed" => false
    })
  end

  defp outsider_comment(card) do
    at = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

    Repo.insert!(%Comment{
      card_id: card.id,
      body: "*Sent by someone.*\n\nSECRET-COMMENT",
      user_id: nil,
      inserted_at: at,
      updated_at: at
    })
  end

  defp read_under(conn, card, job) do
    conn
    |> put_req_header("x-slipdock-job", to_string(job.id))
    |> get("/api/cards/#{card.id}")
    |> response(200)
  end

  describe "a card read naming an anyone job" do
    test "REST returns the fields its claim quoted, not the card's text", ctx do
      card = anyone_card(ctx)
      outsider_comment(card)
      stub_read()
      job = runner_claim(ctx, card)
      assert job.prompt_tier == "anyone"

      body = read_under(ctx.conn, card, job)
      refute_secrets(body)
      read = Jason.decode!(body)["card"]

      assert read["id"] == card.id
      assert read["title"] == nil
      assert read["bar"] == nil
      assert read["comments"] == []
      assert read["text_withheld"] == true
      assert read["quarantined"]["requirement"] == @asked
      assert read["description"] =~ "Quoted from an untrusted author"
      assert read["description"] =~ "> " <> @asked
      assert read["as_at_claim"] == DateTime.to_iso8601(job.claimed_at)
      # It returned no card text, so it marks nothing.
      assert Repo.get!(Job, job.id).marked_at == nil

      # Without the job, the owner reads the card as it is.
      plain = ctx.conn |> get("/api/cards/#{card.id}") |> json_response(200) |> Map.fetch!("card")
      assert plain["title"] == "Outsider title"
    end

    test "MCP get_card returns the same", ctx do
      card = anyone_card(ctx)
      outsider_comment(card)
      stub_read()
      job = runner_claim(ctx, card)

      read = ctx.conn |> put_req_header("x-slipdock-job", to_string(job.id)) |> mcp_card(card)

      refute_secrets(read)
      assert read["title"] == nil
      assert read["quarantined"]["requirement"] == @asked
      assert read["url"] =~ "/cards/#{card.id}"
    end

    test "with no read kept, none of the text and no fields", ctx do
      card = anyone_card(ctx)
      stub_read()
      job = runner_claim(ctx, card)
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [quarantined_read: nil])

      read = Jason.decode!(read_under(ctx.conn, card, job))["card"]
      refute_secrets(read)
      assert read["quarantined"] == nil
      assert read["description"] =~ "none of it is given to you"

      # Nor a read that spoke to an agent, whatever fields it kept.
      directed = %{"requirement" => @asked, "acceptance" => [], "agent_directed" => true}
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [quarantined_read: directed])

      read = Jason.decode!(read_under(ctx.conn, card, job))["card"]
      assert read["quarantined"] == nil
      refute read["description"] =~ @asked
    end

    test "an owner's job still reads its card as at claim", ctx do
      card = card_by(ctx, ctx.owner, "Owner title")
      job = runner_claim(ctx, card)
      assert job.prompt_tier == "owner"

      read = Jason.decode!(read_under(ctx.conn, card, job))["card"]
      assert read["title"] == "Owner title"
      refute Map.has_key?(read, "quarantined")
      assert read["as_at_claim"]
    end

    test "another card read under the anyone job is read as ever", ctx do
      card = anyone_card(ctx)
      stub_read()
      job = runner_claim(ctx, card)
      other = card_by(ctx, ctx.owner, "Owner title")

      read = Jason.decode!(read_under(ctx.conn, other, job))["card"]
      assert read["title"] == "Owner title"
      refute Map.has_key?(read, "quarantined")
    end
  end
end
