defmodule SlipdockWeb.WelcomeBoardTest do
  @moduledoc """
  The two doors to the tour board (see `Slipdock.Onboarding`): signing in for
  the first time, which builds one and lands on it, and asking for one over
  the API for an account that has been here before.
  """
  use SlipdockWeb.ConnCase, async: false

  alias Slipdock.{Access, Accounts, Onboarding}
  alias Slipdock.Search.Indexer

  setup do
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()

    previous = Application.get_env(:slipdock, :welcome_board)
    Application.put_env(:slipdock, :welcome_board, true)

    on_exit(fn ->
      Application.put_env(:slipdock, :welcome_board, previous)
      drain(20)
    end)
  end

  defp drain(0), do: :ok

  defp drain(tries) do
    if Indexer.pending() > 0 do
      Indexer.flush()
      drain(tries - 1)
    end
  end

  @tag :anonymous
  test "a first sign-in builds the tour and lands on it", %{conn: conn} do
    {:ok, newcomer} = Accounts.get_or_create_user_by_email("newcomer@example.com")
    token = Accounts.create_sign_in_token(newcomer)

    conn = post(conn, ~p"/login/#{token}")

    assert [board] = Access.list_boards(newcomer)
    assert board.name == Onboarding.board_name()
    assert redirected_to(conn) == "/boards/#{board.id}"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "tour"

    # And not a second time: the account has signed in now.
    token = Accounts.create_sign_in_token(Accounts.get_user!(newcomer.id))
    conn = conn |> recycle() |> post(~p"/login/#{token}")

    assert redirected_to(conn) == "/"
    assert length(Access.list_boards(newcomer)) == 1
  end

  @tag :anonymous
  test "somebody who already owns a board is sent to the board index", %{conn: conn} do
    {:ok, owner} = Accounts.get_or_create_user_by_email("owner@example.com")
    Slipdock.Fixtures.board_fixture(%{"name" => "Real work"}, owner: owner)

    conn = post(conn, ~p"/login/#{Accounts.create_sign_in_token(owner)}")

    assert redirected_to(conn) == "/"
    assert ["Real work"] = owner |> Access.list_boards() |> Enum.map(& &1.name)
  end

  describe "POST /api/boards/welcome" do
    test "builds the tour for an account that wants it back", %{conn: conn, user: user} do
      conn = post(conn, ~p"/api/boards/welcome")
      assert %{"board" => board} = json_response(conn, 201)
      assert board["name"] == Onboarding.board_name()
      assert Onboarding.exists_for?(user)
    end

    test "refuses a second one unless forced", %{conn: conn, user: user} do
      Onboarding.build!(user)

      assert %{"error" => message} = conn |> post(~p"/api/boards/welcome") |> json_response(409)
      assert message =~ "already"

      assert %{"board" => _} =
               conn |> post(~p"/api/boards/welcome", %{"force" => true}) |> json_response(201)

      assert length(Access.list_boards(user)) == 2
    end
  end
end
