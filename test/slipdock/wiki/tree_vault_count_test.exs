defmodule Slipdock.Wiki.TreeVaultCountTest do
  @moduledoc "`Tree.vault_count/3`: the pages a vault's tree shows (#1698)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Vaults
  alias Slipdock.Wiki.{KnowledgeBase, Tree}

  setup do
    user = user_fixture()
    {:ok, kb} = KnowledgeBase.ensure(user)
    alpha = board_fixture(%{"name" => "Alpha", "code" => "tvc1698a"}, owner: user)
    beta = board_fixture(%{"name" => "Beta", "code" => "tvc1698b"}, owner: user)
    %{user: user, kb: kb, alpha: alpha, beta: beta, vault: Vaults.root(user)}
  end

  defp boards(user, list),
    do: Map.new(list, &{&1.id, {&1, [as: user]}})

  test "sums the pages of every board given that sits in the vault", ctx do
    page_fixture(ctx.kb, %{"title" => "K"}, user: ctx.user)
    page_fixture(ctx.alpha, %{"title" => "A1"}, user: ctx.user)
    page_fixture(ctx.alpha, %{"title" => "A2"}, user: ctx.user)
    page_fixture(ctx.beta, %{"title" => "B1"}, user: ctx.user)

    all = boards(ctx.user, [ctx.kb, ctx.alpha, ctx.beta])
    assert Tree.vault_count(ctx.vault, all) == 4
    # A board left out (one the reader can't open) isn't counted.
    assert Tree.vault_count(ctx.vault, boards(ctx.user, [ctx.alpha])) == 2
  end

  test "with a root, only the boards at or below it", ctx do
    page_fixture(ctx.alpha, %{"title" => "A1"}, user: ctx.user)
    page_fixture(ctx.beta, %{"title" => "B1"}, user: ctx.user)

    all = boards(ctx.user, [ctx.kb, ctx.alpha, ctx.beta])
    root = Tree.vault_root(ctx.vault, ctx.alpha.id, all)

    assert is_binary(root)
    assert Tree.vault_count(ctx.vault, all, root) == 1
    assert Tree.vault_count(ctx.vault, all, nil) == 2
  end

  test "an empty vault counts nothing", ctx do
    assert Tree.vault_count(ctx.vault, %{}) == 0
    assert Tree.vault_count(ctx.vault, boards(ctx.user, [ctx.alpha])) == 0
  end
end
