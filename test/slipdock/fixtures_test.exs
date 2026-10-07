defmodule Slipdock.FixturesTest do
  @moduledoc """
  The fixtures that keep async tests from waiting on each other: a default
  user, addresses, board codes and shortcuts that no other running test is
  using. Each of these used to be one shared value, and every test that
  inserted it queued behind every other one that had.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards

  test "the default user's email is this test's own, and the same on every call" do
    email = default_email()

    assert email =~ ~r/^tester@t\d+\.example\.com$/
    assert default_email() == email
    assert user_fixture().email == email
    assert user_fixture().id == user_fixture().id
  end

  test "another process gets a default email of its own" do
    mine = default_email()
    theirs = Task.async(&default_email/0) |> Task.await()

    refute theirs == mine
  end

  test "an @example.com address moves to this test's domain, and nothing else does" do
    domain = default_email() |> String.split("@") |> List.last()

    assert fixture_email("stranger@example.com") == "stranger@" <> domain
    assert user_fixture("stranger@example.com").email == "stranger@" <> domain
    assert fixture_email("someone@example.net") == "someone@example.net"
    assert fixture_email("someone@work.example") == "someone@work.example"

    # Already moved: left alone, so it is safe to apply twice.
    assert fixture_email(fixture_email("stranger@example.com")) == "stranger@" <> domain
  end

  test "a sync test keeps the address as written" do
    mark_async(false)
    on_exit(fn -> mark_async(true) end)

    assert fixture_email("stranger@example.com") == "stranger@example.com"
  end

  test "sub_board/2 gives the sub-board a code of its own, not the card's title" do
    board = board_fixture(%{"name" => "Root"})
    card = card_fixture(hd(board.columns), %{"title" => "Epic"})
    {:ok, t} = Boards.find_template("Simple")

    {:ok, sub} = sub_board(card, t)

    assert sub.name == "Epic"
    assert sub.code =~ ~r/^t[0-9a-z]+$/
    assert {:error, "This card already has subcards."} = sub_board(card, t)
  end

  test "create_sub_board/3 takes a code, and still derives one without" do
    board = board_fixture(%{"name" => "Root"})
    [col | _] = board.columns
    {:ok, t} = Boards.find_template("Simple")
    code = "s" <> String.downcase(Integer.to_string(System.unique_integer([:positive]), 36))

    {:ok, given} =
      Boards.create_sub_board(card_fixture(col, %{"title" => "Given"}), t, code: code)

    assert given.code == code

    title = "Derived #{System.unique_integer([:positive])}"
    {:ok, derived} = Boards.create_sub_board(card_fixture(col, %{"title" => title}), t)
    assert derived.code == Boards.suggest_code(title, derived.id)
  end

  test "board shortcuts are two characters and not handed out twice while held" do
    shortcuts = for _ <- 1..20, do: board_fixture().shortcut

    assert Enum.all?(shortcuts, &(String.length(&1) == 2))
    assert Enum.uniq(shortcuts) == shortcuts
  end
end
