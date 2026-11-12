defmodule Slipdock.BoardOrderVaultsTest do
  @moduledoc "Vaults in the same order as the boards on the home page."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Vaults}

  setup do
    user = user_fixture()
    a = board_fixture(%{"name" => "A", "code" => "bova"}, owner: user)
    b = board_fixture(%{"name" => "B", "code" => "bovb"}, owner: user)
    {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "V"})
    %{user: user, a: a, b: b, vault: vault}
  end

  defp order(user) do
    boards = Slipdock.Access.list_boards(user)
    vaults = Vaults.list_vaults(user)

    boards
    |> Kernel.++(vaults)
    |> Boards.Arrangement.sort_boards("manual")
    |> Enum.map(&{&1.__struct__ |> Module.split() |> List.last(), &1.id})
  end

  test "home_ranks: placed boards by their place, then the rest oldest first", ctx do
    %{user: user, a: a, b: b} = ctx
    c = board_fixture(%{"name" => "0 first by name", "code" => "bovc"}, owner: user)

    assert Boards.Arrangement.home_ranks(user, [c, b, a]) == %{a.id => 0, b.id => 1, c.id => 2}

    :ok = Boards.Arrangement.reorder_boards(user, [c, a])
    assert Boards.Arrangement.home_ranks(user, [a, b, c]) == %{c.id => 0, a.id => 1, b.id => 2}
  end

  test "a vault takes its place among the boards, by any of its names", ctx do
    %{user: user, a: a, b: b, vault: vault} = ctx

    :ok = Boards.Arrangement.reorder_boards(user, [b, vault, a])
    assert order(user) == [{"Board", b.id}, {"Vault", vault.id}, {"Board", a.id}]

    :ok = Boards.Arrangement.reorder_boards(user, ["vault-#{vault.id}", a.id, b.id])
    assert order(user) == [{"Vault", vault.id}, {"Board", a.id}, {"Board", b.id}]

    :ok = Boards.Arrangement.reorder_boards(user, [a.id, {:vault, to_string(vault.id)}, b.id])
    assert Repo.reload(vault).position == 1
  end

  test "an order of boards alone leaves each vault behind as many boards as before", ctx do
    %{user: user, a: a, b: b, vault: vault} = ctx
    c = board_fixture(%{"name" => "C", "code" => "bovc"}, owner: user)

    :ok = Boards.Arrangement.reorder_boards(user, [a, vault, b, c])
    # As the command line sets it: boards only.
    :ok = Boards.Arrangement.reorder_boards(user, [c.id, b.id, a.id])

    assert order(user) == [
             {"Board", c.id},
             {"Vault", vault.id},
             {"Board", b.id},
             {"Board", a.id}
           ]
  end

  test "nobody else's vault is placed, and their vaults keep their places", ctx do
    %{user: user, a: a, vault: vault} = ctx
    stranger = user_fixture("bov-stranger@example.com")
    {:ok, theirs} = stranger |> Vaults.root() |> Vaults.update_vault(%{"name" => "Theirs"})
    :ok = Boards.Arrangement.reorder_boards(stranger, [theirs])

    :ok = Boards.Arrangement.reorder_boards(user, [{:vault, theirs.id}, vault, a])

    assert Repo.reload(theirs).position == 0
    assert Repo.reload(vault).position == 0
  end

  test "nudge and place move a vault like a board", ctx do
    %{user: user, a: a, b: b, vault: vault} = ctx
    among = [a, b, vault]

    :ok = Boards.Arrangement.nudge_board(user, vault, :up, among)
    assert order(user) == [{"Board", a.id}, {"Vault", vault.id}, {"Board", b.id}]

    :ok = Boards.Arrangement.place_board(user, b, "vault-#{vault.id}", [a, vault, b])
    assert order(user) == [{"Board", a.id}, {"Board", b.id}, {"Vault", vault.id}]

    # Already last: nothing moves.
    :ok = Boards.Arrangement.nudge_board(user, vault, :down, [a, b, vault])
    assert order(user) == [{"Board", a.id}, {"Board", b.id}, {"Vault", vault.id}]
  end

  test "a board and a vault made in the same second: the board first", ctx do
    %{a: a, vault: vault} = ctx
    at = ~U[2026-01-01 00:00:00Z]
    a = %{a | inserted_at: at, id: vault.id + 1}
    vault = %{vault | inserted_at: at}

    assert Boards.Arrangement.sort_boards([vault, a], "manual") == [a, vault]
    assert Boards.Arrangement.sort_boards([a, vault], "oldest") == [a, vault]
  end

  test "sorting reads a vault's activity and cards", ctx do
    %{a: a, b: b, vault: vault} = ctx
    now = DateTime.utc_now(:second)
    a = %{a | last_activity_at: DateTime.add(now, -60), cards: [%{}, %{}]}
    b = %{b | last_activity_at: DateTime.add(now, -120), cards: []}
    vault = %{vault | last_activity_at: now, card_count: 1}

    assert Boards.Arrangement.sort_boards([a, b, vault], "active") |> Enum.map(& &1.name) ==
             ~w(V A B)

    assert Boards.Arrangement.sort_boards([b, vault, a], "cards") |> Enum.map(& &1.name) ==
             ~w(A V B)

    assert Boards.Arrangement.sort_boards([b, vault, a], "name") |> Enum.map(& &1.name) ==
             ~w(A B V)
  end
end
