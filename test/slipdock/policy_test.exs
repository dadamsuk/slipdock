defmodule Slipdock.PolicyTest do
  @moduledoc """
  `Boards.Tags`' writes ask `Slipdock.Policy` themselves (#3168), so a door
  that forgets its own check is refused anyway. Every test here calls the
  context with no door in the way: the actor is set as a door would set it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Actor, Boards, Policy}
  alias Slipdock.Policy.Refused

  setup do
    owner = user_fixture("policy.owner@example.com")
    root = board_fixture(%{"name" => "Root"}, owner: owner)
    epic = card_fixture(hd(root.columns), %{"title" => "Epic"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = Boards.create_sub_board(epic, t)
    sub_card = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Task"})
    {:ok, ops} = Boards.Tags.create_tag(root, %{"name" => "ops", "color" => "rose"})

    writer = user_fixture("policy.writer@example.com")
    {:ok, _} = Access.grant(root, writer, "write", owner)

    card_writer = user_fixture("policy.card-writer@example.com")
    {:ok, _} = Access.grant(epic, card_writer, "write", owner)

    reader = user_fixture("policy.reader@example.com")
    {:ok, _} = Access.grant(root, reader, "read", owner)

    %{
      owner: owner,
      root: root,
      epic: epic,
      sub: sub,
      sub_card: sub_card,
      ops: ops,
      writer: writer,
      card_writer: card_writer,
      reader: reader
    }
  end

  # As a door sets it: the actor, and the user and token beside it.
  defp as(user, token \\ nil), do: Actor.put(Actor.web(user), nil, {user, token})
  defp names(root), do: root.id |> Boards.Tags.list_tags() |> Enum.map(& &1.name)

  defp tag_names(card),
    do:
      Slipdock.Boards.Card
      |> Slipdock.Repo.get!(card.id)
      |> Slipdock.Repo.preload(:tags)
      |> Map.fetch!(:tags)
      |> Enum.map(& &1.name)

  describe "a tag's writes" do
    test "a writer of the root makes, changes and deletes one, from any board of the tree",
         ctx do
      as(ctx.writer)
      assert {:ok, tag} = Boards.Tags.create_tag(ctx.sub, %{"name" => "new", "color" => "sky"})
      assert {:ok, tag} = Boards.Tags.update_tag(tag, %{"name" => "newer"})
      assert {:ok, _} = Boards.Tags.delete_tag(tag)
      assert names(ctx.root) == ["ops"]
    end

    test "a card grant's writer is refused, naming the person (#2751, #2990)", ctx do
      as(ctx.card_writer)

      assert {:error, %Refused{action: :create_tag, need: :write, by: :user} = refused} =
               Boards.Tags.create_tag(ctx.sub, %{"name" => "mine", "color" => "sky"})

      assert refused.message =~ "you don't have it"

      assert {:error, %Refused{action: :update_tag, by: :user}} =
               Boards.Tags.update_tag(ctx.ops, %{"name" => "theirs"})

      assert {:error, %Refused{action: :delete_tag, by: :user}} = Boards.Tags.delete_tag(ctx.ops)
      assert names(ctx.root) == ["ops"]
    end

    test "a reader of the root is refused", ctx do
      as(ctx.reader)

      assert {:error, %Refused{by: :user}} =
               Boards.Tags.create_tag(ctx.root, %{"name" => "read", "color" => "sky"})
    end

    test "a level lowered after the actor was set is read at the write (#2998)", ctx do
      as(ctx.writer)
      {:ok, _} = Access.grant(ctx.root, ctx.writer, "read", ctx.owner)

      assert {:error, %Refused{by: :user}} =
               Boards.Tags.create_tag(ctx.root, %{"name" => "late", "color" => "sky"})

      assert {:error, %Refused{by: :user}} = Boards.Tags.delete_tag(ctx.ops)
    end

    test "a read-only token narrows its owner, and the refusal names the token (ARCH-8)", ctx do
      {_plain, token} = Accounts.create_api_token(ctx.owner, "reader", scope: "read")
      as(ctx.owner, token)

      assert {:error, %Refused{by: :token} = refused} =
               Boards.Tags.create_tag(ctx.root, %{"name" => "scoped", "color" => "sky"})

      assert refused.message =~ "this API token"
      assert {:error, %Refused{by: :token}} = Boards.Tags.delete_tag(ctx.ops)
    end

    test "a token scoped to one tree writes its tags, and is refused another's (ARCH-8)",
         ctx do
      other = board_fixture(%{"name" => "Other"}, owner: ctx.owner)

      {_plain, token} =
        Accounts.create_api_token(ctx.owner, "root only",
          scope: "write",
          scope_boards: [ctx.root.id]
        )

      as(ctx.owner, token)

      # The root's tree, from a board inside it too.
      assert {:ok, _} = Boards.Tags.create_tag(ctx.root, %{"name" => "in", "color" => "sky"})
      assert {:ok, _} = Boards.Tags.create_tag(ctx.sub, %{"name" => "in sub", "color" => "sky"})

      assert {:error, %Refused{by: :token} = refused} =
               Boards.Tags.create_tag(other, %{"name" => "out", "color" => "sky"})

      assert refused.message =~ "this API token"
      assert Boards.Tags.list_tags(other.id) == []
    end

    test "a token narrows only the user it was issued to", ctx do
      {_plain, token} = Accounts.create_api_token(ctx.owner, "reader", scope: "read")
      Actor.put(Actor.web(ctx.writer), nil, {ctx.owner, token})

      assert {:ok, _} = Boards.Tags.create_tag(ctx.root, %{"name" => "w", "color" => "sky"})
    end

    test "an actor set without a user beside it is read by its user id", ctx do
      Actor.put(Actor.email(ctx.card_writer))

      assert {:error, %Refused{by: :user}} =
               Boards.Tags.create_tag(ctx.root, %{"name" => "mailed", "color" => "sky"})

      Actor.put(Actor.email(ctx.writer))
      assert {:ok, _} = Boards.Tags.create_tag(ctx.root, %{"name" => "mailed", "color" => "sky"})
    end

    test "a rule's write passes, as the board's own", ctx do
      Policy.forbid_nobody()
      Process.put(:automation_depth, 1)

      try do
        assert {:ok, _} = Boards.Tags.create_tag(ctx.root, %{"name" => "ruled", "color" => "sky"})
      after
        Process.delete(:automation_depth)
      end
    end

    test "nobody acting is refused, unless the server says it is itself", ctx do
      # What a process outside a test is: no fixture default.
      Policy.forbid_nobody()

      assert {:error, %Refused{by: :nobody} = refused} =
               Boards.Tags.create_tag(ctx.root, %{"name" => "anon", "color" => "sky"})

      assert refused.message =~ "nobody acting"
      assert {:error, %Refused{by: :nobody}} = Boards.Tags.delete_tag(ctx.ops)

      assert {:error, %Refused{by: :nobody}} =
               Boards.Tags.toggle_card_tag(ctx.sub_card, ctx.ops)

      assert {:ok, _} =
               Policy.as_system("a test", fn ->
                 Boards.Tags.create_tag(ctx.root, %{"name" => "system", "color" => "sky"})
               end)

      assert Policy.system_reason() == nil
      assert "system" in names(ctx.root)
      refute "anon" in names(ctx.root)
    end

    test "as_system/2 keeps the outer reason, and lets go after a raise" do
      Policy.as_system("outer", fn ->
        Policy.as_system("inner", fn -> assert Policy.system_reason() == "outer" end)
        assert Policy.system_reason() == "outer"
      end)

      assert_raise RuntimeError, fn -> Policy.as_system("boom", fn -> raise "boom" end) end
      assert Policy.system_reason() == nil
    end
  end

  describe "a card's tags" do
    test "a card grant's writer puts a tree's tag on the card and takes it off", ctx do
      as(ctx.card_writer)
      assert {:ok, _} = Boards.Tags.toggle_card_tag(ctx.sub_card, ctx.ops)
      assert tag_names(ctx.sub_card) == ["ops"]
      assert {:ok, _} = Boards.Tags.toggle_card_tag(ctx.sub_card, ctx.ops)
      assert tag_names(ctx.sub_card) == []
    end

    test "a card grant raises the level on that card, where the board's own grant doesn't reach",
         ctx do
      # The epic is on the root board, where the card writer has no board grant.
      assert Access.board_permission(ctx.card_writer, ctx.root) == :none
      as(ctx.card_writer)
      assert {:ok, _} = Boards.Tags.toggle_card_tag(ctx.epic, ctx.ops)
      assert tag_names(ctx.epic) == ["ops"]

      other = card_fixture(hd(ctx.root.columns), %{"title" => "Not granted"})

      assert {:error, %Refused{action: :toggle_card_tag, by: :user}} =
               Boards.Tags.toggle_card_tag(other, ctx.ops)
    end

    test "a commenter is refused: tagging needs write", ctx do
      commenter = user_fixture("policy.commenter@example.com")
      {:ok, _} = Access.grant(ctx.root, commenter, "comment", ctx.owner)
      as(commenter)

      assert {:error, %Refused{action: :toggle_card_tag, need: :write, by: :user}} =
               Boards.Tags.toggle_card_tag(ctx.epic, ctx.ops)

      assert tag_names(ctx.epic) == []
    end

    test "a reader is refused, and the card keeps its tags", ctx do
      as(ctx.reader)

      assert {:error, %Refused{action: :toggle_card_tag, by: :user}} =
               Boards.Tags.toggle_card_tag(ctx.epic, ctx.ops)

      assert tag_names(ctx.epic) == []
    end

    test "a read-only token is refused, naming the token", ctx do
      {_plain, token} = Accounts.create_api_token(ctx.owner, "reader", scope: "read")
      as(ctx.owner, token)

      assert {:error, %Refused{by: :token}} = Boards.Tags.toggle_card_tag(ctx.epic, ctx.ops)
    end
  end

  describe "can?/3 and opts[:actor]" do
    test "a door asks the same table it draws from", ctx do
      as(ctx.writer)
      assert Policy.can?(:create_tag, ctx.sub)
      refute Policy.can?(:create_tag, ctx.sub, actor: Actor.web(ctx.card_writer))
      assert Policy.can?(:toggle_card_tag, ctx.sub_card, actor: Actor.web(ctx.card_writer))
    end

    test "the table names every Boards.Tags write" do
      assert Map.keys(Policy.rules()) |> Enum.sort() ==
               [:create_tag, :delete_tag, :toggle_card_tag, :update_tag]
    end
  end
end
