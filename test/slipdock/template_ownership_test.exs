defmodule Slipdock.TemplateOwnershipTest do
  @moduledoc """
  Templates are built in (read-only to everyone) or one person's own (#856).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.Template

  setup do
    owner = user_fixture("template-owner@example.com")
    other = user_fixture("template-other@example.com")
    {:ok, simple} = Boards.find_template(nil, "Simple")
    {:ok, mine} = Boards.create_template(owner, %{"name" => uniq("Mine"), "columns" => ["A"]})
    %{owner: owner, other: other, simple: simple, mine: mine}
  end

  defp uniq(prefix), do: "#{prefix} #{System.unique_integer([:positive])}"
  defp names(templates), do: Enum.map(templates, & &1.name)

  test "the seeded templates are the built-ins, owned by nobody" do
    built_in = Boards.list_templates(nil)

    for name <-
          ~w(Simple Slipdock Checklist Research Roadmap) ++ ["Bug triage", "Sprint planning"],
        do: assert(name in names(built_in))

    assert Enum.all?(built_in, &(&1.system and is_nil(&1.owner_id)))
  end

  describe "list_templates/1 and find_template/2" do
    test "a person gets the built-ins and their own; nil gets the built-ins only", ctx do
      assert ctx.mine.name in names(Boards.list_templates(ctx.owner))
      assert ctx.simple.name in names(Boards.list_templates(ctx.owner))
      refute ctx.mine.name in names(Boards.list_templates(ctx.other))
      assert ctx.simple.name in names(Boards.list_templates(ctx.other))
      refute ctx.mine.name in names(Boards.list_templates(nil))
    end

    test "somebody else's template is not found, by id or name", ctx do
      assert {:ok, _} = Boards.find_template(ctx.owner, ctx.mine.name)
      assert {:error, :not_found} = Boards.find_template(ctx.other, ctx.mine.name)
      assert {:error, :not_found} = Boards.find_template(ctx.other, ctx.mine.id)
      assert {:error, :not_found} = Boards.find_template(nil, ctx.mine.id)

      assert_raise Ecto.NoResultsError, fn -> Boards.get_template!(ctx.other, ctx.mine.id) end
    end
  end

  describe "authorize_template/3" do
    test "read: built-ins and one's own; write: one's own only", ctx do
      assert :ok = Boards.authorize_template(ctx.owner, ctx.simple, :read)
      assert {:error, :forbidden} = Boards.authorize_template(ctx.owner, ctx.simple, :write)
      assert :ok = Boards.authorize_template(ctx.owner, ctx.mine, :write)
      assert {:error, :not_found} = Boards.authorize_template(ctx.other, ctx.mine, :read)
      assert {:error, :not_found} = Boards.authorize_template(ctx.other, ctx.mine, :write)
      assert {:error, :not_found} = Boards.authorize_template(nil, ctx.mine, :read)

      refute Boards.template_editable?(ctx.owner, ctx.simple)
      assert Boards.template_editable?(ctx.owner, ctx.mine)
      refute Boards.template_editable?(ctx.other, ctx.mine)
    end

    test "an admin can't change a built-in either", ctx do
      admin = %{ctx.other | admin: true}
      assert {:error, :forbidden} = Boards.update_template(admin, ctx.simple, %{"name" => "X"})
      assert {:error, :forbidden} = Boards.delete_template(admin, ctx.simple)
      assert Repo.get!(Template, ctx.simple.id).name == "Simple"
    end
  end

  describe "update_template/3 and delete_template/2" do
    test "refuse somebody else's template and leave it as it was", ctx do
      assert {:error, :not_found} = Boards.update_template(ctx.other, ctx.mine, %{"name" => "X"})
      assert {:error, :not_found} = Boards.delete_template(ctx.other, ctx.mine)
      assert Repo.get!(Template, ctx.mine.id).name == ctx.mine.name
    end

    test "change and delete one's own", ctx do
      assert {:ok, %{name: "Renamed"}} =
               Boards.update_template(ctx.owner, ctx.mine, %{"name" => "Renamed"})

      assert {:ok, _} = Boards.delete_template(ctx.owner, ctx.mine)
      refute Repo.get(Template, ctx.mine.id)
    end

    test "can't rename one's own to a built-in's name", ctx do
      assert {:error, cs} = Boards.update_template(ctx.owner, ctx.mine, %{"name" => "ROADMAP"})
      assert {"already exists", _} = cs.errors[:name]
    end
  end

  describe "create_template/2" do
    test "owner_id and system can't come from attrs", ctx do
      {:ok, t} =
        Boards.create_template(ctx.owner, %{
          "name" => uniq("Forged"),
          "columns" => ["A"],
          "owner_id" => ctx.other.id,
          "system" => true
        })

      assert t.owner_id == ctx.owner.id
      refute t.system
    end

    test "names are unique per person, not across people", ctx do
      assert {:error, cs} =
               Boards.create_template(ctx.owner, %{"name" => ctx.mine.name, "columns" => ["A"]})

      assert {"already exists", _} = cs.errors[:name]

      assert {:ok, _} =
               Boards.create_template(ctx.other, %{"name" => ctx.mine.name, "columns" => ["A"]})
    end
  end

  test "create_system_template/1 makes a built-in nobody owns" do
    {:ok, t} = Boards.create_system_template(%{"name" => uniq("Server's"), "columns" => ["A"]})
    assert t.system and is_nil(t.owner_id)
    assert t.name in names(Boards.list_templates(nil))
  end

  test "create_board(save_template:) makes the template the board owner's", ctx do
    name = uniq("Saved")

    {:ok, board} =
      Boards.create_board(%{"name" => "Hiring"},
        owner_id: ctx.other.id,
        columns: ["A", "Done"],
        save_template: name
      )

    assert {:ok, t} = Boards.find_template(ctx.other, name)
    assert t.owner_id == ctx.other.id and not t.system
    assert board.template_id == t.id
    assert {:error, :not_found} = Boards.find_template(ctx.owner, name)
  end

  test "create_board(save_template:) can't take a built-in's name", ctx do
    assert {:error, cs} =
             Boards.create_board(%{"name" => "Clash"},
               owner_id: ctx.owner.id,
               columns: ["A"],
               save_template: "checklist"
             )

    assert {"a template called “checklist” already exists", _} = cs.errors[:save_template]
  end

  test "a person's templates go with them", ctx do
    lonely = user_fixture("template-lonely@example.com")
    {:ok, t} = Boards.create_template(lonely, %{"name" => uniq("Lonely"), "columns" => ["A"]})
    Repo.delete!(lonely)
    refute Repo.get(Template, t.id)
    assert Repo.get(Template, ctx.simple.id)
  end
end
