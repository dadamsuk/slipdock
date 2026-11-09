defmodule Slipdock.SkillRegistryPinsTest do
  @moduledoc """
  Enabling registry entries on a board, pinned (#2062): a writer enables the
  text they read, a refresh that changes it is shown as changed upstream and
  the pinned text is still what is enabled until a writer re-pins it, and
  the Playbook stages that name a skill are found, with those neither
  enabled nor shipped flagged.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Handbook, Repo, SkillRegistry, SkillRegistryStub, Wiki}
  alias Slipdock.SkillRegistry.{Enablement, Pins}

  @repo "https://github.com/octo/skills"

  defp skill(name, body \\ "Ask one question at a time.") do
    "---\nname: #{name}\ndescription: Asks hard questions.\n---\n\n#{body}\n"
  end

  defp serve(files), do: SkillRegistryStub.put("octo/skills", %{files: files, licence: "MIT"})

  setup do
    user = user_fixture("pins-owner@example.com")
    board = board_fixture(%{"name" => "Plans"}, owner: user)
    SkillRegistryStub.start(%{})
    serve(%{"grilling/SKILL.md" => skill("grilling"), "tdd/SKILL.md" => skill("tdd")})
    {:ok, source} = SkillRegistry.add_source(user, @repo)
    [grilling, tdd] = source.entries
    %{user: user, board: board, source: source, grilling: grilling, tdd: tdd}
  end

  defp enable!(user, board, entry) do
    {:ok, enablement} = SkillRegistry.enable(user, board, entry.id, entry.content_hash)
    enablement
  end

  defp change_upstream(user, source, body) do
    serve(%{"grilling/SKILL.md" => skill("grilling", body), "tdd/SKILL.md" => skill("tdd")})
    {:ok, source, _changes} = SkillRegistry.refresh_source(user, source)
    source
  end

  describe "enabling" do
    test "pins the text the writer read", %{user: user, board: board, grilling: grilling} do
      assert {:ok, enablement} =
               SkillRegistry.enable(user, board, grilling.id, grilling.content_hash)

      assert enablement.board_id == board.id
      assert enablement.name == "grilling"
      assert enablement.description == "Asks hard questions."
      assert enablement.source_name == "octo/skills"
      assert enablement.source_url == @repo
      assert enablement.licence == "MIT"
      assert enablement.version == SkillRegistryStub.sha()
      assert enablement.pinned_hash == grilling.content_hash
      assert enablement.pinned_body == grilling.body
      assert enablement.enabled_by_id == user.id
      assert SkillRegistry.status(enablement) == :current
      assert [%Enablement{name: "grilling"}] = SkillRegistry.enabled(board)
    end

    test "a hash that isn't the entry's text now is refused", %{
      user: user,
      board: board,
      grilling: grilling
    } do
      assert {:error, message} = SkillRegistry.enable(user, board, grilling.id, "stale")
      assert message == "grilling has changed since you read it. Read it again, then enable it."
      assert SkillRegistry.enabled(board) == []
    end

    test "the same skill twice, or another of the same name, is refused", %{
      user: user,
      board: board,
      grilling: grilling
    } do
      enable!(user, board, grilling)

      assert {:error, "grilling is already enabled on Plans."} ==
               SkillRegistry.enable(user, board, grilling.id, grilling.content_hash)

      SkillRegistryStub.put("octo/other", %{files: %{"g/SKILL.md" => skill("grilling")}})
      {:ok, %{entries: [other]}} = SkillRegistry.add_source(user, "https://github.com/octo/other")

      assert {:error, message} = SkillRegistry.enable(user, board, other.id, other.content_hash)
      assert message =~ "A skill named grilling is already enabled on Plans, from octo/skills."
    end

    test "an entry the user can't see is refused", %{board: board, user: user} do
      stranger = user_fixture("pins-stranger@example.com")
      SkillRegistryStub.put("octo/theirs", %{files: %{"x/SKILL.md" => skill("x")}})

      {:ok, %{entries: [theirs]}} =
        SkillRegistry.add_source(stranger, "https://github.com/octo/theirs")

      assert {:error, "That skill isn't one you can see."} ==
               SkillRegistry.enable(user, board, theirs.id, theirs.content_hash)
    end

    test "a writer may, a reader may not", %{user: user, board: board, grilling: grilling} do
      reader = user_fixture("pins-reader@example.com")
      writer = user_fixture("pins-writer@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)
      {:ok, _} = Access.grant(board, writer, "write", user)
      # The seed is what both of them can see.
      SkillRegistryStub.put("octo/seed", %{files: %{"s/SKILL.md" => skill("seeded")}})
      {:ok, %{entries: [seeded]}} = SkillRegistry.add_source(nil, "https://github.com/octo/seed")

      assert {:error, "Only somebody who can write to Plans changes its skills."} ==
               SkillRegistry.enable(reader, board, seeded.id, seeded.content_hash)

      assert {:ok, enablement} =
               SkillRegistry.enable(writer, board, seeded.id, seeded.content_hash)

      assert {:error, _} = SkillRegistry.disable(reader, enablement)
      assert {:ok, _} = SkillRegistry.disable(writer, enablement)
      assert SkillRegistry.enabled(board) == []

      # The owner's own entries are still theirs to enable.
      assert {:ok, _} = SkillRegistry.enable(user, board, grilling.id, grilling.content_hash)
    end

    test "on a sub-board goes on its root, which the sub-board shares", %{
      user: user,
      board: board,
      grilling: grilling
    } do
      [col | _] = board.columns
      epic = card_fixture(col, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)

      assert {:ok, enablement} =
               SkillRegistry.enable(user, sub, grilling.id, grilling.content_hash)

      assert enablement.board_id == board.id
      assert [%{name: "grilling"}] = SkillRegistry.enabled(sub)
      assert %{name: "grilling"} = SkillRegistry.get_enabled(sub, "grilling")
    end
  end

  describe "a refresh that changes it" do
    test "is changed upstream, and the pinned text stays until re-pinned", %{
      user: user,
      board: board,
      source: source,
      grilling: grilling
    } do
      enable!(user, board, grilling)
      change_upstream(user, source, "Ask them all at once.")

      enablement = SkillRegistry.get_enabled(board, "grilling")
      assert SkillRegistry.status(enablement) == :changed
      assert enablement.pinned_body == grilling.body
      assert enablement.pinned_body =~ "Ask one question at a time."
      assert enablement.entry.body =~ "Ask them all at once."

      assert {:del, ["Ask one question at a time."]} in SkillRegistry.diff(enablement)
      assert {:ins, ["Ask them all at once."]} in SkillRegistry.diff(enablement)
    end

    test "an unchanged refresh leaves it current", %{
      user: user,
      board: board,
      source: source,
      grilling: grilling
    } do
      enable!(user, board, grilling)
      {:ok, _source, _} = SkillRegistry.refresh_source(user, source)

      assert SkillRegistry.status(SkillRegistry.get_enabled(board, "grilling")) == :current
    end

    test "a re-pin with the new hash takes the new text", %{
      user: user,
      board: board,
      source: source,
      grilling: grilling
    } do
      enable!(user, board, grilling)
      change_upstream(user, source, "Ask them all at once.")
      enablement = SkillRegistry.get_enabled(board, "grilling")
      new_hash = enablement.entry.content_hash

      assert {:ok, repinned} = SkillRegistry.repin(user, enablement, new_hash)
      assert repinned.pinned_hash == new_hash
      assert repinned.pinned_body =~ "Ask them all at once."
      assert SkillRegistry.status(repinned) == :current
      assert SkillRegistry.diff(repinned) |> Enum.all?(&match?({:eq, _}, &1))
    end

    test "a re-pin with the hash it had, or a stale one, is refused", %{
      user: user,
      board: board,
      source: source,
      grilling: grilling
    } do
      enable!(user, board, grilling)
      change_upstream(user, source, "Ask them all at once.")
      enablement = SkillRegistry.get_enabled(board, "grilling")

      assert {:error, message} = SkillRegistry.repin(user, enablement, grilling.content_hash)
      assert message =~ "has changed since you read it"
      assert SkillRegistry.get_enabled(board, "grilling").pinned_body == grilling.body
    end

    test "a re-pin by a reader is refused", %{
      user: user,
      board: board,
      source: source,
      grilling: grilling
    } do
      reader = user_fixture("pins-reader2@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)
      enable!(user, board, grilling)
      change_upstream(user, source, "Ask them all at once.")
      enablement = SkillRegistry.get_enabled(board, "grilling")

      assert {:error, "Only somebody who can write to Plans changes its skills."} ==
               SkillRegistry.repin(reader, enablement, enablement.entry.content_hash)
    end

    test "an entry gone from its source leaves the pinned text, removed upstream", %{
      user: user,
      board: board,
      source: source,
      grilling: grilling
    } do
      enable!(user, board, grilling)
      serve(%{"tdd/SKILL.md" => skill("tdd")})
      {:ok, _source, %{removed: ["grilling"]}} = SkillRegistry.refresh_source(user, source)

      enablement = SkillRegistry.get_enabled(board, "grilling")
      assert enablement.entry_id == nil
      assert SkillRegistry.status(enablement) == :removed
      assert enablement.pinned_body == grilling.body
      assert SkillRegistry.diff(enablement) == []

      assert {:error, "grilling has gone from its source, so there is nothing newer to pin."} ==
               SkillRegistry.repin(user, enablement, "anything")
    end

    test "removing the source leaves it removed upstream too", %{
      user: user,
      board: board,
      source: source,
      grilling: grilling
    } do
      enable!(user, board, grilling)
      {:ok, _} = SkillRegistry.remove_source(user, source)

      assert SkillRegistry.status(SkillRegistry.get_enabled(board, "grilling")) == :removed
    end
  end

  describe "the stages that name a skill" do
    test "are the skill: lines under each heading" do
      body = """
      ## Grill

      - **Skill:** the plan skill's Grill. To use an installed skill instead, add `skill: <its name>` here.
      - skill: grilling

      ## Decide

      - **Skill:** the plan skill's Decide.

      ```
      skill: in-a-fence
      ```

      ## Spec

      Use `skill: write-a-prd` for this, or skill: slipdock-plan.
      """

      assert Pins.stage_lines(body) == [
               %{stage: "Grill", skill: "grilling"},
               %{stage: "Spec", skill: "write-a-prd"},
               %{stage: "Spec", skill: "slipdock-plan"}
             ]
    end

    test "none before the first heading, and none in an empty page" do
      assert Pins.stage_lines("skill: early\n\n## Grill\n") == []
      assert Pins.stage_lines("") == []
    end

    test "are read from the board's Playbook, and flagged when neither enabled nor shipped",
         %{user: user, board: board, grilling: grilling} do
      assert SkillRegistry.stages(board) == []

      {:ok, _} = Handbook.install(user, board)
      # The seed Playbook names none.
      assert SkillRegistry.stages(board) == []

      playbook = Enum.find(Handbook.find(board).pages, &(Handbook.key(&1) == "playbook"))

      body =
        String.replace(
          playbook.body,
          "## Spike\n",
          "- skill: grilling\n- skill: slipdock-plan\n- skill: nowhere\n\n## Spike\n"
        )

      {:ok, _} = Wiki.update_page(playbook, %{"body" => body}, user: user)

      assert SkillRegistry.stages(board) == [
               %{stage: "Grill", skill: "grilling"},
               %{stage: "Grill", skill: "slipdock-plan"},
               %{stage: "Grill", skill: "nowhere"}
             ]

      [%{board: named, stages: [g, p, n]}] = SkillRegistry.naming(user)
      assert named.id == board.id
      assert %{skill: "grilling", enabled: nil, shipped: false, flagged: true} = g
      assert %{skill: "slipdock-plan", enabled: nil, shipped: true, flagged: false} = p
      assert %{skill: "nowhere", flagged: true} = n

      enable!(user, board, grilling)

      [%{stages: [g | _]}] = SkillRegistry.naming(user)
      assert %{enabled: %Enablement{name: "grilling"}, flagged: false} = g

      # Narrowed to one name, per entry.
      assert [%{board: %{id: id}, stages: [%{skill: "grilling"}]}] =
               SkillRegistry.naming(user, "grilling")

      assert id == board.id
      assert SkillRegistry.naming(user, "tdd") == []

      # Somebody who can't read the board doesn't see its stages.
      assert SkillRegistry.naming(user_fixture("pins-outsider@example.com")) == []
    end
  end

  test "an enablement is found only on a board the user reads", %{
    user: user,
    board: board,
    grilling: grilling
  } do
    e = enable!(user, board, grilling)
    reader = user_fixture("pins-lookup-reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)

    assert %Enablement{id: id} = SkillRegistry.get_enablement(user, e.id)
    assert id == e.id
    assert %Enablement{} = SkillRegistry.get_enablement(reader, e.id)
    assert SkillRegistry.get_enablement(user_fixture("pins-lookup-out@example.com"), e.id) == nil
    assert SkillRegistry.get_enablement(user, -1) == nil
  end

  test "the changeset never casts the board, the entry or who pinned it" do
    changeset =
      Enablement.changeset(%Enablement{}, %{
        name: "x",
        pinned_hash: "h",
        pinned_body: "b",
        pinned_at: DateTime.utc_now(:second),
        board_id: 1,
        entry_id: 2,
        enabled_by_id: 3
      })

    assert changeset.valid?
    refute Map.has_key?(changeset.changes, :board_id)
    refute Map.has_key?(changeset.changes, :entry_id)
    refute Map.has_key?(changeset.changes, :enabled_by_id)
  end

  test "disabling removes it from the board", %{user: user, board: board, grilling: grilling} do
    enablement = enable!(user, board, grilling)
    assert {:ok, _} = SkillRegistry.disable(user, enablement)
    assert SkillRegistry.enabled(board) == []
    refute Repo.get(Enablement, enablement.id)
  end
end
