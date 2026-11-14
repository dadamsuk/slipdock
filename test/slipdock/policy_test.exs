defmodule Slipdock.PolicyTest do
  @moduledoc """
  SPIKE #3162, not for merging: `Boards.Tags`' writes ask `Slipdock.Policy`
  themselves, so a door that forgets its own check is still refused.
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
    {:ok, ops} = Boards.Tags.create_tag(root, %{"name" => "ops", "color" => "rose"})

    writer = user_fixture("policy.writer@example.com")
    {:ok, grant} = Access.grant(root, writer, "write", owner)

    card_writer = user_fixture("policy.card-writer@example.com")
    {:ok, _} = Access.grant(epic, card_writer, "write", owner)

    %{
      owner: owner,
      root: root,
      sub: sub,
      ops: ops,
      writer: writer,
      grant: grant,
      card_writer: card_writer
    }
  end

  defp as(user, token \\ nil), do: Actor.put(Actor.web(user), nil, {user, token})
  defp names(root), do: root.id |> Boards.Tags.list_tags() |> Enum.map(& &1.name)

  test "a writer of the root makes, changes and deletes a tag", ctx do
    as(ctx.writer)
    assert {:ok, tag} = Boards.Tags.create_tag(ctx.sub, %{"name" => "new", "color" => "sky"})
    assert {:ok, tag} = Boards.Tags.update_tag(tag, %{"name" => "newer"})
    assert {:ok, _} = Boards.Tags.delete_tag(tag)
    assert names(ctx.root) == ["ops"]
  end

  test "a card grant's writer is refused with no door in the way (#2751, #2990)", ctx do
    as(ctx.card_writer)

    assert {:error, %Refused{action: :create_tag, need: :write, by: :user}} =
             Boards.Tags.create_tag(ctx.sub, %{"name" => "mine", "color" => "sky"})

    assert {:error, %Refused{by: :user}} = Boards.Tags.update_tag(ctx.ops, %{"name" => "theirs"})
    assert {:error, %Refused{by: :user}} = Boards.Tags.delete_tag(ctx.ops)
    assert names(ctx.root) == ["ops"]
  end

  test "a level lowered after the actor was set is read at the write (#2998)", ctx do
    as(ctx.writer)
    {:ok, _} = Access.grant(ctx.root, ctx.writer, "read", ctx.owner)

    assert {:error, %Refused{by: :user}} =
             Boards.Tags.create_tag(ctx.root, %{"name" => "late", "color" => "sky"})
  end

  test "a read-only token narrows its owner, and the refusal names the token (ARCH-8)", ctx do
    {_plain, token} = Accounts.create_api_token(ctx.owner, "reader", scope: "read")
    as(ctx.owner, token)

    assert {:error, %Refused{by: :token}} =
             Boards.Tags.create_tag(ctx.root, %{"name" => "scoped", "color" => "sky"})
  end

  test "a rule's write passes, as the board's own", ctx do
    Process.put(:automation_depth, 1)
    assert {:ok, _} = Boards.Tags.create_tag(ctx.root, %{"name" => "ruled", "color" => "sky"})
  end

  test "nobody acting is refused, unless the server says it is itself", ctx do
    # What a process outside a test is: no fixture default.
    Process.delete({Policy, :nobody_ok})

    assert {:error, %Refused{by: :nobody}} =
             Boards.Tags.create_tag(ctx.root, %{"name" => "anon", "color" => "sky"})

    assert {:ok, _} =
             Policy.as_system("a test", fn ->
               Boards.Tags.create_tag(ctx.root, %{"name" => "system", "color" => "sky"})
             end)

    assert "system" in names(ctx.root)
    refute "anon" in names(ctx.root)
  end
end
