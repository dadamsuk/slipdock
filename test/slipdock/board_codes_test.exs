defmodule Slipdock.BoardCodesTest do
  # Sync: about the codes boards are given, so it uses real ones ("epic",
  # "qvm-1"), and an async test holding the same one would block or deadlock it.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.Board

  describe "code_from_name/2" do
    test "cuts a name down to a short, URL-safe code" do
      assert Board.code_from_name("QVM V1 Remediation") == "qvm-v1-rem"
      assert Board.code_from_name("Product launch") == "product-la"
      assert Board.code_from_name("Roadmap") == "roadmap"
      assert Board.code_from_name("  Spaces   &   symbols!  ") == "spaces-sym"
      assert Board.code_from_name("Café Núñez") == "cafe-nunez"
    end

    test "never ends on a hyphen and never exceeds the limit" do
      for name <- ["A B C D E F", "One-Two-Three-Four", "x" <> String.duplicate("y", 40)] do
        code = Board.code_from_name(name)
        assert String.length(code) <= Board.code_length()
        assert code =~ ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
      end
    end

    test "falls back to a code when the name has nothing usable in it" do
      assert Board.code_from_name("!!! ???") == "board"
      assert Board.code_from_name(nil) == "board"
    end

    test "works around codes that are taken, staying within the limit" do
      assert Board.code_from_name("QVM V1 Remediation", ["qvm-v1-rem"]) == "qvm-v1-re2"

      assert Board.code_from_name("QVM V1 Remediation", ["qvm-v1-rem", "qvm-v1-re2"]) ==
               "qvm-v1-re3"

      taken = Enum.map(2..99, &"qvm-v1-re#{&1}") ++ ["qvm-v1-rem"]
      code = Board.code_from_name("QVM V1 Remediation", taken)
      assert String.length(code) <= Board.code_length()
      refute code in taken
    end
  end

  describe "creating a board" do
    test "generates a code from the name" do
      board = board_fixture(%{"name" => "QVM V1 Remediation"}, derive_keys: true)
      assert board.code == "qvm-v1-rem"
    end

    test "keeps a code that is given, tidied up" do
      board = board_fixture(%{"name" => "Anything", "code" => " My Code "})
      assert board.code == "my-code"
    end

    test "refuses a code that is too long" do
      {:error, changeset} =
        Boards.create_board(%{"name" => "Too long", "code" => "abcdefghijk"})

      assert "should be at most 10 character(s)" in errors_on(changeset).code
    end

    test "two boards with the same name get different codes" do
      a = board_fixture(%{"name" => "QVM V1 Remediation"}, derive_keys: true)
      b = board_fixture(%{"name" => "QVM V1 Remediation"}, derive_keys: true)
      assert a.code == "qvm-v1-rem"
      assert b.code == "qvm-v1-re2"
    end

    test "a code already in use is refused" do
      board_fixture(%{"name" => "First", "code" => "taken"})

      assert {:error, changeset} =
               Boards.create_board(%{"name" => "Second", "code" => "taken"},
                 owner_id: user_fixture().id
               )

      assert "is already used by another board" in errors_on(changeset).code
    end

    test "sub-boards get a code of their own" do
      board = board_fixture(%{"name" => "Parent"}, derive_keys: true)
      card = card_fixture(hd(board.columns), %{"title" => "Query parser work"})
      template = hd(Boards.list_templates())

      {:ok, sub} = Boards.create_sub_board(card, template)
      assert sub.code == "query-pars"
    end
  end

  describe "updating a board" do
    setup do
      %{board: board_fixture(%{"name" => "QVM V1 Remediation"}, derive_keys: true)}
    end

    test "the code can be edited", %{board: board} do
      {:ok, board} = Boards.update_board(board, %{"code" => "QVM-1"})
      assert board.code == "qvm-1"
    end

    test "an update that leaves the code out keeps it", %{board: board} do
      {:ok, board} = Boards.update_board(board, %{"name" => "Something else entirely"})
      assert board.code == "qvm-v1-rem"
    end

    test "clearing the code takes a fresh one from the name", %{board: board} do
      {:ok, board} = Boards.update_board(board, %{"name" => "Billing rewrite", "code" => ""})
      assert board.code == "billing-re"
    end

    test "re-saving the same code is not a clash with itself", %{board: board} do
      {:ok, board} = Boards.update_board(board, %{"code" => "qvm-v1-rem"})
      assert board.code == "qvm-v1-rem"
    end

    test "another board's code is refused", %{board: board} do
      other = board_fixture(%{"name" => "Other", "code" => "other"})

      assert {:error, changeset} = Boards.update_board(board, %{"code" => other.code})
      assert "is already used by another board" in errors_on(changeset).code
    end
  end

  describe "finding a board" do
    test "by code, id and name" do
      board = board_fixture(%{"name" => "QVM V1 Remediation"}, derive_keys: true)

      assert {:ok, %{id: id}} = Boards.find_board("qvm-v1-rem")
      assert id == board.id
      assert {:ok, %{id: ^id}} = Boards.find_board("QVM-V1-REM")
      assert {:ok, %{id: ^id}} = Boards.find_board(to_string(board.id))
      assert {:ok, %{id: ^id}} = Boards.find_board("qvm v1 remediation")
      assert Boards.find_board("no-such-thing") == {:error, :not_found}
    end

    test "a code beats another board that happens to be named the same" do
      named = board_fixture(%{"name" => "handle", "code" => "named-one"})
      coded = board_fixture(%{"name" => "Something else", "code" => "handle"})

      assert {:ok, %{id: id}} = Boards.find_board("handle")
      assert id == coded.id
      assert {:ok, %{id: id}} = Boards.find_board("named-one")
      assert id == named.id
    end
  end

  describe "suggest_code/2" do
    test "skips codes that are already in the database" do
      board = board_fixture(%{"name" => "QVM V1 Remediation"}, derive_keys: true)

      assert Boards.suggest_code("QVM V1 Remediation") == "qvm-v1-re2"
      assert Boards.suggest_code("QVM V1 Remediation", board.id) == "qvm-v1-rem"
    end
  end
end
