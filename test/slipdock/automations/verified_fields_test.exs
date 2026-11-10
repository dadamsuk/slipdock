defmodule Slipdock.Automations.VerifiedFieldsTest do
  @moduledoc """
  Rules and a card's bar, lanes, profile and verification (#2731): a rule
  reads them in its conditions and placeholders, fires when they change,
  sends them in a callback and changes them with `set_bar`, `set_paths` and
  `set_profile`. The checks on agents' work never refuse a rule (SPEC-5):
  it may change a locked bar and lower a started card's profile.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards}
  alias Slipdock.Automations.{Runner, Spec}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Gates"}, owner: owner)
    [_backlog, todo, doing | _] = board.columns
    assert doing.category == "doing"
    %{owner: owner, board: board, todo: todo, doing: doing}
  end

  defp holds?(card, field, op, value \\ nil),
    do: Runner.conditions_match?([%{"field" => field, "op" => op, "value" => value}], card)

  defp fresh(card), do: Repo.get!(Card, card.id)

  # A rule fired by a title change, so a test sets it off with one write and
  # the rule's own writes are a rule's (`Slipdock.Actor.automation/0`).
  defp on_title(board, actions, conditions \\ []) do
    rule_fixture(board, %{
      "trigger" => %{"type" => "card_updated", "field" => "title"},
      "conditions" => conditions,
      "actions" => actions
    })
  end

  defp retitle(card), do: {:ok, _} = Boards.update_card(card, %{"title" => card.title <> "!"})

  describe "conditions" do
    test "bar, paths, profile and verify_state read the card", ctx do
      card =
        card_fixture(ctx.todo, %{
          "title" => "Gated",
          "bar" => "Tests pass",
          "paths" => "lib/foo/**, docs/notes.md",
          "profile" => "fix"
        })

      card = fresh(card)

      assert holds?(card, "bar", "is_set")
      assert holds?(card, "bar", "contains", "tests")
      assert holds?(card, "paths", "is", "docs/notes.md")
      assert holds?(card, "paths", "contains", "lib/foo")
      refute holds?(card, "paths", "contains", "priv/")
      assert holds?(card, "profile", "is", "fix")
      assert holds?(card, "profile", "none_of", ["schema", "security"])
      assert holds?(card, "verify_state", "is_not_set")

      {:ok, card} =
        card |> Ecto.Changeset.change(verify_state: "pending") |> Repo.update()

      assert holds?(card, "verify_state", "is", "pending")
      refute holds?(card, "verify_state", "is", "accepted")
    end

    test "a card with none of them set", ctx do
      card = fresh(card_fixture(ctx.todo, %{"title" => "Bare"}))

      assert holds?(card, "bar", "is_not_set")
      assert holds?(card, "paths", "is_not_set")
      assert holds?(card, "profile", "is_not_set")
      refute holds?(card, "paths", "contains", "lib")
    end

    test "are known to the spec, and read in words", _ctx do
      for field <- ~w(bar paths profile verify_state),
          do: assert(field in Spec.condition_fields(), field)

      {:ok, spec} =
        Spec.validate(%{
          "trigger" => %{"type" => "card_updated", "field" => "verify_state"},
          "conditions" => [%{"field" => "verify_state", "op" => "is", "value" => "rejected"}],
          "actions" => [%{"type" => "add_flags", "flags" => ["flagged"]}]
        })

      assert Spec.summary(spec) ==
               "When a card's verification changes and its verification is rejected, flag it."
    end
  end

  describe "card_updated" do
    test "fires on a change to the bar, the paths or the profile", ctx do
      for field <- ~w(bar paths profile) do
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "card_updated", "field" => field},
          "actions" => [%{"type" => "log", "message" => "#{field} changed on {{card.title}}"}]
        })
      end

      card = card_fixture(ctx.todo, %{"title" => "Watched"})
      {:ok, card} = Boards.update_card(card, %{"bar" => "It works"})
      {:ok, card} = Boards.update_card(card, %{"paths" => "lib/a/**"})
      {:ok, _} = Boards.update_card(card, %{"profile" => "docs"})

      logged =
        Repo.all(
          from(a in Slipdock.Boards.Activity,
            where: a.card_id == ^card.id and like(a.message, "% changed on Watched"),
            select: a.message
          )
        )

      assert Enum.sort(logged) == [
               "bar changed on Watched",
               "paths changed on Watched",
               "profile changed on Watched"
             ]
    end

    test "fires on verify_state when an agent's completion is submitted", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"verify_work" => true})

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_updated", "field" => "verify_state"},
        "conditions" => [%{"field" => "verify_state", "op" => "is", "value" => "pending"}],
        "actions" => [%{"type" => "add_flags", "flags" => ["starred"]}]
      })

      card = card_fixture(ctx.doing, %{"title" => "Submitted"})
      agent = %{Slipdock.Actor.unknown() | kind: "agent", via: "api", user_id: ctx.owner.id}

      {:ok, _} =
        Boards.update_card(card, %{"completed" => true, "evidence" => "tests pass"}, actor: agent)

      card = fresh(card)
      assert card.verify_state == "pending"
      assert "starred" in card.flags
    end

    test "the field-change preset offers them", _ctx do
      for field <- ~w(bar paths profile verify_state) do
        assert field in Slipdock.Automations.Presets.card_fields(), field
      end

      assert {:ok, %{"name" => name, "spec" => spec}} =
               Slipdock.Automations.Presets.build("watch_field", %{
                 "field" => "verify_state",
                 "notify" => "alert"
               })

      assert spec["trigger"] == %{"type" => "card_updated", "field" => "verify_state"}
      assert name == "Followed: verification changes"
    end

    test "a change to another field doesn't fire it", ctx do
      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "card_updated", "field" => "bar"},
        "actions" => [%{"type" => "add_flags", "flags" => ["starred"]}]
      })

      card = card_fixture(ctx.todo, %{"title" => "Quiet"})
      {:ok, _} = Boards.update_card(card, %{"priority" => "high"})
      assert fresh(card).flags == []
    end
  end

  describe "placeholders and callbacks" do
    test "{{card.bar}}, {{card.paths}}, {{card.profile}} and {{card.verify_state}}", ctx do
      card =
        card_fixture(ctx.todo, %{
          "title" => "Told",
          "bar" => "Green CI",
          "paths" => "lib/a/**,test/a/**",
          "profile" => "feature"
        })

      vars = Runner.variables(%{card: fresh(card), board: ctx.board})

      assert Runner.render(
               "{{card.bar}}|{{card.paths}}|{{card.profile}}|{{card.verify_state}}",
               vars
             ) == "Green CI|lib/a/**, test/a/**|feature|"

      for p <- ~w({{card.bar}} {{card.paths}} {{card.profile}} {{card.verify_state}}),
          do: assert(p in Spec.placeholders(), p)
    end

    test "{{card.verify_state}} renders the card's verification", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Checked"})
      {:ok, card} = card |> Ecto.Changeset.change(verify_state: "pending") |> Repo.update()

      vars = Runner.variables(%{card: fresh(card), board: ctx.board})
      assert Runner.render("state: {{card.verify_state}}", vars) == "state: pending"
    end

    test "a callback carries them", ctx do
      test = self()

      Req.Test.stub(Slipdock.Automations.Notifier, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:callback, body})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [%{"type" => "webhook", "url" => "https://example.com/hooks/gates"}]
      })

      card_fixture(ctx.todo, %{
        "title" => "Hooked",
        "bar" => "Done when green",
        "paths" => "lib/b/**",
        "profile" => "schema"
      })

      assert_received {:callback, body}
      %{"card" => payload} = Jason.decode!(body)
      assert payload["bar"] == "Done when green"
      assert payload["paths"] == ["lib/b/**"]
      assert payload["profile"] == "schema"
      assert Map.has_key?(payload, "verify_state")
      assert payload["verify_state"] == nil
    end

    test "a callback carries the card's verify_state when it has one", ctx do
      test = self()

      Req.Test.stub(Slipdock.Automations.Notifier, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:callback, body})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      card = card_fixture(ctx.todo, %{"title" => "Submitted"})
      {:ok, _} = card |> Ecto.Changeset.change(verify_state: "pending") |> Repo.update()

      on_title(ctx.board, [%{"type" => "webhook", "url" => "https://example.com/hooks/state"}])
      retitle(fresh(card))

      assert_received {:callback, body}
      assert %{"card" => %{"verify_state" => "pending"}} = Jason.decode!(body)
    end
  end

  describe "set_bar" do
    test "sets the bar from a template, and none clears it", ctx do
      rule = on_title(ctx.board, [%{"type" => "set_bar", "bar" => "{{card.title}} ships"}])

      card = card_fixture(ctx.todo, %{"title" => "Thing"})
      retitle(card)
      assert fresh(card).bar == "Thing! ships"
      assert Automations.get_rule!(rule.id).last_error in [nil, ""]

      Automations.delete_rule(rule)
      on_title(ctx.board, [%{"type" => "set_bar", "bar" => "none"}])
      retitle(fresh(card))
      assert fresh(card).bar == nil
    end

    test "changes a locked bar, where an agent is refused", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"bar_required" => true})
      rule = on_title(board, [%{"type" => "set_bar", "bar" => "Reworded by the rule"}])

      card = card_fixture(ctx.todo, %{"title" => "Locked", "bar" => "The real bar"})
      :ok = Boards.move_card(card.id, ctx.doing.id, nil)
      assert fresh(card).bar_locked_at

      agent = %{Slipdock.Actor.unknown() | kind: "agent", via: "api", user_id: ctx.owner.id}

      assert {:error, changeset} =
               Boards.update_card(fresh(card), %{"bar" => "Easier"}, actor: agent)

      assert changeset.errors[:bar]

      retitle(fresh(card))
      assert fresh(card).bar == "Reworded by the rule"
      assert Automations.get_rule!(rule.id).last_error in [nil, ""]
    end

    test "is validated and summarised" do
      assert {:error, msg} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_created"},
                 "actions" => [%{"type" => "set_bar"}]
               })

      assert msg =~ "needs bar"

      {:ok, spec} =
        Spec.validate(%{
          "trigger" => %{"type" => "card_created"},
          "actions" => [
            %{"type" => "set_bar", "bar" => "x"},
            %{"type" => "set_bar", "bar" => "none"}
          ]
        })

      assert Spec.summary(spec) == "When a card is added, set its bar, then clear its bar."
    end

    test "says when the bar is unchanged, and when it cleared it", ctx do
      card = fresh(card_fixture(ctx.todo, %{"title" => "Barred", "bar" => "Tests pass"}))
      event = %{type: "card_updated", card: card, board_id: ctx.board.id}

      {:ok, same} = validated([%{"type" => "set_bar", "bar" => "Tests pass"}], ctx)
      assert Runner.run(same, event) == [{:ok, "bar unchanged"}]
      assert fresh(card).bar == "Tests pass"

      {:ok, clear} = validated([%{"type" => "set_bar", "bar" => "none"}], ctx)
      assert Runner.run(clear, event) == [{:ok, "cleared the bar"}]
      assert fresh(card).bar == nil
    end
  end

  describe "set_paths" do
    test "replaces, adds to and takes from the card's paths", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Lane", "paths" => "lib/a/**"})

      for {action, want} <- [
            {%{"mode" => "add", "paths" => "test/a/**, lib/a/**"}, ["lib/a/**", "test/a/**"]},
            {%{"mode" => "remove", "paths" => ["lib/a/**"]}, ["test/a/**"]},
            {%{"paths" => "docs/x.md"}, ["docs/x.md"]},
            {%{"paths" => "none"}, []}
          ] do
        rule = on_title(ctx.board, [Map.put(action, "type", "set_paths")])
        retitle(fresh(card))
        assert fresh(card).paths == want, inspect(action)
        Automations.delete_rule(rule)
      end
    end

    test "says when nothing changed", ctx do
      card = fresh(card_fixture(ctx.todo, %{"title" => "Same", "paths" => "lib/a/**"}))

      {:ok, rule} =
        validated([%{"type" => "set_paths", "mode" => "add", "paths" => "lib/a/**"}], ctx)

      assert Runner.run(rule, %{type: "card_updated", card: card, board_id: ctx.board.id}) ==
               [{:ok, "paths unchanged"}]
    end

    test "says when it cleared them", ctx do
      card = fresh(card_fixture(ctx.todo, %{"title" => "Unlaned", "paths" => "lib/a/**"}))
      {:ok, rule} = validated([%{"type" => "set_paths", "paths" => "none"}], ctx)

      assert Runner.run(rule, %{type: "card_updated", card: card, board_id: ctx.board.id}) ==
               [{:ok, "cleared its paths"}]

      assert fresh(card).paths in [nil, []]
    end

    test "refuses paths that split to nothing" do
      for paths <- ["", " , ", [""]] do
        assert {:error, msg} =
                 Spec.validate(%{
                   "trigger" => %{"type" => "card_created"},
                   "actions" => [%{"type" => "set_paths", "paths" => paths}]
                 }),
               inspect(paths)

        assert msg =~ "needs paths"
      end
    end

    test "refuses a mode it doesn't know, and none with a mode other than replace" do
      base = %{"trigger" => %{"type" => "card_created"}}

      assert {:error, msg} =
               Spec.validate(
                 Map.put(base, "actions", [
                   %{"type" => "set_paths", "paths" => "a", "mode" => "swap"}
                 ])
               )

      assert msg =~ "mode must be replace, add or remove"

      assert {:error, msg} =
               Spec.validate(
                 Map.put(base, "actions", [
                   %{"type" => "set_paths", "paths" => "none", "mode" => "add"}
                 ])
               )

      assert msg =~ "none only clears"

      {:ok, spec} =
        Spec.validate(
          Map.put(base, "actions", [
            %{"type" => "set_paths", "paths" => "lib/**, test/**", "mode" => "ADD"},
            %{"type" => "set_paths", "paths" => ["docs/**"], "mode" => "remove"},
            %{"type" => "set_paths", "paths" => "none"}
          ])
        )

      assert [%{"paths" => ["lib/**", "test/**"], "mode" => "add"} | _] = spec["actions"]

      assert Spec.summary(spec) ==
               "When a card is added, add lib/**, test/** to its paths, " <>
                 "then take docs/** off its paths, then clear its paths."
    end
  end

  describe "set_profile" do
    test "sets the profile, recorded as a rule's, and none clears it", ctx do
      rule = on_title(ctx.board, [%{"type" => "set_profile", "profile" => "security"}])
      card = card_fixture(ctx.todo, %{"title" => "Kind"})

      retitle(card)
      card = fresh(card)
      assert card.profile == "security"
      assert card.profile_source == "rule"

      Automations.delete_rule(rule)
      on_title(ctx.board, [%{"type" => "set_profile", "profile" => "none"}])
      retitle(card)
      assert fresh(card).profile == nil
    end

    test "once work has started a rule may lower it, where an agent may not", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"profiles" => true})
      card = card_fixture(ctx.doing, %{"title" => "Started", "profile" => "feature"})
      agent = %{Slipdock.Actor.unknown() | kind: "agent", via: "api", user_id: ctx.owner.id}

      assert {:error, _} = Boards.update_card(fresh(card), %{"profile" => "docs"}, actor: agent)
      assert fresh(card).profile == "feature"

      lower = on_title(board, [%{"type" => "set_profile", "profile" => "docs"}])
      retitle(fresh(card))
      assert fresh(card).profile == "docs"
      assert fresh(card).profile_source == "rule"
      assert Automations.get_rule!(lower.id).last_error in [nil, ""]
    end

    test "says when the profile is unchanged", ctx do
      card = fresh(card_fixture(ctx.todo, %{"title" => "Kept", "profile" => "fix"}))
      {:ok, rule} = validated([%{"type" => "set_profile", "profile" => "fix"}], ctx)

      assert Runner.run(rule, %{type: "card_updated", card: card, board_id: ctx.board.id}) ==
               [{:ok, "profile unchanged"}]
    end

    test "none is summarised as clearing it" do
      {:ok, spec} =
        Spec.validate(%{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "set_profile", "profile" => "none"}]
        })

      assert Spec.summary(spec) == "When a card is added, clear its profile."
    end

    test "its blurb names every profile" do
      %{description: blurb} = Enum.find(Spec.vocabulary().actions, &(&1.type == "set_profile"))
      assert blurb =~ "(" <> Enum.join(Slipdock.Profiles.names(), ", ") <> ", or none)"
    end

    test "refuses a profile that isn't one" do
      assert {:error, msg} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_created"},
                 "actions" => [%{"type" => "set_profile", "profile" => "huge"}]
               })

      assert msg =~ "isn't one of security"

      {:ok, spec} =
        Spec.validate(%{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "set_profile", "profile" => " Fix "}]
        })

      assert [%{"profile" => "fix"}] = spec["actions"]
      assert Spec.summary(spec) == "When a card is added, set its profile to fix."
    end
  end

  defp validated(actions, ctx) do
    {:ok,
     rule_fixture(ctx.board, %{
       "trigger" => %{"type" => "schedule", "at" => "23:59"},
       "actions" => actions
     })}
  end
end
