defmodule Slipdock.SupportAccessTest do
  @moduledoc """
  An admin looking at somebody's boards to help them.

  The access is not the interesting part — whoever runs the server can read the
  database regardless. What these tests are about is that it cannot be silent,
  cannot be permanent, and cannot be used to change anything.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Access, Accounts, Settings}

  setup do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => "admin@example.com",
        "smtp_host" => "smtp.example.com",
        "smtp_from_email" => "mail@example.com"
      })

    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    customer = user_fixture("customer@example.com")
    board = board_fixture(%{"name" => "Theirs"}, owner: customer)

    %{admin: admin, customer: customer, board: board}
  end

  test "an admin cannot read somebody's boards without one", %{admin: admin, board: board} do
    # Being an admin is about running the server, not about reading everybody's
    # work. The two are deliberately separate.
    assert Access.board_permission(admin, board) == :none
  end

  test "opening one grants read access, and only read", %{
    admin: admin,
    customer: customer,
    board: board
  } do
    assert {:ok, _} = Accounts.open_support_session(admin, customer, "they reported a lost card")

    assert Access.board_permission(admin, board) == :read
    refute Access.can_write?(Access.board_permission(admin, board))
  end

  test "the person is told, at the time, with the reason", %{admin: admin, customer: customer} do
    {:ok, _} = Accounts.open_support_session(admin, customer, "they reported a lost card")

    assert_received {:email, %Swoosh.Email{to: [{_, "customer@example.com"}], text_body: body}}
    assert body =~ "admin@example.com"
    assert body =~ "they reported a lost card"
  end

  test "it needs a reason worth writing down", %{admin: admin, customer: customer} do
    assert {:error, changeset} = Accounts.open_support_session(admin, customer, "")
    assert %{reason: [_ | _]} = errors_on(changeset)

    assert {:error, changeset} = Accounts.open_support_session(admin, customer, "x")
    assert %{reason: [_ | _]} = errors_on(changeset)
  end

  test "it expires on its own", %{admin: admin, customer: customer, board: board} do
    past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

    {:ok, _} =
      Accounts.open_support_session(admin, customer, "looking at a problem", expires_at: past)

    # Forgetting to end one is not the same as keeping it.
    refute Accounts.support_access?(admin, customer.id)
    assert Access.board_permission(admin, board) == :none
  end

  test "it can be ended early", %{admin: admin, customer: customer, board: board} do
    {:ok, session} = Accounts.open_support_session(admin, customer, "looking at a problem")
    assert Access.board_permission(admin, board) == :read

    {:ok, _} = Accounts.end_support_session(session)
    assert Access.board_permission(admin, board) == :none
  end

  test "the person it is about can see every one, ever", %{admin: admin, customer: customer} do
    {:ok, session} = Accounts.open_support_session(admin, customer, "a lost card")
    {:ok, _} = Accounts.end_support_session(session)

    # Including the ones that are over: a log you can only read while it is
    # happening is not a log.
    assert [recorded] = Accounts.support_sessions_for(customer)
    assert recorded.reason == "a lost card"
    assert recorded.admin.email == "admin@example.com"
    assert recorded.ended_at
  end

  test "a non-admin cannot open one", %{customer: customer} do
    other = user_fixture("other@example.com")
    assert {:error, :not_admin} = Accounts.open_support_session(other, customer, "curiosity")
  end

  test "an admin cannot open one on themselves", %{admin: admin} do
    # They can already see their own boards, and a record saying otherwise
    # would be noise in the one list that has to stay readable.
    assert {:error, :self} = Accounts.open_support_session(admin, admin, "testing")
  end

  test "it reaches sub-boards, because a tree belongs to its root's owner", %{
    admin: admin,
    customer: customer,
    board: board
  } do
    card = card_fixture(hd(board.columns), %{"title" => "Epic"})
    {:ok, sub} = Slipdock.Boards.create_sub_board(card, hd(Slipdock.Boards.list_templates()))

    {:ok, _} = Accounts.open_support_session(admin, customer, "a lost card")

    assert Access.board_permission(admin, Slipdock.Boards.get_board!(sub.id)) == :read
  end
end
