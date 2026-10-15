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
    assert sub.code =~ ~r/^fx[0-9a-z]+$/
    assert {:error, "This card already has subcards."} = sub_board(card, t)
  end

  test "create_sub_board/3 takes a code, and still derives one without" do
    board = board_fixture(%{"name" => "Root"})
    [col | _] = board.columns
    {:ok, t} = Boards.find_template("Simple")
    code = unique_code()

    {:ok, given} =
      Boards.create_sub_board(card_fixture(col, %{"title" => "Given"}), t, code: code)

    assert given.code == code

    title = "Derived #{System.unique_integer([:positive])}"
    {:ok, derived} = Boards.create_sub_board(card_fixture(col, %{"title" => title}), t)
    assert derived.code == Boards.suggest_code(title, derived.id)
  end

  test "board codes come from a namespace other tests' codes and names don't reach" do
    codes = for _ <- 1..20, do: board_fixture().code

    assert Enum.all?(codes, &(&1 =~ ~r/^fx[0-9a-z]+$/))
    assert Enum.uniq(codes) == codes
    refute unique_code() in codes

    # The old "t" prefix handed out codes like these, which other tests set
    # by hand or derive from a board's name, and the insert then waited on
    # that test's uncommitted board.
    for code <- ~w(taken team todo tiny tick tess) do
      refute code =~ ~r/^fx/
      refute Boards.suggest_code(String.capitalize(code)) =~ ~r/^fx/
    end
  end

  test "a shortcut taken by hand is held for this test, and a board can have it" do
    key = unique_shortcut()
    assert key =~ ~r/^[0-9a-z]{2}$/

    theirs = Task.async(fn -> for _ <- 1..20, do: board_fixture().shortcut end) |> Task.await()
    refute key in theirs

    board = board_fixture()
    assert {:ok, %{shortcut: ^key}} = Boards.update_board(board, %{"shortcut" => key})
  end

  test "board shortcuts are two characters and not handed out twice while held" do
    shortcuts = for _ <- 1..20, do: board_fixture().shortcut

    assert Enum.all?(shortcuts, &(String.length(&1) == 2))
    assert Enum.uniq(shortcuts) == shortcuts
  end

  # A board code written into a test by hand is the one key `board_fixture/2`
  # can't make unique. Two async modules giving a board the same one queue on
  # `boards_code_index`, the second until the first's test ends, and on a busy
  # run that was past the query timeout: setups failed with "canceling
  # statement due to user request" in whichever test lost (#788). Within one
  # module tests run one at a time, so a module may reuse its own codes.
  describe "board codes written into async tests" do
    test "no two async modules use the same one" do
      shared =
        Path.wildcard("test/**/*_test.exs")
        |> Enum.map(&{&1, File.read!(&1)})
        |> shared_codes()

      assert shared == %{},
             "Board codes used in more than one async test module wait on each other " <>
               "(#788); give each module its own:\n" <>
               Enum.map_join(shared, "\n", fn {code, files} ->
                 "  #{code}: #{Enum.join(files, ", ")}"
               end)
    end

    test "the check sees both spellings in either case, and leaves sync modules and other modules' uses alone" do
      async = "use Slipdock.DataCase, async: true\n"

      sources = [
        {"a_test.exs", async <> ~s|board_fixture(%{"code" => "same"})\n"code" => "same"|},
        {"b_test.exs", async <> ~s|create_sub_board(card, name, code: "same")|},
        {"c_test.exs", async <> ~s|board_fixture(%{"code" => "solo"})|},
        {"d_test.exs", "use Slipdock.DataCase, async: false\n" <> ~s|"code" => "solo"|},
        {"e_test.exs", async <> ~s|assert %{"code" => -32600} = error|},
        {"f_test.exs", async <> ~s|board_fixture(%{"code" => "PL"})|},
        {"g_test.exs", async <> ~s|board_fixture(%{"code" => "pl"})|}
      ]

      assert shared_codes(sources) == %{
               "same" => ["a_test.exs", "b_test.exs"],
               "pl" => ["f_test.exs", "g_test.exs"]
             }
    end
  end

  defp shared_codes(sources) do
    sources
    |> Enum.reject(fn {_, source} -> source =~ "async: false" end)
    |> Enum.flat_map(fn {path, source} ->
      ~r/(?:"code" =>|code:) "([A-Za-z0-9-]+)"/
      |> Regex.scan(source, capture: :all_but_first)
      # A board's code is kept in lower case, so "PL" and "pl" are one code.
      |> Enum.map(fn [code] -> {String.downcase(code), path} end)
      |> Enum.uniq()
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.filter(fn {_, paths} -> length(paths) > 1 end)
  end
end
