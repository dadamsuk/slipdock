defmodule SlipdockWeb.QuotaBypassTest do
  @moduledoc """
  The ways round `Slipdock.Quota` that are not creating something: bringing an
  archived thing back, carrying a card into somebody else's tree, importing
  archived rows, and building the welcome tour. Each is refused at the limit
  with the same 402 and the same name as creating would be.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Onboarding, Portable, Quota, Repo, Settings, Wiki}
  alias Slipdock.Boards.Board

  defp settings(attrs) do
    {:ok, _} = Settings.complete_setup(Map.merge(%{"admin_email" => "admin@example.com"}, attrs))
    :ok
  end

  defp age(user, days) do
    moved = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)

    user
    |> Ecto.Changeset.change(inserted_at: DateTime.truncate(moved, :second))
    |> Repo.update!()
  end

  defp refused(conn, code) do
    body = json_response(conn, 402)
    assert body["error"] == code
    assert body["retryable"] == false
    body
  end

  setup %{user: user} do
    board = board_fixture(%{"name" => "Mine"}, owner: user)
    %{board: board, column: hd(board.columns)}
  end

  describe "restoring an archived card" do
    test "is refused when its return would go past the limit", %{
      conn: conn,
      user: user,
      column: column
    } do
      settings(%{"free_card_limit" => 1})
      card = card_fixture(column, %{"title" => "Old"})
      {:ok, card} = Boards.archive_card(card)
      _new = card_fixture(column, %{"title" => "New"})

      assert {:error, changeset} = Boards.unarchive_card(card)
      assert Quota.limit_kind(changeset) == :items

      refused(post(conn, ~p"/api/cards/#{card.id}/restore"), "card_limit_reached")
      assert Repo.reload(card).archived_at
      assert Quota.used(user) == 1
    end

    test "is refused once the trial has run out", %{conn: conn, user: user, column: column} do
      settings(%{"trial_days" => 30, "trial_enabled" => true})
      card = card_fixture(column, %{"title" => "Old"})
      {:ok, card} = Boards.archive_card(card)
      age(user, 31)

      refused(post(conn, ~p"/api/cards/#{card.id}/restore"), "trial_expired")
    end

    test "goes through with room to spare", %{conn: conn, column: column} do
      settings(%{"free_card_limit" => 2})
      card = card_fixture(column, %{"title" => "Old"})
      {:ok, card} = Boards.archive_card(card)

      assert json_response(post(conn, ~p"/api/cards/#{card.id}/restore"), 200)
      refute Repo.reload(card).archived_at
    end
  end

  describe "restoring an archived board" do
    test "is refused at the board limit", %{conn: conn, user: user, board: board} do
      {:ok, _} = Boards.archive_board(board)
      _other = board_fixture(%{"name" => "Replacement"}, owner: user)
      settings(%{"board_limit" => 1})

      refused(post(conn, ~p"/api/boards/#{board.id}/restore"), "board_limit_reached")
      assert Board.archived?(Repo.reload(board))
    end
  end

  describe "restoring an archived page" do
    test "counts the page and every archived child coming back with it", %{
      conn: conn,
      user: user,
      board: board
    } do
      {:ok, parent} = Wiki.create_page(board, %{"title" => "Parent"}, user: user)

      {:ok, _child} =
        Wiki.create_page(board, %{"title" => "Child", "parent_id" => parent.id}, user: user)

      {:ok, _} = Wiki.archive_page(parent)
      # Room for one more, and the restore wants two.
      settings(%{"free_card_limit" => 1})

      refused(post(conn, ~p"/api/pages/#{parent.id}/restore"), "card_limit_reached")
      assert Repo.reload(parent).archived_at

      {:ok, _} = Settings.update(%{"free_card_limit" => 2})
      assert {:ok, _} = Wiki.unarchive_page(Repo.reload(parent))
    end
  end

  describe "moving a card into somebody else's tree" do
    setup %{user: user, column: column} do
      settings(%{"free_card_limit" => 3})

      other = user_fixture("other@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: other)
      share_fixture(theirs, user)

      # Theirs: two of three used. Mine: an epic with two subcards.
      [their_column | _] = theirs.columns
      card_fixture(their_column, %{"title" => "One"})
      card_fixture(their_column, %{"title" => "Two"})

      epic = card_fixture(column, %{"title" => "Epic"})
      {:ok, template} = Boards.find_template("Simple")
      {:ok, sub} = Boards.create_sub_board(epic, template)
      [sub_column | _] = Boards.get_board!(sub.id).columns
      card_fixture(sub_column, %{"title" => "Sub one"})
      card_fixture(sub_column, %{"title" => "Sub two"})

      %{
        other: other,
        theirs: theirs,
        their_column: their_column,
        epic: epic,
        sub: sub,
        user: user
      }
    end

    test "counts the whole subtree against the destination's owner", %{
      conn: conn,
      other: other,
      theirs: theirs,
      their_column: their_column,
      epic: epic
    } do
      assert {:error, changeset} = Boards.move_card_to_board(epic, their_column)
      assert Quota.limit_kind(changeset) == :items

      conn =
        post(conn, ~p"/api/cards/#{epic.id}/move", %{
          "board" => theirs.id,
          "column" => their_column.name
        })

      refused(conn, "card_limit_reached")
      assert Repo.reload(epic).board_id != theirs.id
      assert Quota.used(other) == 2
    end

    test "a free account cannot farm cards on a paid board and carry them home", %{
      user: user,
      other: other,
      column: column,
      their_column: their_column
    } do
      # Mine is full at three (the epic and its two subcards); theirs is paid.
      other
      |> Ecto.Changeset.change(paid_until: DateTime.add(DateTime.utc_now(:second), 86_400))
      |> Repo.update!()

      assert Quota.check(user) == {:error, :card_limit_reached}
      {:ok, farmed} = Boards.create_card(their_column, %{"title" => "Made over there"})

      assert {:error, changeset} = Boards.move_card_to_board(farmed, column)
      assert Quota.limit_kind(changeset) == :items
    end

    test "with room, it moves, and its sub-boards change owner with it", %{
      other: other,
      their_column: their_column,
      epic: epic,
      sub: sub
    } do
      {:ok, _} = Settings.update(%{"free_card_limit" => 10})

      assert {:ok, _} = Boards.move_card_to_board(epic, their_column)
      sub = Repo.reload(sub)
      assert sub.root_id == their_column.board_id
      assert sub.owner_id == other.id
      assert Quota.used(other) == 5
    end

    test "inside one owner's boards nothing is checked", %{user: user, epic: epic} do
      second = board_fixture(%{"name" => "Also mine"}, owner: user)
      assert Quota.check(user) == {:error, :card_limit_reached}

      assert {:ok, _} = Boards.move_card_to_board(epic, hd(second.columns))
    end
  end

  describe "importing" do
    test "archived cards in the document count", %{user: user, column: column} do
      settings(%{"free_card_limit" => 10})
      card_fixture(column, %{"title" => "Kept"})
      gone = card_fixture(column, %{"title" => "Archived"})
      {:ok, _} = Boards.archive_card(gone)

      document = user |> Portable.export(archived_cards: true) |> Jason.encode!()
      receiver = user_fixture("receiver@example.com")
      {:ok, _} = Settings.update(%{"free_card_limit" => 1})

      assert {:error, {:card_limit_reached, 2, 1}} = Portable.import(receiver, document)
    end

    test "the API refuses a document that will not fit with a 402", %{user: user, column: column} do
      settings(%{"free_card_limit" => 10})
      card_fixture(column, %{"title" => "One"})
      card_fixture(column, %{"title" => "Two"})
      document = user |> Portable.export() |> Jason.encode!() |> Jason.decode!()

      receiver = user_fixture("receiver@example.com")
      {:ok, _} = Settings.update(%{"free_card_limit" => 1})

      body = refused(post(conn_as(receiver), ~p"/api/import", document), "card_limit_reached")
      assert body["message"] =~ "Nothing was imported"
    end
  end

  describe "the welcome tour" do
    test "its size is what building one actually adds" do
      settings(%{})
      fresh = user_fixture("fresh@example.com")
      assert {:ok, _} = Onboarding.build(fresh)
      assert Quota.used(fresh) == Onboarding.tour_size()
    end

    test "at the board limit, the API says so rather than crashing", %{conn: conn} do
      settings(%{"board_limit" => 1})

      refused(post(conn, ~p"/api/boards/welcome", %{"force" => true}), "board_limit_reached")
    end

    test "too small an allowance builds none of it", %{conn: conn, user: user} do
      settings(%{"free_card_limit" => Onboarding.tour_size() - 1})

      body = refused(post(conn, ~p"/api/boards/welcome"), "card_limit_reached")
      assert body["message"] =~ "#{Onboarding.tour_size()} cards and pages"
      refute Onboarding.exists_for?(user)
      assert Quota.used(user) == 0
    end
  end
end
