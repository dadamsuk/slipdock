defmodule Slipdock.SupportAccessTest do
  @moduledoc """
  An admin looking at somebody's boards to help them.

  The access is not the interesting part — whoever runs the server can read the
  database regardless. What these tests are about is that it cannot be silent,
  cannot be permanent, and cannot be used to change anything.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Settings}

  setup do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => fixture_email("admin@example.com"),
        "smtp_host" => "smtp.example.com",
        "smtp_from_email" => fixture_email("mail@example.com")
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

  test "ends when the admin is demoted or disabled", %{
    admin: admin,
    customer: customer,
    board: board
  } do
    {:ok, _} = Accounts.promote(user_fixture("second@example.com"))
    {:ok, _} = Accounts.open_support_session(admin, customer, "they reported a lost card")
    assert Access.board_permission(admin, board) == :read

    {:ok, _} = Accounts.demote(admin)
    assert Access.board_permission(admin, board) == :none

    {:ok, admin} = Accounts.promote(Repo.reload(admin))
    assert Access.board_permission(admin, board) == :read

    {:ok, _} = Accounts.disable(admin)
    assert Access.board_permission(admin, board) == :none
  end

  test "the person is told, at the time, with the reason", %{admin: admin, customer: customer} do
    {:ok, _} = Accounts.open_support_session(admin, customer, "they reported a lost card")

    customer_email = fixture_email("customer@example.com")

    assert_received {:email,
                     %Swoosh.Email{
                       to: [{_, ^customer_email}],
                       text_body: body
                     }}

    assert body =~ fixture_email("admin@example.com")
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
    assert recorded.admin.email == fixture_email("admin@example.com")
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
    {:ok, sub} = sub_board(card, hd(Slipdock.Boards.list_templates(nil)))

    {:ok, _} = Accounts.open_support_session(admin, customer, "a lost card")

    assert Access.board_permission(admin, Slipdock.Boards.get_board!(sub.id)) == :read
  end

  describe "supported_boards/1, the way in" do
    test "lists each session's person and their own top-level boards, by name", %{
      admin: admin,
      customer: customer,
      board: board
    } do
      assert Access.supported_boards(admin) == []

      other = board_fixture(%{"name" => "Another of theirs"}, owner: customer)
      archived = board_fixture(%{"name" => "Put away"}, owner: customer)
      {:ok, _} = Slipdock.Boards.archive_board(archived)
      card = card_fixture(hd(board.columns), %{"title" => "Epic"})
      {:ok, _} = sub_board(card, hd(Slipdock.Boards.list_templates(nil)))
      _not_theirs = board_fixture(%{"name" => "Somebody else's"}, owner: user_fixture())

      {:ok, session} = Accounts.open_support_session(admin, customer, "a lost card")

      assert [%{session: %{id: id}, subject: subject, boards: boards}] =
               Access.supported_boards(admin)

      assert id == session.id
      assert subject.id == customer.id
      # Sub-boards are reached from their parent card; archived ones are put away.
      assert Enum.map(boards, & &1.id) == [other.id, board.id]

      # Every board it lists is one the session lets them read.
      assert Enum.all?(boards, &(Access.board_permission(admin, &1) == :read))

      # Still not among their own: the index is theirs alone.
      refute Enum.any?(Access.list_boards(admin), &(&1.owner_id == customer.id))
    end

    test "drops a session once it ends, expires, or its admin is demoted", %{
      admin: admin,
      customer: customer
    } do
      {:ok, session} = Accounts.open_support_session(admin, customer, "a lost card")
      {:ok, _} = Accounts.end_support_session(session)
      assert Access.supported_boards(admin) == []

      past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      {:ok, _} = Accounts.open_support_session(admin, customer, "again", expires_at: past)
      assert Access.supported_boards(admin) == []

      {:ok, _} = Accounts.promote(user_fixture("third@example.com"))
      {:ok, _} = Accounts.open_support_session(admin, customer, "once more")
      assert [_] = Access.supported_boards(admin)
      {:ok, admin} = Accounts.demote(admin)
      assert Access.supported_boards(admin) == []
    end

    test "is only the sessions this admin holds", %{admin: admin, customer: customer} do
      {:ok, second} = Accounts.promote(user_fixture("second@example.com"))
      {:ok, _} = Accounts.open_support_session(second, customer, "theirs, not mine")

      assert Access.supported_boards(admin) == []
      assert [_] = Access.supported_boards(second)
      assert Access.supported_boards(nil) == []
    end
  end
end
