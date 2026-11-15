defmodule Slipdock.PolicyOwnerAdminTest do
  @moduledoc """
  Policy 7 (#3174): the owner and admin writes (automations, findings, the
  gardener, health, the overseer, skills, Tools and the server's settings)
  ask `Slipdock.Policy` themselves. For every action in the table's rows
  for them (`Slipdock.PolicyActions.owner_admin/0`), the context is called
  with no door in the way, the actor set as a door sets it: the level the
  action needs passes; a person short of it, a read-only token, and a level
  lowered after the actor was set are each refused (ARCH-8).

  A person-only decision (#2668) passes only a person in the web app: the
  board's owner over MCP or REST is refused, whatever the level.

  Every guarded function is called once more by somebody short of it, so a
  write that stops asking fails here by name.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{
    Access,
    Accounts,
    Actor,
    Automations,
    Findings,
    Gardener,
    Health,
    Overseer,
    Policy,
    Repo,
    Settings,
    SkillRegistry,
    Tools
  }

  alias Slipdock.Findings.Finding
  alias Slipdock.Gardener.Suggestion
  alias Slipdock.Policy.Refused

  @actions Slipdock.PolicyActions.owner_admin()

  @spec_ok %{
    "trigger" => %{"type" => "card_completed"},
    "actions" => [%{"type" => "comment", "body" => "Closed."}]
  }

  setup do
    owner = user_fixture("owner7.policy.#{System.unique_integer([:positive])}@example.com")
    board = board_fixture(%{"name" => "Policy seven"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Card"})
    rule = rule_fixture(board, @spec_ok)
    %{owner: owner, board: board, card: card, rule: rule, entry: seed_entry()}
  end

  defp as(user, token \\ nil), do: Actor.put(Actor.web(user), nil, {user, token})
  defp fixture(fun), do: Policy.as_system("a test fixture", fun)

  defp stranger,
    do: user_fixture("owner7.policy.#{System.unique_integer([:positive])}@example.com")

  defp person(ctx, level) do
    user = stranger()
    {:ok, grant} = fixture(fn -> Access.grant(ctx.board, user, level, ctx.owner) end)
    {user, grant}
  end

  defp admin do
    {:ok, admin} = fixture(fn -> Accounts.promote(stranger()) end)
    admin
  end

  defp read_token(user) do
    {_plain, %Accounts.UserToken{} = token} =
      fixture(fn -> Accounts.create_api_token(user, "reader", scope: "read") end)

    token
  end

  # A seed's skill, which everybody sees.
  defp seed_entry do
    Slipdock.SkillRegistryStub.start(%{})
    repo = "octo#{System.unique_integer([:positive])}/skills"

    Slipdock.SkillRegistryStub.put(repo, %{
      files: %{
        "grilling/SKILL.md" => "---\nname: grilling\ndescription: Asks.\n---\n\nAsk one.\n"
      }
    })

    {:ok, %{entries: [entry]}} =
      fixture(fn -> SkillRegistry.add_source(nil, "https://github.com/#{repo}") end)

    entry
  end

  defp refused?(result, action, by),
    do: match?({:error, %Refused{action: ^action, by: ^by}}, result)

  defp passed?(result), do: not match?({:error, %Refused{}}, result)

  defp suggestion(ctx, check \\ "stale_cards") do
    Repo.insert!(%Suggestion{
      board_id: ctx.board.id,
      check: check,
      fingerprint: "p#{System.unique_integer([:positive])}",
      explanation: "tidy",
      subject: %{},
      proposal: []
    })
  end

  defp finding(ctx) do
    Repo.insert!(%Finding{
      board_id: ctx.board.id,
      card_id: ctx.card.id,
      kind: "gotcha",
      text: "a thing #{System.unique_integer([:positive])}",
      status: "open",
      source: "comment",
      count: 1
    })
  end

  # Who passes, and who is one short, for the level an action needs.
  defp right(ctx, :owner), do: {ctx.owner, nil}
  defp right(ctx, :write), do: person(ctx, "write")
  defp short(ctx, :owner), do: ctx |> person("write") |> elem(0)
  defp short(ctx, :write), do: ctx |> person("comment") |> elem(0)

  # Lowers `user` below what an action needs, after the actor was set.
  defp lower(ctx, :owner, _user, _grant),
    do: Repo.update!(Ecto.Changeset.change(ctx.board, owner_id: stranger().id))

  defp lower(ctx, :write, user, _grant),
    do: {:ok, _} = fixture(fn -> Access.grant(ctx.board, user, "comment", ctx.owner) end)

  # One write per board-scoped action, by `user`.
  defp act(:edit_rule, ctx, _user), do: Automations.toggle_rule(ctx.rule)
  defp act(:triage_finding, ctx, _user), do: Findings.triage(finding(ctx), "dismiss")

  defp act(:decide_suggestion, ctx, user),
    do: Gardener.dismiss(suggestion(ctx), user, actor: Actor.web(user))

  defp act(:propose_edit, ctx, user),
    do:
      Gardener.propose(ctx.board, user, %{
        "explanation" => "x",
        "steps" => [%{"op" => "comment", "card" => ctx.card.id, "body" => "b"}]
      })

  defp act(:run_board_check, ctx, _user), do: Health.run(ctx.board)

  defp act(:enable_skill, ctx, user),
    do: SkillRegistry.enable(user, ctx.board, ctx.entry.id, ctx.entry.content_hash)

  @board_rows ~w(edit_rule triage_finding decide_suggestion propose_edit run_board_check enable_skill)a

  # The gardener's own check (`can_write/2`) refuses a person short of write
  # first, in its own words; the policy is what a token's scope meets.
  @own_check_first ~w(decide_suggestion propose_edit enable_skill)a

  test "the table's owner and admin rows are the ones tested here" do
    for {action, need} <- @actions do
      assert {_scope, ^need} = Policy.rules()[action], "#{action} needs #{need} in the table"
    end

    others =
      Slipdock.PolicyActions.tags() ++
        Keyword.keys(Slipdock.PolicyActions.boards()) ++
        Keyword.keys(Slipdock.PolicyActions.wiki()) ++
        Keyword.keys(Slipdock.PolicyActions.own())

    refute Enum.any?(Keyword.keys(@actions), &(&1 in others))
  end

  for action <- @board_rows do
    describe "#{action}" do
      test "passes at the level it needs", ctx do
        {user, _} = right(ctx, @actions[unquote(action)])
        as(user)
        assert passed?(act(unquote(action), ctx, user))
      end

      test "a read-only token is refused, named as the token", ctx do
        {user, _} = right(ctx, @actions[unquote(action)])
        as(user, read_token(user))
        assert refused?(act(unquote(action), ctx, user), unquote(action), :token)
      end
    end
  end

  for action <- @board_rows -- @own_check_first do
    describe "#{action}, by level" do
      test "a person short of it is refused", ctx do
        user = short(ctx, @actions[unquote(action)])
        as(user)
        assert refused?(act(unquote(action), ctx, user), unquote(action), :user)
      end

      test "a level lowered after the actor was set is read at the write", ctx do
        need = @actions[unquote(action)]
        {user, grant} = right(ctx, need)
        as(user)
        lower(ctx, need, user, grant)
        assert refused?(act(unquote(action), ctx, user), unquote(action), :user)
      end
    end
  end

  describe "a person-only decision (decide_in_person)" do
    setup ctx do
      %{proposal: suggestion(ctx, "proposal")}
    end

    test "the board's owner in the web app passes", ctx do
      as(ctx.owner)

      assert passed?(Gardener.dismiss(ctx.proposal, ctx.owner, actor: Actor.web(ctx.owner)))
    end

    test "the owner over MCP is refused by the policy, after the Tidy-up page's link", ctx do
      as(ctx.owner)
      mcp = Actor.mcp(%{user: ctx.owner})

      assert {:error, message} = Gardener.dismiss(ctx.proposal, ctx.owner, actor: mcp)
      assert message =~ "/boards/#{ctx.board.id}/tidy"

      # The policy row on its own, as `asks/2` asks it.
      assert refused?(
               Policy.authorize(:decide_in_person, ctx.proposal, actor: mcp),
               :decide_in_person,
               :user
             )
    end

    # A door that names a web actor with nobody in it, while the process acts
    # over MCP: the gardener's own check reads the label, the policy reads
    # who is acting.
    test "a web label with nobody in it doesn't pass over MCP", ctx do
      Actor.put(Actor.mcp(%{user: ctx.owner}), nil, {ctx.owner, nil})
      label = %{kind: "human", via: "web", user_id: nil}

      assert refused?(
               Gardener.dismiss(ctx.proposal, ctx.owner, actor: label),
               :decide_in_person,
               :user
             )
    end

    test "a rule never passes it, though a rule passes the board's other rows", ctx do
      rule = Actor.automation()
      refute Policy.can?(:decide_in_person, ctx.proposal, actor: rule)
      assert Policy.can?(:decide_suggestion, ctx.proposal, actor: rule)
    end

    test "a web person short of write is refused", ctx do
      user = short(ctx, :write)
      as(user)
      web = Actor.web(user)

      assert refused?(
               Policy.authorize(:decide_in_person, ctx.proposal, actor: web),
               :decide_in_person,
               :user
             )
    end
  end

  describe "a person's own (own_alert, own_source, own_tool)" do
    test "the person passes, somebody else and a read-only token are refused", ctx do
      user = stranger()
      as(user)
      assert passed?(Automations.dismiss_all_alerts(user))
      assert passed?(SkillRegistry.add_source(user, "not a url"))
      assert passed?(Tools.publish(user, "not a package"))

      as(stranger())
      assert refused?(Automations.dismiss_all_alerts(user), :own_alert, :user)
      assert refused?(SkillRegistry.add_source(user, "x"), :own_source, :user)
      assert refused?(Tools.publish(user, "x"), :own_tool, :user)
      assert refused?(Tools.install_board(user, %Tools.Tool{id: -1}), :own_tool, :user)

      as(user, read_token(user))
      assert refused?(Automations.dismiss_alert(user, 1), :own_alert, :token)
      assert refused?(Tools.publish(user, "x"), :own_tool, :token)
      _ = ctx
    end
  end

  describe "the server's settings (administer)" do
    test "an admin passes; somebody who isn't, or an admin demoted since, is refused" do
      a = admin()
      as(a)
      assert passed?(Settings.update(%{}))

      as(stranger())
      assert refused?(Settings.update(%{}), :administer, :user)
      assert refused?(Settings.add_allowlist_entry("x@example.com"), :administer, :user)
      {:ok, entry} = fixture(fn -> Settings.add_allowlist_entry("y@example.com") end)
      assert refused?(Settings.remove_allowlist_entry(entry), :administer, :user)
      assert refused?(Settings.mark_smtp_verified(), :administer, :user)

      as(a)
      Repo.update!(Ecto.Changeset.change(a, admin: false))
      assert refused?(Settings.update(%{}), :administer, :user)
    end

    test "a seed source is an admin's", _ctx do
      as(stranger())
      assert refused?(SkillRegistry.add_seed(admin(), "x"), :administer, :user)
    end
  end

  # Every guarded write, by somebody short of it: each is refused by the
  # policy with its own action. A guard taken off fails here by its name.
  describe "every write asks" do
    test "the board's writes refuse a person short of them", ctx do
      commenter = short(ctx, :write)
      writer = short(ctx, :owner)
      gardener = Gardener.Settings
      check = hd(Gardener.checks())

      owner_writes = [
        edit_rule: fn -> Automations.create_rule(%{"board_id" => ctx.board.id, "name" => "R"}) end,
        edit_rule: fn -> Automations.update_rule(ctx.rule, %{"name" => "S"}) end,
        edit_rule: fn -> Automations.delete_rule(ctx.rule) end,
        edit_rule: fn -> Automations.toggle_rule(ctx.rule) end,
        edit_rule: fn -> Automations.run_rule_now(ctx.rule) end,
        edit_rule: fn -> Automations.create_rule_from_text(ctx.board, "x", created_by: writer) end,
        edit_rule: fn ->
          Automations.create_rule_from_preset(ctx.board, "x", %{}, created_by: writer)
        end,
        edit_rule: fn -> Automations.rewrite_rule(ctx.rule, "x", created_by: writer) end
      ]

      as(writer)

      for {action, write} <- owner_writes do
        assert refused?(write.(), action, :user), "#{action}: #{inspect(write)} didn't ask"
      end

      write_writes = [
        triage_finding: fn -> Findings.triage(finding(ctx), "dismiss") end,
        run_board_check: fn -> Gardener.run(ctx.board) end,
        run_board_check: fn -> Health.run(ctx.board) end,
        update_board: fn -> gardener.put(ctx.board, check, %{}) end,
        update_board: fn -> Health.Settings.put(ctx.board.id, hd(Health.detectors()), %{}) end,
        update_board: fn -> Overseer.put_settings(ctx.board, %{}) end
      ]

      as(commenter)

      for {action, write} <- write_writes do
        assert refused?(write.(), action, :user), "#{action}: #{inspect(write)} didn't ask"
      end

      # The gardener's own check passes a writer; their read-only token is
      # what the policy refuses.
      {editor, _} = person(ctx, "write")

      token_writes = [
        decide_suggestion: fn -> Gardener.apply(suggestion(ctx), editor) end,
        decide_suggestion: fn -> Gardener.dismiss(suggestion(ctx), editor) end,
        decide_suggestion: fn ->
          applied = suggestion(ctx) |> Ecto.Changeset.change(state: "applied") |> Repo.update!()
          Gardener.undo(applied, editor)
        end,
        enable_skill: fn ->
          SkillRegistry.enable(editor, ctx.board, ctx.entry.id, ctx.entry.content_hash)
        end,
        propose_edit: fn ->
          Gardener.propose(ctx.board, editor, %{
            "explanation" => "x",
            "steps" => [%{"op" => "comment", "card" => ctx.card.id, "body" => "b"}]
          })
        end
      ]

      as(editor, read_token(editor))

      for {action, write} <- token_writes do
        assert refused?(write.(), action, :token), "#{action}: #{inspect(write)} didn't ask"
      end
    end

    test "a Tool's and a skill's writes refuse a token that can't write", ctx do
      owner = ctx.owner
      {:ok, v1} = fixture(fn -> Tools.publish(owner, package(unique_name(), "1.0.0")) end)
      {:ok, _} = fixture(fn -> Tools.request_listing(owner, v1) end)
      friend = stranger()
      {:ok, grant} = fixture(fn -> Tools.share(owner, v1.tool, friend) end)

      {:ok, pin} =
        fixture(fn ->
          SkillRegistry.enable(owner, ctx.board, ctx.entry.id, ctx.entry.content_hash)
        end)

      as(owner, read_token(owner))

      owner_writes = [
        share_tool: fn -> Tools.share(owner, v1.tool, stranger()) end,
        share_tool: fn -> Tools.unshare(owner, v1.tool, grant.id) end,
        share_tool: fn -> Tools.request_listing(owner, v1) end,
        share_tool: fn -> Tools.unlist(owner, v1.tool) end,
        enable_skill: fn -> SkillRegistry.repin(owner, pin, ctx.entry.content_hash) end,
        enable_skill: fn -> SkillRegistry.disable(owner, pin) end
      ]

      for {action, write} <- owner_writes do
        assert refused?(write.(), action, :token), "#{action}: #{inspect(write)} didn't ask"
      end

      a = admin()
      as(a, read_token(a))

      admin_writes = [
        fn -> Tools.approve_listing(a, v1) end,
        fn -> Tools.decline_listing(a, v1, "no") end,
        fn -> Tools.unlist(a, v1.tool) end,
        fn -> SkillRegistry.add_source(a, "https://example.com/x", seed: true) end
      ]

      for write <- admin_writes do
        assert refused?(write.(), :administer, :token), "#{inspect(write)} didn't ask"
      end
    end
  end
end
