defmodule Slipdock.ProfilesTest do
  @moduledoc """
  Profiles 1 (#1951): the six profiles and their inference, strict first,
  with the size bump; the board's `profiles` switch, off by default; the
  card's profile, set, cleared and refused; and inference when an agent
  claims or starts a card, which a person, the assistant or a board with
  profiles off never sets off.
  """
  # Sync: the export/import test derives board codes, as the other import tests.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Portable, Profiles, Repo, Runners}
  alias Slipdock.Boards.Card

  describe "infer/3" do
    test "names the six profiles, strictest first" do
      assert Profiles.names() == ~w(security schema feature fix docs spike)
      assert Enum.all?(Profiles.names(), &Profiles.name?/1)
      refute Profiles.name?("chore")
      refute Profiles.name?(nil)
    end

    test "security: tagged security, or a path in an auth, access, token or egress module" do
      assert Profiles.infer(["docs/x.md"], ["Security"]) == "security"
      assert Profiles.infer(["lib/slipdock/access.ex"], []) == "security"
      assert Profiles.infer(["lib/slipdock_web/user_auth.ex"], []) == "security"
      assert Profiles.infer(["lib/slipdock/accounts/user_token.ex"], []) == "security"
      assert Profiles.infer(["lib/slipdock/egress.ex"], []) == "security"
      assert Profiles.infer(["lib/slipdock/oauth/**"], []) == "security"
      # A word inside another isn't one: "accessible" is not "access".
      assert Profiles.infer(["lib/slipdock_web/accessible_menu.ex"], []) == "feature"
    end

    test "security beats schema, and schema beats spike, fix and docs" do
      assert Profiles.infer(["priv/repo/migrations/1_x.exs", "lib/slipdock/access.ex"], []) ==
               "security"

      assert Profiles.infer(["priv/repo/migrations/**"], ["spike", "bug"]) == "schema"
    end

    test "schema: a migration or a schema file; with a docs file it is still schema" do
      assert Profiles.infer(["priv/repo/migrations/2026_add.exs"], []) == "schema"
      assert Profiles.infer(["priv/repo/structure.sql"], []) == "schema"
      assert Profiles.infer(["db/schema.rb"], []) == "schema"
      assert Profiles.infer(["priv/repo/migrations/**", "docs/manual.md"], []) == "schema"
    end

    test "spike only by tag, before fix" do
      assert Profiles.infer(["lib/x.ex"], ["spike"]) == "spike"
      assert Profiles.infer(["lib/x.ex"], ["spike", "bug"]) == "spike"
      assert Profiles.infer(["spike/notes.ex"], []) == "feature"
    end

    test "fix: tagged bug, docs paths and all" do
      assert Profiles.infer(["lib/x.ex"], ["bug"]) == "fix"
      assert Profiles.infer(["docs/manual.md"], ["bug"]) == "fix"
    end

    test "docs: every path under docs/, a README.md or a .md file" do
      assert Profiles.infer(["docs/**"], []) == "docs"

      assert Profiles.infer(["README.md", "docs/agents.md", "priv/skills/x/SKILL.md"], []) ==
               "docs"

      assert Profiles.infer(["docs/manual.md", "lib/x.ex"], []) == "feature"
    end

    test "feature: anything else, a card with no paths or tags included" do
      assert Profiles.infer([], []) == "feature"
      assert Profiles.infer(nil, nil) == "feature"
      assert Profiles.infer(["lib/slipdock/boards.ex"], ["ux"]) == "feature"
    end

    test "a diff over the size limit bumps fix and docs to feature, and nothing else" do
      limit = Profiles.size_limit()
      assert limit == 400

      assert Profiles.infer(["docs/**"], [], diff_lines: limit) == "docs"
      assert Profiles.infer(["docs/**"], [], diff_lines: limit + 1) == "feature"
      assert Profiles.infer(["lib/x.ex"], ["bug"], diff_lines: limit + 1) == "feature"
      assert Profiles.infer(["lib/x.ex"], ["bug"], diff_lines: 10) == "fix"
      assert Profiles.infer(["priv/repo/migrations/**"], [], diff_lines: 5000) == "schema"
      assert Profiles.infer(["lib/x.ex"], ["spike"], diff_lines: 5000) == "spike"
    end
  end

  describe "recheck/4: the actual change (#2017)" do
    test "more than the size limit raises fix and docs to feature, with the count" do
      limit = Profiles.size_limit()

      assert Profiles.recheck("fix", "inferred", limit + 212, ["lib/x.ex"]) ==
               {"feature", "#{limit + 212} lines changed"}

      assert Profiles.recheck("docs", "agent", limit + 1, []) ==
               {"feature", "#{limit + 1} lines changed"}

      assert Profiles.recheck("fix", "rule", limit + 1, []) == {"feature", "401 lines changed"}
      assert Profiles.recheck("fix", "inferred", limit, ["lib/x.ex"]) == nil
      assert Profiles.recheck("fix", "inferred", nil, ["lib/x.ex"]) == nil
    end

    test "a person's fix or docs survives the size" do
      assert Profiles.recheck("fix", "person", 5000, ["lib/x.ex"]) == nil
      assert Profiles.recheck("docs", "person", 5000, ["docs/a.md"]) == nil
    end

    test "a migration raises to schema and a security path to security, whoever set it" do
      migration = "priv/repo/migrations/20261107_add.exs"

      assert Profiles.recheck("docs", "person", 3, ["docs/a.md", migration]) ==
               {"schema", "changes #{migration}"}

      assert Profiles.recheck("fix", "person", 3, ["lib/slipdock/access.ex", migration]) ==
               {"security", "changes lib/slipdock/access.ex"}

      assert Profiles.recheck("spike", "agent", 3, [migration]) ==
               {"schema", "changes #{migration}"}

      # Strictest first: a migration in a big fix is schema, not feature.
      assert Profiles.recheck("fix", "inferred", 900, [migration]) ==
               {"schema", "changes #{migration}"}
    end

    test "never lower, and nothing raised where the change is no stricter" do
      assert Profiles.recheck("security", "inferred", 5000, ["priv/repo/migrations/1.exs"]) ==
               nil

      assert Profiles.recheck("schema", "inferred", 5000, ["docs/a.md"]) == nil
      assert Profiles.recheck("schema", "inferred", 1, ["priv/repo/migrations/1.exs"]) == nil
      assert Profiles.recheck("feature", "inferred", 5000, ["docs/a.md"]) == nil
      assert Profiles.recheck("spike", "inferred", 5000, []) == nil
      assert Profiles.recheck("docs", "inferred", 2, ["docs/a.md", "", nil]) == nil
    end

    test "rank orders them strictest last, no profile below them all" do
      assert Enum.sort_by(Profiles.names(), &Profiles.rank/1) ==
               ~w(docs fix feature spike schema security)

      assert Profiles.rank(nil) < Profiles.rank("docs")
    end
  end

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Profiled", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    agent = Actor.runner(owner.id, nil, "bot")
    %{owner: owner, board: board, todo: todo, doing: doing, agent: agent}
  end

  defp profiles_on(ctx) do
    {:ok, board} = Boards.update_board(ctx.board, %{"profiles" => true})
    board
  end

  describe "the setting and the card's field" do
    test "profiles is off by default, and turns on and off", ctx do
      refute ctx.board.profiles
      assert profiles_on(ctx).profiles
      {:ok, board} = Boards.update_board(ctx.board, %{"profiles" => false})
      refute board.profiles
    end

    test "a card takes a profile, any case, and a blank clears it", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Work", "profile" => "Schema"})
      assert card.profile == "schema"
      {:ok, card} = Boards.update_card(card, %{"profile" => ""})
      assert card.profile == nil
    end

    test "an unknown profile is refused with the list", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Work"})
      assert {:error, cs} = Boards.update_card(card, %{"profile" => "chore"})
      assert %{profile: [message]} = errors_on(cs)
      assert message =~ "security, schema, feature, fix, docs, spike"
      assert Repo.reload!(card).profile == nil
    end

    test "sub-boards inherit the switch", ctx do
      profiles_on(ctx)
      card = card_fixture(ctx.todo, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(card, t)
      assert sub.profiles
    end

    test "export and import carry the switch and the profile, and drop an unknown one", ctx do
      board = profiles_on(ctx)
      card_fixture(ctx.todo, %{"title" => "Typed", "profile" => "docs"})
      card_fixture(ctx.todo, %{"title" => "Untyped"})

      doc = Portable.export(ctx.owner, boards: [Boards.get_board!(board.id)])
      assert hd(doc.boards).root.profiles == true

      json =
        doc
        |> Jason.encode!()
        |> Jason.decode!()
        |> mark_untyped()
        |> Jason.encode!()

      {:ok, report} = Portable.import(ctx.owner, json)
      imported = Boards.get_board!(hd(report.boards).id)
      assert imported.profiles
      assert Repo.get_by!(Card, board_id: imported.id, title: "Typed").profile == "docs"
      assert Repo.get_by!(Card, board_id: imported.id, title: "Untyped").profile == nil
    end
  end

  # Gives the exported card "Untyped" a profile no card takes.
  defp mark_untyped(%{"title" => "Untyped"} = card), do: Map.put(card, "profile", "chore")
  defp mark_untyped(%{} = map), do: Map.new(map, fn {k, v} -> {k, mark_untyped(v)} end)
  defp mark_untyped(list) when is_list(list), do: Enum.map(list, &mark_untyped/1)
  defp mark_untyped(other), do: other

  defp tagged(card, ctx, name) do
    tag = tag_fixture(ctx.board, name)
    {:ok, _} = Boards.set_card_tags(card, [tag])
    card
  end

  describe "inferred when an agent starts or claims a card" do
    test "an agent moving it into a doing list gives it one, from its paths and tags", ctx do
      profiles_on(ctx)
      card = card_fixture(ctx.todo, %{"title" => "Migrate", "paths" => "priv/repo/migrations/**"})
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
      assert Repo.reload!(card).profile == "schema"

      bug = ctx.todo |> card_fixture(%{"title" => "Bug"}) |> tagged(ctx, "bug")
      :ok = Boards.move_card(bug.id, ctx.doing.id, nil, actor: ctx.agent)
      assert Repo.reload!(bug).profile == "fix"
    end

    test "a profile already set is kept", ctx do
      profiles_on(ctx)
      card = card_fixture(ctx.todo, %{"title" => "Set", "profile" => "spike"})
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
      assert Repo.reload!(card).profile == "spike"
    end

    test "a person, the assistant or a rule starting it infers nothing", ctx do
      profiles_on(ctx)

      for actor <- [Actor.web(ctx.owner), Actor.assistant(ctx.owner), Actor.automation()] do
        card = card_fixture(ctx.todo, %{"title" => "Theirs"})
        :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: actor)
        assert Repo.reload!(card).profile == nil
      end
    end

    test "with profiles off nothing is inferred", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Off"})
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)
      assert Repo.reload!(card).profile == nil
    end

    test "a move into a list that isn't a doing list infers nothing", ctx do
      profiles_on(ctx)
      [backlog | _] = ctx.board.columns
      card = card_fixture(ctx.todo, %{"title" => "Back"})
      :ok = Boards.move_card(card.id, backlog.id, nil, actor: ctx.agent)
      assert Repo.reload!(card).profile == nil
    end

    test "an agent creating a card in a doing list starts it", ctx do
      profiles_on(ctx)

      {:ok, card} =
        Boards.create_card(ctx.doing, %{"title" => "Docs", "paths" => "docs/**"},
          actor: ctx.agent
        )

      assert Repo.reload!(card).profile == "docs"

      {:ok, card} = Boards.create_card(ctx.todo, %{"title" => "Later"}, actor: ctx.agent)
      assert Repo.reload!(card).profile == nil
    end

    test "the inference is logged as the card's activity", ctx do
      profiles_on(ctx)
      card = card_fixture(ctx.todo, %{"title" => "Logged"})
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: ctx.agent)

      assert Enum.any?(
               Boards.list_activities(ctx.board.id, 50, card.id),
               &(&1.message == "profile inferred: feature")
             )
    end

    test "a runner claiming the card's job gives it one; a verify job doesn't", ctx do
      profiles_on(ctx)
      {:ok, runner, _token} = Runners.create_runner(ctx.board, %{"name" => "r", "pool" => "dev"})

      card = card_fixture(ctx.todo, %{"title" => "Queued", "paths" => "docs/**"})
      {:ok, _job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
      assert %{card: claimed} = Runners.claim(runner)
      assert claimed.profile == "docs"

      checked = card_fixture(ctx.todo, %{"title" => "Checked"})
      {:ok, _job} = Runners.queue(checked, %{pool: "dev", kind: "verify", prompt: "Check."})
      assert %{card: _} = Runners.claim(runner)
      assert Repo.reload!(checked).profile == nil
    end
  end
end
