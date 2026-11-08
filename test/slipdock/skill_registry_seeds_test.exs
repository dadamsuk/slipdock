defmodule Slipdock.SkillRegistrySeedsTest do
  @moduledoc """
  The registry's seeds (#2075, spec W-2513 §Seeds): a new server's sources,
  owned by no one, seen by everyone and enabled nowhere, seeded once per URL
  so an admin's removal sticks and a failed fetch is tried again; and an
  admin, only, adding a seed.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, SkillRegistry, SkillRegistryStub, TestConfig}
  alias Slipdock.SkillRegistry.{Enablement, Seeds, Source}

  @seed "https://github.com/octo/seed"

  defp skill(name), do: "---\nname: #{name}\ndescription: Asks.\n---\n\nSteps.\n"

  defp serve_seed,
    do: SkillRegistryStub.put("octo/seed", %{files: %{"grilling/SKILL.md" => skill("grilling")}})

  setup do
    SkillRegistryStub.start(%{})
    TestConfig.merge(:skill_registry, seeds: [@seed])
    %{user: user_fixture(), other: user_fixture("seeds-other@example.com")}
  end

  test "a server seeds mattpocock/skills unless told otherwise" do
    TestConfig.merge(:skill_registry, seeds: nil)
    assert Seeds.seeds() == ["https://github.com/mattpocock/skills"]
  end

  test "a seed is owned by no one, seen by everyone and enabled nowhere", %{
    user: user,
    other: other
  } do
    serve_seed()
    assert Seeds.run() == [{@seed, :added}]

    assert [%Source{owner_id: nil, name: "octo/seed"} = seed] = SkillRegistry.list_sources(user)
    assert [%Source{id: id}] = SkillRegistry.list_sources(other)
    assert id == seed.id
    assert Enum.map(seed.entries, & &1.name) == ["grilling"]
    assert Repo.aggregate(Enablement, :count) == 0
    assert Seeds.seeded() == MapSet.new([@seed])
  end

  test "a URL is seeded once: a second boot fetches nothing" do
    serve_seed()
    Seeds.run()
    fetched = length(SkillRegistryStub.requests())

    assert Seeds.run() == [{@seed, :seeded_before}]
    assert length(SkillRegistryStub.requests()) == fetched
    assert Repo.aggregate(Source, :count) == 1
  end

  test "a seed an admin removed stays removed", %{user: user} do
    serve_seed()
    Seeds.run()
    [seed] = SkillRegistry.list_sources(user)

    assert {:ok, _} = SkillRegistry.remove_source(%{user | admin: true}, seed)
    assert Seeds.run() == [{@seed, :seeded_before}]
    assert SkillRegistry.list_sources(user) == []
  end

  test "a fetch that fails is not recorded, so the next boot tries again" do
    assert [{@seed, {:error, reason}}] = Seeds.run()
    assert reason =~ "octo/seed"
    assert Seeds.seeded() == MapSet.new()
    assert Repo.aggregate(Source, :count) == 0

    serve_seed()
    assert Seeds.run() == [{@seed, :added}]
  end

  test "a seed already there (an admin added it) is recorded, not added twice", %{user: user} do
    serve_seed()
    {:ok, _} = SkillRegistry.add_seed(%{user | admin: true}, @seed)

    assert Seeds.run() == [{@seed, :already}]
    assert Repo.aggregate(Source, :count) == 1
    assert Seeds.seeded() == MapSet.new([@seed])
  end

  test "an empty list seeds nothing" do
    TestConfig.merge(:skill_registry, seeds: [])
    assert Seeds.run() == []
    assert SkillRegistryStub.requests() == []
  end

  describe "an admin adding a seed" do
    test "is a source for everyone; a second of the same URL is refused", %{
      user: user,
      other: other
    } do
      serve_seed()
      admin = %{user | admin: true}

      assert {:ok, %Source{owner_id: nil}} = SkillRegistry.add_source(admin, @seed, seed: true)
      assert [%Source{owner_id: nil}] = SkillRegistry.list_sources(other)

      assert {:error, "#{@seed} is already one of the seeds."} ==
               SkillRegistry.add_seed(admin, @seed)
    end

    test "anyone else is refused, and nothing is fetched", %{user: user} do
      serve_seed()
      message = "Only an admin can add a source for everyone."

      assert SkillRegistry.add_source(user, @seed, seed: true) == {:error, message}
      assert SkillRegistry.add_seed(nil, @seed) == {:error, message}
      assert SkillRegistryStub.requests() == []
      assert Repo.aggregate(Source, :count) == 0
    end
  end
end
