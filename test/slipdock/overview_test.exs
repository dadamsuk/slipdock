defmodule Slipdock.OverviewTest do
  @moduledoc """
  The admin overview's counting: what each person owns, when they were last
  seen, the totals across everybody, and the orders the list comes in.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Overview, Repo}
  alias Slipdock.Accounts.{User, UserToken}

  @now ~U[2030-06-15 12:00:00Z]

  defp days_ago(n), do: DateTime.add(@now, -n * 86_400, :second)

  defp set_user(user, fields) do
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: fields)
  end

  defp use_token(user, at) do
    {_token, record} = Accounts.create_api_token(user, "test", scope: "write")
    Repo.update_all(from(t in UserToken, where: t.id == ^record.id), set: [last_used_at: at])
  end

  defp upload(card, bytes) do
    path = Path.join(System.tmp_dir!(), "overview-#{System.unique_integer([:positive])}")
    File.write!(path, :binary.copy("x", bytes))

    {:ok, _} =
      Boards.add_attachment(
        card,
        %{filename: "f.txt", content_type: "text/plain", size: bytes},
        path
      )

    File.rm(path)
  end

  defp person(overview, user), do: Enum.find(overview.people, &(&1.user.id == user.id))

  setup do
    alice = user_fixture("alice@example.com")
    bob = user_fixture("bob@example.com")
    %{alice: alice, bob: bob}
  end

  describe "what each person owns" do
    test "counts boards, lists, cards, pages, files and storage by owner", %{
      alice: alice,
      bob: bob
    } do
      board = board_fixture(%{}, owner: alice)
      [column | _] = board.columns
      card = card_fixture(column)
      card_fixture(column)
      page_fixture(board, %{}, user: alice)
      upload(card, 300)

      # Bob working on Alice's board makes Alice's things, not Bob's.
      share_fixture(board, [bob])
      card_fixture(column)

      overview = Overview.overview(now: @now)
      a = person(overview, alice)

      assert a.boards == 1
      assert a.lists == length(board.columns)
      assert a.cards == 3
      assert a.pages == 1
      assert a.files == 1
      assert a.storage == 300

      assert %{boards: 0, lists: 0, cards: 0, pages: 0, files: 0, storage: 0} =
               person(overview, bob)
    end

    test "a sub-board's lists and cards are its root owner's", %{alice: alice} do
      board = board_fixture(%{}, owner: alice)
      [column | _] = board.columns
      epic = card_fixture(column)
      {:ok, template} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, template)
      sub = Boards.get_board!(sub.id)
      card_fixture(hd(sub.columns))

      a = person(Overview.overview(), alice)

      # One board: a sub-board is not a board against the limit.
      assert a.boards == 1
      assert a.lists == length(board.columns) + length(sub.columns)
      assert a.cards == 2
    end

    test "archived cards are not counted, as the quota does not count them", %{alice: alice} do
      board = board_fixture(%{}, owner: alice)
      card = card_fixture(hd(board.columns))
      card_fixture(hd(board.columns))
      {:ok, _} = Boards.archive_card(card)

      assert person(Overview.overview(), alice).cards == 1
    end

    test "somebody with nothing has zeros, not a missing row", %{bob: bob} do
      assert %{boards: 0, lists: 0, cards: 0, pages: 0, files: 0, storage: 0} =
               person(Overview.overview(), bob)
    end
  end

  describe "when they arrived and were last seen" do
    test "signed up is when the account was made", %{alice: alice} do
      set_user(alice, inserted_at: days_ago(40))
      assert person(Overview.overview(), alice).signed_up_at == days_ago(40)
    end

    test "never seen is nil everywhere", %{bob: bob} do
      assert %{last_signed_in_at: nil, last_api_at: nil, last_active_at: nil} =
               person(Overview.overview(), bob)
    end

    test "an account worked only by an agent is active by its token", %{alice: alice} do
      use_token(alice, days_ago(2))
      p = person(Overview.overview(), alice)

      assert p.last_signed_in_at == nil
      assert p.last_api_at == days_ago(2)
      assert p.last_active_at == days_ago(2)
    end

    test "last active is the later of signing in and the API", %{alice: alice, bob: bob} do
      set_user(alice, last_signed_in_at: days_ago(1))
      use_token(alice, days_ago(5))
      set_user(bob, last_signed_in_at: days_ago(9))
      use_token(bob, days_ago(3))
      # Of several tokens, the last one used.
      use_token(bob, days_ago(20))

      overview = Overview.overview()
      assert person(overview, alice).last_active_at == days_ago(1)
      assert person(overview, bob).last_active_at == days_ago(3)
      assert person(overview, bob).last_api_at == days_ago(3)
    end
  end

  describe "totals" do
    test "add up the counts and sort accounts by kind and recency", %{alice: alice, bob: bob} do
      {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
      {:ok, _} = Accounts.disable(bob)

      set_user(alice, inserted_at: days_ago(3), last_signed_in_at: days_ago(1))
      set_user(bob, inserted_at: days_ago(20), last_signed_in_at: days_ago(25))
      set_user(admin, inserted_at: days_ago(100))
      use_token(admin, days_ago(10))

      board = board_fixture(%{}, owner: alice)
      card_fixture(hd(board.columns))
      board_fixture(%{}, owner: admin)

      %{totals: t} = Overview.overview(now: @now)

      assert t.users == 3
      assert t.admins == 1
      assert t.disabled == 1
      assert t.never_seen == 0
      assert t.joined_7d == 1
      assert t.joined_30d == 2
      assert t.active_7d == 1
      assert t.active_30d == 3
      assert t.boards == 2
      assert t.cards == 1
      assert t.lists == length(board.columns) * 2
    end

    test "of nobody is all zeros" do
      t = Overview.totals([], @now)
      assert t.users == 0 and t.storage == 0 and t.active_30d == 0
    end
  end

  describe "sorting" do
    setup %{alice: alice, bob: bob} do
      carol = user_fixture("carol@example.com")
      board = board_fixture(%{}, owner: bob)
      card_fixture(hd(board.columns))
      set_user(alice, inserted_at: days_ago(1), last_signed_in_at: days_ago(1))
      set_user(bob, inserted_at: days_ago(5), last_signed_in_at: days_ago(3))
      set_user(carol, inserted_at: days_ago(9))
      %{carol: carol}
    end

    # Fixture addresses get a domain of their own per test; the name is enough.
    defp emails(opts),
      do: Overview.people(opts) |> Enum.map(&(&1.user.email |> String.split("@") |> hd()))

    test "storage by default, then most first with ties by email" do
      assert emails([]) == emails(sort: :storage)
      assert emails(sort: :cards) == ~w(bob alice carol)
    end

    test "dates latest first, the never-seen last" do
      assert emails(sort: :last_active) ==
               ~w(alice bob carol)

      assert emails(sort: "signed_up") == ~w(alice bob carol)
    end

    test "email A to Z, and an unknown order is the default" do
      assert emails(sort: "email") == ~w(alice bob carol)
      assert emails(sort: "nonsense") == emails(sort: :storage)
      assert emails(sort: :nonsense) == emails(sort: :storage)
    end
  end
end
