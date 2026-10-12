defmodule SlipdockWeb.VaultChannelTest do
  @moduledoc "The websocket that tells a sync client a vault changed (W-103 R2.8)."
  use Slipdock.DataCase, async: true

  import Phoenix.ChannelTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Vaults, Wiki}
  alias SlipdockWeb.{UserSocket, VaultChannel}

  @endpoint SlipdockWeb.Endpoint

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "KB", "code" => "chankb"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
    {token, _} = Accounts.create_api_token(user, "sync", scope: "read")
    %{user: user, board: board, vault: vault, token: token}
  end

  test "an API token connects; a missing or dead one does not", %{token: token} do
    assert {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert socket.assigns.current_user
    assert :error = connect(UserSocket, %{"token" => "nonsense"})
    assert :error = connect(UserSocket, %{})
  end

  test "the owner joins by id or name, and is told each change's cursor", ctx do
    {:ok, socket} = connect(UserSocket, %{"token" => ctx.token})

    assert {:ok, %{vault_id: id}, _socket} =
             subscribe_and_join(socket, VaultChannel, "vault:Notes")

    assert id == ctx.vault.id

    {:ok, _} = Wiki.create_page(ctx.board, %{"title" => "New"}, user: ctx.user)
    assert_push "change", %{cursor: cursor}
    assert is_integer(cursor)
  end

  test "nobody else's vault can be joined", ctx do
    stranger = user_fixture("stranger@example.com")
    {token, _} = Accounts.create_api_token(stranger, "theirs")
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    assert {:error, %{reason: _}} =
             subscribe_and_join(socket, VaultChannel, "vault:#{ctx.vault.id}")
  end
end
