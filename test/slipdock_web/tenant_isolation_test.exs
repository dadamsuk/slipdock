defmodule SlipdockWeb.TenantIsolationTest do
  @moduledoc """
  Two unrelated people on one server, in `shared_only` mode: neither learns
  that the other exists, through any surface that lists people — then one
  shares a card and they do, and revoking takes it away again.

  These are the tests that make hosting Slipdock for strangers defensible, so
  they are deliberately about the *surfaces* rather than about
  `Access.visible_users/1`, which has its own unit tests. A correct function
  with one forgotten call site is still a leak.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, QuickAdd, Settings}

  setup do
    # Writing any setting creates the row, whose `setup_completed_at` is nil —
    # at which point the app decides it has never been set up and sends every
    # request to the wizard. The test environment's `setup_completed: true` is
    # only a *default*, and defaults stop applying the moment a row exists.
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    {:ok, _} = Settings.update(%{"user_directory" => "shared_only"})

    alice = user_fixture("alice@example.com")
    acme = user_fixture("acme@other.example")

    alice_board = board_fixture(%{"name" => "Alice's work"}, owner: alice)
    acme_board = board_fixture(%{"name" => "Acme's work"}, owner: acme)
    card_fixture(hd(acme_board.columns), %{"title" => "Acme's secret plan"})
    alice_card = card_fixture(hd(alice_board.columns), %{"title" => "Alice's card"})

    %{
      alice: alice,
      acme: acme,
      alice_board: alice_board,
      acme_board: acme_board,
      alice_card: alice_card
    }
  end

  describe "two strangers sharing a server" do
    test "the assignee picker does not name the other customer", %{
      conn: conn,
      alice: alice,
      acme: acme,
      alice_board: board,
      alice_card: card
    } do
      # The picker is rendered with the card panel, not on the board itself —
      # asserting against the board index passes whatever the code does.
      {:ok, _view, html} =
        live(log_in_user(conn, alice), ~p"/boards/#{board.id}/cards/#{card.id}")

      assert html =~ "Alice&#39;s card"
      assert html =~ display_name(alice)
      refute html =~ acme.email
      refute html =~ display_name(acme)
    end

    test "quick add offers only people you share something with", %{alice: alice, acme: acme} do
      emails =
        alice |> QuickAdd.Capture.catalogue() |> Map.get(:people, []) |> Enum.map(& &1.email)

      assert alice.email in emails
      refute acme.email in emails
    end

    test "an automation rule on your board cannot name them", %{
      alice_board: board,
      acme: acme,
      alice: alice
    } do
      # The rule parser's prompt and the runner's assignee lookup both go
      # through this, scoped to the board's owner.
      visible = board |> Slipdock.Repo.reload() |> Access.visible_users_for()

      assert alice.email in Enum.map(visible, & &1.email)
      refute acme.email in Enum.map(visible, & &1.email)
    end

    test "search finds nothing of theirs", %{conn: conn, alice: alice} do
      {:ok, _view, html} = live(log_in_user(conn, alice), ~p"/search?q=secret+plan")
      refute html =~ "Acme's secret plan"
    end

    test "their board is not listed, nor reachable by guessing its id", %{
      conn: conn,
      alice: alice,
      acme_board: board
    } do
      {:ok, _view, html} = live(log_in_user(conn, alice), ~p"/")
      refute html =~ "Acme's work"

      assert {:error, {_, _}} = live(log_in_user(conn, alice), ~p"/boards/#{board.id}")
    end

    test "the API does not hand one of them the other", %{conn: conn, alice: alice, acme: acme} do
      conn = api_conn(conn, alice)
      body = conn |> get(~p"/api/boards") |> json_response(200)

      refute inspect(body) =~ acme.email
      refute inspect(body) =~ "Acme's work"
    end
  end

  describe "once something is shared" do
    setup %{alice: alice, acme: acme, alice_board: board} do
      {:ok, grant} = Access.grant(board, acme, "write", alice)
      %{grant: grant}
    end

    test "each appears in the other's picker", %{
      conn: conn,
      alice: alice,
      acme: acme,
      alice_board: board,
      alice_card: card
    } do
      {:ok, _view, html} =
        live(log_in_user(conn, alice), ~p"/boards/#{board.id}/cards/#{card.id}")

      assert html =~ display_name(acme)

      {:ok, _view, html} = live(log_in_user(conn, acme), ~p"/boards/#{board.id}/cards/#{card.id}")
      assert html =~ display_name(alice)
    end

    test "revoking takes it away again", %{
      conn: conn,
      alice: alice,
      acme: acme,
      alice_board: board,
      alice_card: card,
      grant: grant
    } do
      {:ok, _} = Access.revoke(grant)

      {:ok, _view, html} =
        live(log_in_user(conn, alice), ~p"/boards/#{board.id}/cards/#{card.id}")

      refute html =~ acme.email
      refute html =~ display_name(acme)

      # And the board goes with it.
      assert {:error, {_, _}} = live(log_in_user(conn, acme), ~p"/boards/#{board.id}")
    end
  end

  describe "instance mode" do
    test "the directory still lists everybody, but a card only takes people who can open it",
         %{conn: conn, alice: alice, acme: acme, alice_board: board, alice_card: card} do
      {:ok, _} = Settings.update(%{"user_directory" => "instance"})

      assert acme.id in Enum.map(Access.visible_users(alice), & &1.id)

      # Assigning somebody to a card they cannot open would email them its
      # title and tell the assigner they have an account, whatever the
      # directory says — so the picker offers the board's people only.
      {:ok, _view, html} =
        live(log_in_user(conn, alice), ~p"/boards/#{board.id}/cards/#{card.id}")

      refute html =~ display_name(acme)

      {:ok, _} = Access.grant(board, acme, "read", alice)

      {:ok, _view, html} =
        live(log_in_user(conn, alice), ~p"/boards/#{board.id}/cards/#{card.id}")

      assert html =~ display_name(acme)
    end
  end

  defp display_name(user), do: Slipdock.Accounts.User.display_name(user)

  defp api_conn(conn, user) do
    {token, _} = Slipdock.Accounts.create_api_token(user, "test")

    conn
    |> Phoenix.ConnTest.recycle()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end
end
