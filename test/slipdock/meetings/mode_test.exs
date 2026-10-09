defmodule Slipdock.Meetings.ModeTest do
  @moduledoc """
  Meeting mode (W-87, #530): off by default, and while on, where it shows
  for whom — the tab, the board menu's one entry, or nothing.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Meetings, Repo, Settings}
  alias Slipdock.Boards.Board

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)
    %{user: user, board: board}
  end

  defp turn_on(attrs \\ %{}),
    do: {:ok, _} = Settings.update(Map.merge(%{"meetings_enabled" => true}, attrs))

  test "is off on a server nobody has touched", %{user: user, board: board} do
    refute Meetings.enabled?()
    refute Meetings.available?(user)
    assert Meetings.presence(user, board) == :none
    assert %{enabled: false} = Meetings.mode(user)
  end

  test "on and used_only: a board with no capture gets the menu entry, then the tab", %{
    user: user,
    board: board
  } do
    turn_on()
    assert Meetings.visibility() == :used_only
    assert Meetings.presence(user, board) == :menu

    marked = Meetings.mark_used(board)
    assert marked.meetings_used_at
    assert Meetings.presence(user, marked) == :tab
    # Stored, not only on the struct handed back.
    assert Meetings.presence(user, Repo.get!(Board, board.id)) == :tab
  end

  test "the first capture's stamp is the one kept", %{board: board} do
    first = Meetings.mark_used(board)
    again = Meetings.mark_used(%{board | meetings_used_at: nil})

    assert Repo.get!(Board, board.id).meetings_used_at == first.meetings_used_at
    assert again.meetings_used_at >= first.meetings_used_at
    assert Meetings.mark_used(first) == first
  end

  test "on every board: the tab everywhere, captured or not", %{user: user, board: board} do
    turn_on(%{"meetings_visibility" => "every_board"})
    assert Meetings.presence(user, board) == :tab
  end

  test "a person who hides it sees nothing, even where there are captures", %{
    user: user,
    board: board
  } do
    turn_on(%{"meetings_visibility" => "every_board"})
    {:ok, user} = Accounts.update_display(user, %{"hide_meetings" => "true"})
    board = Meetings.mark_used(board)

    assert Meetings.hidden_by?(user)
    refute Meetings.available?(user)
    assert Meetings.presence(user, board) == :none
    assert %{enabled: true, hidden: true} = Meetings.mode(user)
  end

  test "hiding counts only while the admin lets people hide it", %{user: user, board: board} do
    turn_on(%{"meetings_hideable" => false})
    {:ok, user} = Accounts.update_display(user, %{"hide_meetings" => "true"})

    refute Meetings.hidden_by?(user)
    assert Meetings.presence(user, board) == :menu
  end

  test "turning it off hides everything and forgets nothing", %{user: user, board: board} do
    turn_on()
    board = Meetings.mark_used(board)
    {:ok, _} = Settings.update(%{"meetings_enabled" => false})

    assert Meetings.presence(user, board) == :none

    turn_on()
    assert Meetings.presence(user, Repo.get!(Board, board.id)) == :tab
  end

  test "nobody signed in sees none of it", %{board: board} do
    turn_on(%{"meetings_visibility" => "every_board"})
    refute Meetings.available?(nil)
    assert Meetings.presence(nil, board) == :none
  end

  test "an unknown visibility is refused" do
    assert {:error, cs} = Settings.update(%{"meetings_visibility" => "sometimes"})
    assert %{meetings_visibility: [_]} = errors_on(cs)
  end
end
