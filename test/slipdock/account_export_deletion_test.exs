defmodule Slipdock.AccountExportDeletionTest do
  @moduledoc """
  Leaving: taking your work with you, and being removed.

  `disable/1` stops an account; it does not answer "delete my account", which
  on a server people pay for they are entitled to ask. These are the two halves
  of that answer.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{AccountExport, Accounts, Access, Boards}

  setup do
    user = user_fixture("leaver@example.com")
    board = board_fixture(%{"name" => "Their work"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "A card of theirs"})
    %{user: user, board: board, card: card}
  end

  describe "export" do
    test "is a zip with the account, the boards and the cards in them", %{user: user} do
      {name, binary} = AccountExport.zip(user)

      assert name =~ "slipdock-leaver-example-com"
      {:ok, entries} = :zip.unzip(binary, [:memory])
      paths = Enum.map(entries, fn {path, _} -> to_string(path) end)

      assert "account.json" in paths
      assert Enum.any?(paths, &String.starts_with?(&1, "boards/"))

      {_, json} = Enum.find(entries, fn {p, _} -> to_string(p) == "account.json" end)
      account = Jason.decode!(json)
      assert account["email"] == "leaver@example.com"
      assert [%{"name" => "Their work"}] = account["boards_owned"]

      {_, board_json} = Enum.find(entries, fn {p, _} -> to_string(p) =~ "boards/" end)

      assert Jason.decode!(board_json)
             |> get_in(["lists"])
             |> Enum.any?(fn list ->
               Enum.any?(list["cards"], &(&1["title"] == "A card of theirs"))
             end)
    end

    test "includes what they wrote on other people's boards", %{user: user} do
      other = user_fixture("other@example.com")
      their_board = board_fixture(%{"name" => "Somebody else's"}, owner: other)
      card = card_fixture(hd(their_board.columns))

      {:ok, _} =
        Boards.add_status_update(card, user, %{"health" => "at_risk", "body" => "slipping a week"})

      {_name, binary} = AccountExport.zip(user)
      {:ok, entries} = :zip.unzip(binary, [:memory])

      # Theirs, and in no other export: that board belongs to somebody else.
      {_, json} =
        Enum.find(entries, fn {p, _} -> to_string(p) == "elsewhere/written-by-you.json" end)

      assert Jason.decode!(json)["status_updates"] |> hd() |> Map.get("body") =~ "slipping"
    end
  end

  describe "deletion" do
    test "says what it will do before it does it", %{user: user} do
      preview = Accounts.deletion_preview(user)

      assert preview.boards_deleted == ["Their work"]
      assert preview.boards_handed_over == []
      assert preview.cards_deleted == 1
      refute preview.last_admin?
    end

    test "takes their own boards and cards with them", %{user: user, board: board, card: card} do
      assert {:ok, %{email: "leaver@example.com"}} = Accounts.delete_user(user)

      refute Accounts.get_user_by_email("leaver@example.com")
      refute Repo.get(Slipdock.Boards.Board, board.id)
      refute Repo.get(Slipdock.Boards.Card, card.id)
    end

    test "hands a shared board on rather than deleting other people's work", %{
      user: user,
      board: board,
      card: card
    } do
      colleague = user_fixture("colleague@example.com")
      {:ok, _} = Access.grant(board, colleague, "write", user)

      assert {:ok, %{handed_over: [%{to: "colleague@example.com"}]}} = Accounts.delete_user(user)

      # The board survives, with its cards, under its new owner.
      assert Repo.get(Slipdock.Boards.Board, board.id).owner_id == colleague.id
      assert Repo.get(Slipdock.Boards.Card, card.id)
    end

    test "a writer inherits before a reader", %{user: user, board: board} do
      reader = user_fixture("reader@example.com")
      writer = user_fixture("writer@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)
      {:ok, _} = Access.grant(board, writer, "write", user)

      {:ok, %{handed_over: [%{to: to}]}} = Accounts.delete_user(user)
      assert to == "writer@example.com"
    end

    test "what they wrote elsewhere survives, with no author", %{user: user} do
      other = user_fixture("other@example.com")
      their_board = board_fixture(%{"name" => "Somebody else's"}, owner: other)
      card = card_fixture(hd(their_board.columns))

      {:ok, update} =
        Boards.add_status_update(card, user, %{"health" => "at_risk", "body" => "still readable"})

      {:ok, _} = Accounts.delete_user(user)

      # The words were addressed to other people, and a history with holes in
      # it is unreadable.
      kept = Repo.get(Slipdock.Boards.StatusUpdate, update.id)
      assert kept.body == "still readable"
      assert kept.user_id == nil
    end

    test "a shared board's sub-boards go to the successor with it", %{user: user, board: board} do
      colleague = user_fixture("colleague@example.com")
      {:ok, _} = Access.grant(board, colleague, "write", user)

      epic = card_fixture(hd(board.columns), %{"title" => "Epic"})
      {:ok, t} = Boards.find_template("Simple")
      {:ok, sub} = Boards.create_sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      task = card_fixture(hd(sub.columns), %{"title" => "Task"})
      {:ok, subsub} = Boards.create_sub_board(task, t)

      assert {:ok, %{handed_over: [%{to: "colleague@example.com"}]}} = Accounts.delete_user(user)

      for b <- [board, sub, subsub] do
        assert Repo.get(Slipdock.Boards.Board, b.id).owner_id == colleague.id
      end

      assert Repo.get(Slipdock.Boards.Card, task.id)
    end

    test "the preview names root boards only", %{user: user, board: board} do
      epic = card_fixture(hd(board.columns), %{"title" => "Epic"})
      {:ok, t} = Boards.find_template("Simple")
      {:ok, _} = Boards.create_sub_board(epic, t)

      assert Accounts.deletion_preview(user).boards_deleted == ["Their work"]
    end

    test "an admin who opened a support session can still be deleted", %{user: user} do
      {:ok, admin} = Accounts.promote(user_fixture("helper@example.com"))
      {:ok, _} = Accounts.promote(user_fixture("remaining@example.com"))
      {:ok, session} = Accounts.open_support_session(admin, user, "looking into a bug")

      assert {:ok, _} = Accounts.delete_user(admin)

      # The record stays for the person it was about, with the admin nulled.
      kept = Repo.get(Slipdock.Accounts.SupportSession, session.id)
      assert kept.admin_id == nil
      assert Slipdock.Accounts.User.display_name(nil) == "a deleted account"
    end

    test "their uploaded files go with their boards, card and page alike", %{
      user: user,
      board: board,
      card: card
    } do
      src = Path.join(System.tmp_dir!(), "leaver-#{System.unique_integer([:positive])}.txt")
      File.write!(src, "theirs")
      on_exit(fn -> File.rm(src) end)

      meta = %{filename: "a.txt", content_type: "text/plain"}
      {:ok, on_card} = Boards.add_attachment(card, meta, src)
      page = page_fixture(board, %{"title" => "Notes"})
      {:ok, on_page} = Slipdock.Wiki.add_attachment(page, meta, src)

      paths = Enum.map([on_card, on_page], &Boards.attachment_path/1)
      assert Enum.all?(paths, &File.exists?/1)

      {:ok, _} = Accounts.delete_user(user)

      refute Enum.any?(paths, &File.exists?/1)
    end

    test "a handed-over board keeps its files", %{user: user, board: board, card: card} do
      colleague = user_fixture("colleague@example.com")
      {:ok, _} = Access.grant(board, colleague, "write", user)

      src = Path.join(System.tmp_dir!(), "kept-#{System.unique_integer([:positive])}.txt")
      File.write!(src, "kept")
      on_exit(fn -> File.rm(src) end)

      {:ok, a} =
        Boards.add_attachment(card, %{filename: "k.txt", content_type: "text/plain"}, src)

      {:ok, _} = Accounts.delete_user(user)

      assert File.exists?(Boards.attachment_path(a))
    end

    test "the last admin cannot be deleted", %{user: user} do
      {:ok, admin} = Accounts.promote(user)
      assert {:error, :last_admin} = Accounts.delete_user(admin)
      assert Accounts.get_user_by_email("leaver@example.com")
    end
  end
end
