defmodule Slipdock.BoardKeyClaimsTest do
  @moduledoc """
  Board keys derived in one test step around the ones other running tests
  hold, rather than waiting on their uncommitted boards (#830).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{BoardKeyClaims, Boards}
  alias Slipdock.Boards.Board

  # A value no other test claims.
  defp value, do: "claim-#{System.unique_integer([:positive])}"

  # Another test, still running: a process registered as its own sandbox
  # owner, which claims `values` and then waits until it is told to stop.
  defp other_test(claims) do
    test = self()

    pid =
      spawn(fn ->
        BoardKeyClaims.register_test(self(), self())
        for {kind, value} <- claims, do: true = BoardKeyClaims.claim(kind, value)
        send(test, :claimed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :claimed
    pid
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  describe "claim/2" do
    test "a free value is the caller's, and stays so when asked again" do
      v = value()
      assert BoardKeyClaims.claim(:code, v)
      assert BoardKeyClaims.claim(:code, v)
    end

    test "a value another running test holds is refused, until that test ends" do
      v = value()
      other = other_test(code: v)

      refute BoardKeyClaims.claim(:code, v)

      stop(other)
      assert BoardKeyClaims.claim(:code, v)
    end

    test "codes and shortcuts are held apart" do
      v = value()
      other = other_test(code: v)

      assert BoardKeyClaims.claim(:shortcut, v)
      stop(other)
    end

    test "a process the test started claims for the test" do
      v = value()
      assert Task.async(fn -> BoardKeyClaims.claim(:code, v) end) |> Task.await()

      # The test holds it: it is still the test's own, and nobody else's.
      assert BoardKeyClaims.claim(:code, v)
      refute BoardKeyClaims.claim_new(:code, v)
    end

    test "a process that belongs to no test holds its own claims" do
      v = value()
      test = self()

      spawn(fn ->
        send(test, BoardKeyClaims.claim(:code, v))

        receive do
          :stop -> :ok
        end
      end)

      assert_receive true
      refute BoardKeyClaims.claim(:code, v)
    end
  end

  describe "claim_new/2" do
    test "is true only the first time, even for the same test" do
      v = value()
      assert BoardKeyClaims.claim_new(:shortcut, v)
      refute BoardKeyClaims.claim_new(:shortcut, v)
    end

    test "takes over a value whose test has ended" do
      v = value()
      stop(other_test(shortcut: v))
      assert BoardKeyClaims.claim_new(:shortcut, v)
    end
  end

  describe "deriving a board's keys" do
    test "a code another running test holds is passed over for the next one" do
      name = "Held #{System.unique_integer([:positive])}"
      code = Board.code_from_name(name)
      other = other_test(code: code)

      board = board_fixture(%{"name" => name}, derive_keys: true)
      assert board.code == Board.code_from_name(name, [code])

      stop(other)
    end

    test "a sub-board named after its card steps around a code another test holds" do
      title = "Epic #{System.unique_integer([:positive])}"
      code = Board.code_from_name(title)
      other = other_test(code: code)

      [column | _] = board_fixture().columns
      {:ok, t} = Boards.find_template("Simple")
      {:ok, sub} = Boards.create_sub_board(card_fixture(column, %{"title" => title}), t)
      refute sub.code == code

      stop(other)
    end

    test "a shortcut another running test holds is passed over for the next letter" do
      # Whatever "Q…" would get on its own, held elsewhere.
      name = "Qx #{System.unique_integer([:positive])}"
      wanted = Board.shortcut_from_name(name)
      other = other_test(shortcut: wanted)

      board = board_fixture(%{"name" => name}, derive_keys: true)
      refute board.shortcut == wanted

      stop(other)
    end

    test "a code this test derived is still its own to derive again" do
      name = "Mine #{System.unique_integer([:positive])}"
      code = Boards.suggest_code(name)
      assert Boards.suggest_code(name) == code
    end
  end

  test "board_fixture's shortcuts are claimed, so a derived shortcut can't be one" do
    shortcut = board_fixture().shortcut
    refute BoardKeyClaims.claim_new(:shortcut, shortcut)

    other =
      Task.async(fn ->
        BoardKeyClaims.register_test(self(), self())
        BoardKeyClaims.claim(:shortcut, shortcut)
      end)

    refute Task.await(other)
  end
end
