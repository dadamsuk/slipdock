defmodule Slipdock.WikiContentsTest do
  @moduledoc """
  A page holding the card's *contents*: comments, status updates, a
  checklist, web links, votes and custom field values.

  The property these tests hold is that there is **one** of each — one
  comments table, one way to write a comment, one set of readers — and a row
  belongs to exactly one of a card or a page. Two parallel implementations
  would drift, and the database would not stop them.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields, Repo, Votes, Wiki}
  alias Slipdock.Boards.{Card, Owned}
  alias Slipdock.Wiki.Page

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Written", "code" => "written"}, owner: user)
    [todo | _] = board.columns
    {:ok, page} = Wiki.create_page(board, %{"title" => "The spec"}, user: user)

    %{user: user, board: board, todo: todo, page: page}
  end

  defp fresh(%Page{id: id}), do: Repo.preload(Wiki.get_page!(id), Wiki.board_preloads())

  describe "one table, two owners" do
    test "a comment belongs to a page or a card, and never to both or neither", %{
      page: page,
      todo: todo
    } do
      card = card_fixture(todo, %{"title" => "The work"})

      {:ok, on_page} = Boards.add_comment(page, "reads well")
      {:ok, on_card} = Boards.add_comment(card, "shipped")

      assert on_page.page_id == page.id
      assert is_nil(on_page.card_id)
      assert on_card.card_id == card.id
      assert is_nil(on_card.page_id)

      assert Owned.owner_ref(on_page) == {:page, page.id}
      assert Owned.owner_ref(on_card) == {:card, card.id}

      # Neither.
      assert {:error, changeset} =
               %Slipdock.Boards.Comment{}
               |> Slipdock.Boards.Comment.changeset(%{"body" => "orphan"})
               |> Repo.insert()

      assert "must belong to a card or a page" in errors_on(changeset).card_id

      # Both.
      assert {:error, changeset} =
               %Slipdock.Boards.Comment{card_id: card.id, page_id: page.id}
               |> Slipdock.Boards.Comment.changeset(%{"body" => "greedy"})
               |> Repo.insert()

      assert "cannot belong to both a card and a page" in errors_on(changeset).card_id
    end

    test "the database refuses what the changeset would have caught", %{page: page, todo: todo} do
      card = card_fixture(todo, %{"title" => "The work"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert_raise Exqlite.Error, fn ->
        Repo.insert_all("comments", [
          [card_id: card.id, page_id: page.id, body: "both", inserted_at: now, updated_at: now]
        ])
      end
    end
  end

  describe "comments" do
    test "a page takes them, and a [[link]] in one is a backlink", %{
      page: page,
      board: board,
      user: user
    } do
      {:ok, other} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)
      {:ok, _} = Boards.add_comment(page, "see [[Retry policy]] for the detail")

      assert [%{body: body}] = fresh(page).comments
      assert body =~ "Retry policy"

      # The remark is writing too: it shows in the other page's backlinks,
      # naming the page it was written on.
      backlinks = Wiki.backlinks(other, user)
      assert Enum.any?(backlinks, &(&1.page.id == page.id))
    end

    test "deleting one leaves the page alone", %{page: page} do
      {:ok, comment} = Boards.add_comment(page, "passing thought")
      {:ok, _} = Boards.delete_comment(comment.id)

      assert fresh(page).comments == []
      assert %Page{} = Wiki.get_page!(page.id)
    end
  end

  describe "status updates" do
    test "a page can be off track, and says so the way a card does", %{page: page, user: user} do
      {:ok, _} =
        Boards.add_status_update(page, user, %{"health" => "at_risk", "body" => "stalled"})

      page = fresh(page)
      assert [%{health: "at_risk", body: "stalled"}] = page.status_updates
      assert Card.stated_health(page) == "at_risk"

      {:ok, _} = Boards.add_status_update(page, user, %{"health" => "on_track"})
      assert Card.stated_health(fresh(page)) == "on_track"
    end

    test "the latest is found per page as it is per card", %{page: page, user: user} do
      {:ok, _} = Boards.add_status_update(page, user, %{"health" => "off_track"})
      assert Boards.latest_stated_health_for_pages([page.id]) == %{page.id => "off_track"}
    end
  end

  describe "a checklist" do
    test "items go on in order, tick, and come off", %{page: page} do
      {:ok, first} = Boards.add_checklist_item(page, "outline")
      {:ok, second} = Boards.add_checklist_item(page, "review")

      assert first.position == 0
      assert second.position == 1
      assert Enum.map(fresh(page).checklist_items, & &1.text) == ["outline", "review"]

      {:ok, _} = Boards.toggle_checklist_item(first.id)
      assert SlipdockWeb.ItemComponents.progress(fresh(page).checklist_items) == {1, 2, 50}

      {:ok, _} = Boards.delete_checklist_item(second.id)
      assert length(fresh(page).checklist_items) == 1
    end

    test "a page's positions are its own, not the board's", %{page: page, todo: todo} do
      card = card_fixture(todo, %{"title" => "The work"})
      {:ok, _} = Boards.add_checklist_item(card, "a card's first")
      {:ok, on_page} = Boards.add_checklist_item(page, "a page's first")

      assert on_page.position == 0
    end
  end

  describe "web links" do
    test "a page links out, and the link is only its own to remove", %{page: page, todo: todo} do
      card = card_fixture(todo, %{"title" => "The work"})
      {:ok, url} = Boards.add_card_url(page, %{"url" => "example.com/spec"})

      assert url.url == "https://example.com/spec"
      assert [^url] = fresh(page).urls
      assert Boards.get_card_url!(url.id).page_id == page.id
      assert Repo.preload(card, :urls).urls == []

      {:ok, _} = Boards.delete_card_url(url)
      assert fresh(page).urls == []
    end
  end

  describe "votes" do
    test "a page competes with the cards for one budget", %{
      page: page,
      board: board,
      todo: todo,
      user: user
    } do
      {:ok, _} = Boards.update_board(board, %{"vote_budget" => 5, "vote_max" => 5})
      card = card_fixture(todo, %{"title" => "The work"})

      {:ok, _} = Votes.set(page, user, 2)
      {:ok, _} = Votes.set(card, user, 2)

      assert Votes.spent(user, board.id) == 4
      assert Card.vote_total(fresh(page)) == 2

      # One left, and the budget is the tree's, not the page's.
      assert {:error, message} = Votes.set(page, user, 4)
      assert message =~ "left on this board"

      {:ok, _} = Votes.set(page, user, 0)
      assert Card.vote_total(fresh(page)) == 0
      assert Votes.spent(user, board.id) == 2
    end
  end

  describe "custom fields" do
    test "a page holds the board's fields, separately from a card's", %{
      page: page,
      board: board,
      todo: todo
    } do
      {:ok, field} = Fields.create_field(board, %{"name" => "Effort", "kind" => "number"})
      card = card_fixture(todo, %{"title" => "The work"})

      {:ok, _} = Fields.set_value(page, field, "3")
      {:ok, _} = Fields.set_value(card, field, "8")

      assert Fields.value(Repo.preload(fresh(page), field_values: :field), field) == 3.0
      assert Fields.value(Boards.get_card!(card.id), field) == 8.0

      {:ok, _} = Fields.set_value(page, field, "")
      assert Fields.value(Repo.preload(fresh(page), field_values: :field), field) == nil
    end
  end

  describe "what a page still has not got" do
    test "the card-to-card joins and the subcard board stay card-only", %{page: page} do
      page = fresh(page)

      assert page.blocked_by == []
      assert page.blocks == []
      assert page.links_out == []
      assert page.links_in == []
      assert is_nil(page.sub_board)
      refute Card.blocked?(page)
    end
  end

  describe "deleting the page" do
    test "takes what was written about it with it", %{page: page, user: user} do
      {:ok, _} = Boards.add_comment(page, "a remark")
      {:ok, _} = Boards.add_checklist_item(page, "an item")
      {:ok, _} = Boards.add_status_update(page, user, %{"health" => "on_track"})
      {:ok, _} = Boards.add_card_url(page, %{"url" => "https://example.com"})

      {:ok, _} = Wiki.delete_page(page)

      assert Repo.aggregate(from(c in "comments", where: c.page_id == ^page.id), :count) == 0

      assert Repo.aggregate(from(c in "checklist_items", where: c.page_id == ^page.id), :count) ==
               0

      assert Repo.aggregate(from(c in "status_updates", where: c.page_id == ^page.id), :count) ==
               0

      assert Repo.aggregate(from(c in "card_urls", where: c.page_id == ^page.id), :count) == 0
    end
  end
end
