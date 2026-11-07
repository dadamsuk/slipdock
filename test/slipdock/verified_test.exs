defmodule Slipdock.VerifiedTest do
  @moduledoc """
  A card's profile once work starts (#2016): on a board with profiles on, an
  agent may raise a started card's profile (or one a person set) but not
  lower or clear it; a person may do either. Profiles off, or a card not yet
  started, leaves an agent free. The refusal reaches every door from the
  core: REST, MCP's update_card and the CLI run as an agent (the CLI shows
  the API's message).
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Profiled", "code" => unique_code()}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    {token, _} = Accounts.create_api_token(user, "bot")

    api =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    cli_agent =
      api
      |> put_req_header("x-slipdock-client", "cli")
      |> put_req_header("x-slipdock-agent", "1")

    cli_person = put_req_header(api, "x-slipdock-client", "cli")

    %{
      board: board,
      todo: todo,
      doing: doing,
      agent: Actor.runner(user.id, nil, "bot"),
      person: Actor.web(user),
      api: api,
      cli_agent: cli_agent,
      cli_person: cli_person
    }
  end

  defp profiles_on(ctx) do
    {:ok, board} = Boards.update_board(ctx.board, %{"profiles" => true})
    board
  end

  # A card an agent has started: on a profiles board it gets its profile
  # inferred, or keeps the one given.
  defp started(ctx, attrs) do
    card = card_fixture(ctx.todo, Map.merge(%{"title" => "Work"}, attrs))
    :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
    Repo.get!(Card, card.id)
  end

  defp profile(card), do: Repo.get!(Card, card.id).profile

  defp refused_message({:error, %Ecto.Changeset{} = cs}) do
    assert %{profile: [message]} = Slipdock.DataCase.errors_on(cs)
    message
  end

  defp mcp(conn, tool, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: tool, arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  describe "a started card on a profiles board" do
    setup ctx, do: %{board: profiles_on(ctx)}

    test "an agent may raise the profile, any case", ctx do
      card = started(ctx, %{"profile" => "fix"})
      {:ok, card} = Boards.update_card(card, %{"profile" => "Schema"}, actor: ctx.agent)
      assert card.profile == "schema"
      {:ok, card} = Boards.update_card(card, %{"profile" => "security"}, actor: ctx.agent)
      assert card.profile == "security"
    end

    test "spike is above feature: an agent may raise feature to spike, not lower it back",
         ctx do
      card = started(ctx, %{"profile" => "feature"})
      {:ok, card} = Boards.update_card(card, %{"profile" => "spike"}, actor: ctx.agent)
      assert card.profile == "spike"

      assert {:error, _} =
               Boards.update_card(card, %{"profile" => "feature"}, actor: ctx.agent)

      assert profile(card) == "spike"
    end

    test "an agent can't lower it: refused naming the card, and the card is unchanged", ctx do
      card = started(ctx, %{"profile" => "schema"})
      result = Boards.update_card(card, %{"profile" => "docs"}, actor: ctx.agent)
      message = refused_message(result)

      assert message =~ "##{card.id}"
      assert message =~ "schema to docs"
      assert message =~ "only a person can lower or clear it"
      assert profile(card) == "schema"
    end

    test "an agent can't clear it, with a blank or a nil", ctx do
      card = started(ctx, %{"profile" => "security"})

      for blank <- ["", "  ", nil] do
        result = Boards.update_card(card, %{"profile" => blank}, actor: ctx.agent)
        message = refused_message(result)
        assert message =~ "##{card.id}"
        assert message =~ "can't be cleared"
        assert profile(card) == "security"
      end
    end

    test "the inferred profile is held too: an agent can't lower one inferred at its start",
         ctx do
      card =
        card_fixture(ctx.todo, %{"title" => "Migrate", "paths" => ["priv/repo/migrations/x.exs"]})

      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
      card = Repo.get!(Card, card.id)
      assert {card.profile, card.profile_source} == {"schema", "inferred"}

      assert {:error, _} = Boards.update_card(card, %{"profile" => "fix"}, actor: ctx.agent)
      assert profile(card) == "schema"
    end

    test "a started card with no profile is judged by the one it would infer", ctx do
      # Started by a person, which infers nothing.
      card =
        card_fixture(ctx.todo, %{"title" => "Migrate", "paths" => ["priv/repo/migrations/x.exs"]})

      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.person)
      card = Repo.get!(Card, card.id)
      assert card.profile == nil

      message =
        refused_message(Boards.update_card(card, %{"profile" => "docs"}, actor: ctx.agent))

      assert message =~ "schema to docs"

      {:ok, card} = Boards.update_card(card, %{"profile" => "security"}, actor: ctx.agent)
      assert card.profile == "security"
    end

    test "keeping the same profile, or writing other fields, is fine", ctx do
      card = started(ctx, %{"profile" => "schema"})
      {:ok, card} = Boards.update_card(card, %{"profile" => "schema"}, actor: ctx.agent)
      {:ok, card} = Boards.update_card(card, %{"title" => "Again"}, actor: ctx.agent)
      assert {card.title, card.profile} == {"Again", "schema"}
    end

    test "an unknown name is still refused with the list, not as a lowering", ctx do
      card = started(ctx, %{"profile" => "schema"})

      message =
        refused_message(Boards.update_card(card, %{"profile" => "chore"}, actor: ctx.agent))

      assert message =~ "security, schema, feature, fix, docs, spike"
    end

    test "a person may lower or clear it, and so may the assistant", ctx do
      card = started(ctx, %{"profile" => "security"})
      {:ok, card} = Boards.update_card(card, %{"profile" => "docs"}, actor: ctx.person)
      assert card.profile == "docs"
      {:ok, card} = Boards.update_card(card, %{"profile" => ""}, actor: ctx.person)
      assert card.profile == nil

      {:ok, card} = Boards.update_card(card, %{"profile" => "schema"}, actor: ctx.person)

      {:ok, card} =
        Boards.update_card(card, %{"profile" => "fix"}, actor: Actor.assistant(ctx.user))

      assert card.profile == "fix"
    end

    test "a card sent back to the ready list after a rejection stays held", ctx do
      card = started(ctx, %{"profile" => "schema"})
      card = card |> Ecto.Changeset.change(verify_state: "rejected") |> Repo.update!()
      :ok = Boards.move_card(card.id, ctx.todo.id, nil, actor: ctx.person)
      card = Repo.get!(Card, card.id)

      assert {:error, _} = Boards.update_card(card, %{"profile" => "docs"}, actor: ctx.agent)
    end

    test "an agent's own raise, then a move back out of the doing list, still holds it", ctx do
      refute ctx.board.bar_required

      card =
        card_fixture(ctx.todo, %{"title" => "Migrate", "paths" => ["priv/repo/migrations/x.exs"]})

      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
      card = Repo.get!(Card, card.id)
      assert {card.profile, card.profile_source} == {"schema", "inferred"}

      {:ok, card} = Boards.update_card(card, %{"profile" => "security"}, actor: ctx.agent)
      assert card.profile_source == "agent"

      :ok = Boards.move_card(card.id, ctx.todo.id, nil, actor: ctx.agent)
      card = Repo.get!(Card, card.id)
      assert card.column_id == ctx.todo.id

      message =
        refused_message(Boards.update_card(card, %{"profile" => "docs"}, actor: ctx.agent))

      assert message =~ "##{card.id}"
      assert message =~ "security to docs"
      assert {:error, _} = Boards.update_card(card, %{"profile" => ""}, actor: ctx.agent)
      assert profile(card) == "security"
    end

    test "a person's start with nothing stored stays held after an agent moves it back", ctx do
      card =
        card_fixture(ctx.todo, %{"title" => "Migrate", "paths" => ["priv/repo/migrations/x.exs"]})

      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.person)
      :ok = Boards.move_card(card.id, ctx.todo.id, nil, actor: ctx.agent)
      card = Repo.get!(Card, card.id)
      assert {card.profile, card.column_id} == {nil, ctx.todo.id}

      message =
        refused_message(Boards.update_card(card, %{"profile" => "docs"}, actor: ctx.agent))

      assert message =~ "schema to docs"
      assert profile(card) == nil

      {:ok, card} = Boards.update_card(card, %{"profile" => "security"}, actor: ctx.agent)
      assert card.profile == "security"
    end

    test "a card created straight into the doing list is started", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Work", "profile" => "schema"})
      :ok = Boards.move_card(card.id, ctx.todo.id, nil, actor: ctx.agent)
      card = Repo.get!(Card, card.id)

      assert {:error, _} = Boards.update_card(card, %{"profile" => "docs"}, actor: ctx.agent)
      assert profile(card) == "schema"
    end
  end

  describe "before work starts" do
    test "a card moved between lists that aren't doing ones isn't started", ctx do
      board = profiles_on(ctx)
      [backlog, todo, _doing, _done] = board.columns
      card = card_fixture(backlog, %{"title" => "Work"})
      {:ok, card} = Boards.update_card(card, %{"profile" => "schema"}, actor: ctx.agent)
      :ok = Boards.move_card(card.id, todo.id, nil, actor: ctx.agent)
      card = Repo.get!(Card, card.id)

      {:ok, card} = Boards.update_card(card, %{"profile" => "docs"}, actor: ctx.agent)
      assert card.profile == "docs"
    end

    setup ctx, do: %{board: profiles_on(ctx)}

    test "an agent may lower or clear a card's profile it set itself", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Work"})
      {:ok, card} = Boards.update_card(card, %{"profile" => "schema"}, actor: ctx.agent)
      assert card.profile_source == "agent"
      {:ok, card} = Boards.update_card(card, %{"profile" => "docs"}, actor: ctx.agent)
      assert card.profile == "docs"
      {:ok, card} = Boards.update_card(card, %{"profile" => ""}, actor: ctx.agent)
      assert card.profile == nil
    end

    test "a profile a person set is held, though the card hasn't started", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Work"})
      {:ok, card} = Boards.update_card(card, %{"profile" => "schema"}, actor: ctx.person)
      assert card.profile_source == "person"

      message = refused_message(Boards.update_card(card, %{"profile" => "fix"}, actor: ctx.agent))
      assert message =~ "##{card.id}"
      assert {:error, _} = Boards.update_card(card, %{"profile" => nil}, actor: ctx.agent)

      {:ok, card} = Boards.update_card(card, %{"profile" => "security"}, actor: ctx.agent)
      assert card.profile == "security"
    end
  end

  describe "with profiles off" do
    test "an agent may lower or clear a started card's profile", ctx do
      refute ctx.board.profiles
      card = started(ctx, %{"profile" => "security"})
      {:ok, card} = Boards.update_card(card, %{"profile" => "docs"}, actor: ctx.agent)
      assert card.profile == "docs"
      {:ok, card} = Boards.update_card(card, %{"profile" => ""}, actor: ctx.agent)
      assert card.profile == nil
    end
  end

  describe "profile_message/3" do
    setup ctx, do: %{board: profiles_on(ctx)}

    test "nil for anything but an agent lowering or clearing", ctx do
      card = started(ctx, %{"profile" => "feature"})
      assert Verified.profile_message(card, "docs", ctx.person) == nil
      assert Verified.profile_message(card, "security", ctx.agent) == nil
      assert Verified.profile_message(card, "feature", ctx.agent) == nil
      assert Verified.profile_message(card, "docs", ctx.agent) =~ "feature to docs"
      assert Verified.profile_message(card, "", ctx.agent) =~ "can't be cleared"
    end
  end

  describe "the doors" do
    setup ctx, do: %{board: profiles_on(ctx)}

    test "REST: 422 with the message, and a person on the CLI may lower it", ctx do
      card = started(ctx, %{"profile" => "schema"})

      body =
        ctx.api
        |> patch(~p"/api/cards/#{card.id}", %{"profile" => "docs"})
        |> json_response(422)

      assert inspect(body) =~ "##{card.id}"
      assert inspect(body) =~ "only a person can lower or clear it"

      body =
        ctx.cli_agent
        |> patch(~p"/api/cards/#{card.id}", %{"profile" => ""})
        |> json_response(422)

      assert inspect(body) =~ "can't be cleared"
      assert profile(card) == "schema"

      ctx.api
      |> patch(~p"/api/cards/#{card.id}", %{"profile" => "security"})
      |> json_response(200)

      ctx.cli_person
      |> patch(~p"/api/cards/#{card.id}", %{"profile" => "docs"})
      |> json_response(200)

      assert profile(card) == "docs"
    end

    test "MCP update_card: an error naming the card", ctx do
      card = started(ctx, %{"profile" => "schema"})

      result = mcp(ctx.api, "update_card", %{card: card.id, profile: "docs"})
      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "##{card.id}"
      assert text =~ "only a person can lower or clear it"
      assert profile(card) == "schema"

      result = mcp(ctx.api, "update_card", %{card: card.id, profile: "security"})
      assert result["isError"] == false
      assert profile(card) == "security"
    end
  end
end
