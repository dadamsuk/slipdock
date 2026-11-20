defmodule SlipdockWeb.PoolGrantsLiveTest do
  @moduledoc """
  "Who takes each pool's jobs" on the board's Runners panel (#3492): the
  owner grants a pool to a writer of the board and takes it back; a person
  who can't write the board is refused there, saying why.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Access
  alias Slipdock.Runners.PoolGrants

  setup %{user: user} do
    board = board_fixture(%{"name" => "Pool panel"}, owner: user)
    writer = user_fixture("panel-writer-#{System.unique_integer([:positive])}@example.com")
    {:ok, _} = Access.grant(board, writer, "write", user)
    %{board: board, writer: writer}
  end

  defp grant(view, pool, email),
    do:
      view
      |> form("#pool-grant-form", pool_grant: %{"pool" => pool, "email" => email})
      |> render_submit()

  test "the owner grants a pool and takes it back", %{conn: conn, board: board, writer: writer} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    assert has_element?(view, "#pool-grants", "Who takes each pool's jobs")
    refute has_element?(view, "#pool-grant-list")

    html = grant(view, "dev", writer.email)
    assert html =~ "#{writer.email} takes pool dev&#39;s jobs now."
    assert PoolGrants.may_take?(writer, board, "dev")

    [g] = PoolGrants.list(board)
    assert has_element?(view, "#pool-grant-#{g.id}", writer.email)

    view |> element("#revoke-pool-grant-#{g.id}") |> render_click()
    refute PoolGrants.may_take?(writer, board, "dev")
    refute has_element?(view, "#pool-grant-#{g.id}")
  end

  test "somebody who can't write the board isn't granted it", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")

    html = grant(view, "dev", "stranger@example.com")
    assert html =~ "share it with them first"
    assert PoolGrants.list(board) == []
  end

  test "a writer of the board doesn't see the section", %{board: board, writer: writer} do
    conn = build_conn() |> log_in_user(writer)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    refute has_element?(view, "#pool-grants")
  end
end
