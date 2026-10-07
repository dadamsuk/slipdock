defmodule Slipdock.QuotaLimitsTest do
  @moduledoc """
  The limits that are not the free tier: what counts as an item, the ceilings
  every install has, and the free trial's clock.

  The free tier's own allowance is in `Slipdock.QuotaTest`; this file is about
  the parts that apply whether or not anybody is paying for anything.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Quota, Repo, Settings}

  defp settings(attrs) do
    {:ok, _} = Settings.complete_setup(Map.merge(%{"admin_email" => "admin@example.com"}, attrs))
    :ok
  end

  defp off do
    settings(%{
      "board_limit_enabled" => false,
      "item_limit_enabled" => false,
      "storage_limit_enabled" => false
    })
  end

  defp upload(card, bytes, name \\ "file.txt") do
    path = Path.join(System.tmp_dir!(), "quota-#{System.unique_integer([:positive])}")
    File.write!(path, :binary.copy("x", bytes))

    result =
      Boards.add_attachment(
        card,
        %{filename: name, content_type: "text/plain", size: bytes},
        path
      )

    File.rm(path)
    result
  end

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Owned"}, owner: owner)
    %{owner: owner, board: board, column: hd(board.columns)}
  end

  describe "what the defaults are" do
    test "every install has the ceilings on, with the documented numbers" do
      settings(%{})

      assert Settings.board_limit() == 1_000
      assert Settings.item_limit() == 250_000
      assert Settings.storage_limit_bytes() == 10_240 * 1024 * 1024
    end

    test "the trial is off, because a self-hosted install must not expire" do
      settings(%{})
      assert Settings.trial_days() == nil
    end

    test "each one can be switched off on its own, keeping its number" do
      settings(%{"board_limit_enabled" => false})

      assert Settings.board_limit() == nil
      assert Settings.get().board_limit == 1_000
      assert Settings.item_limit() == 250_000
    end

    test "a limit switched on with no number is refused rather than saved" do
      settings(%{})

      assert {:error, changeset} = Settings.update(%{"item_limit" => nil})
      assert %{item_limit: [_ | _]} = errors_on(changeset)
    end
  end

  describe "an item is a card, a page or a file" do
    setup do: off()

    test "wiki pages count", %{owner: owner, board: board} do
      page_fixture(board, %{"title" => "Runbook"}, user: owner)

      assert Quota.used(owner, :pages) == 1
      assert Quota.used(owner) == 1
    end

    test "uploaded files count", %{owner: owner, column: column} do
      card = card_fixture(column)
      {:ok, _} = upload(card, 100)

      assert Quota.used(owner, :files) == 1
      assert Quota.used(owner, :storage) == 100
      # The card and the file.
      assert Quota.used(owner) == 2
    end

    test "a file on a wiki page counts against the board's owner too", %{
      owner: owner,
      board: board
    } do
      page = page_fixture(board, %{"title" => "With a picture"}, user: owner)
      path = Path.join(System.tmp_dir!(), "page-upload-#{System.unique_integer([:positive])}")
      File.write!(path, "12345")

      {:ok, _} =
        Boards.store_attachment(
          %{page_id: page.id},
          "pages",
          %{filename: "a.txt", content_type: "text/plain", size: 5},
          path
        )

      File.rm(path)

      assert Quota.used(owner, :files) == 1
      assert Quota.used(owner, :storage) == 5
    end

    test "archiving a page frees an item; the file behind it does not go", %{
      owner: owner,
      board: board
    } do
      page = page_fixture(board, %{"title" => "Done with"}, user: owner)
      assert Quota.used(owner) == 1

      {:ok, _} = Slipdock.Wiki.archive_page(page)
      assert Quota.used(owner) == 0
    end

    test "things on somebody else's board cost you nothing", %{owner: owner} do
      bob = user_fixture("bob@example.com")
      theirs = board_fixture(%{"name" => "Bob's"}, owner: bob)
      page_fixture(theirs, %{"title" => "Theirs"}, user: bob)

      assert Quota.used(owner) == 0
      assert Quota.used(bob) == 1
    end
  end

  describe "the item ceiling" do
    test "refuses a page as well as a card", %{owner: owner, board: board, column: column} do
      settings(%{"item_limit" => 1})

      {:ok, _} = Boards.create_card(column, %{"title" => "The only one"})

      assert {:error, changeset} =
               Slipdock.Wiki.create_page(board, %{"title" => "No room"}, user: owner)

      assert Quota.limit_kind(changeset) == :items
    end

    test "refuses an upload, and the bytes never land", %{column: column} do
      settings(%{"item_limit" => 1})
      card = card_fixture(column)

      assert {:error, changeset} = upload(card, 10)
      assert Quota.limit_kind(changeset) == :items
      assert files_on(card) == 0
    end

    test "applies to admins, unlike the free tier's allowance", %{column: _column} do
      settings(%{"item_limit" => 1, "free_card_limit" => 1})
      {:ok, admin} = Accounts.promote(user_fixture("owner@example.com"))
      board = board_fixture(%{"name" => "Admin's"}, owner: admin)

      assert Quota.limit(admin, :items) == 1
      {:ok, _} = Boards.create_card(hd(board.columns), %{"title" => "One"})
      assert {:error, _} = Boards.create_card(hd(board.columns), %{"title" => "Two"})

      # Nothing wrong with the second card; the ceiling refused it.
      refute Quota.allows?(admin)
    end

    test "applies to unlimited accounts too: they skip the free tier, not the ceilings", %{
      owner: owner,
      column: column
    } do
      settings(%{"item_limit" => 2, "free_card_limit" => 1})
      {:ok, owner} = Accounts.update_standing(owner, %{"unlimited" => true})

      assert Quota.limit(owner, :items) == 2
      assert Quota.limit(owner, :boards) == 1_000
      {:ok, _} = Boards.create_card(column, %{"title" => "One"})
      # Past the free allowance of one, so that is not what refuses...
      {:ok, _} = Boards.create_card(column, %{"title" => "Two"})
      # ...but the ceiling of two still does.
      assert {:error, changeset} = Boards.create_card(column, %{"title" => "Three"})
      assert Quota.limit_kind(changeset) == :items
    end

    test "the lower of the free allowance and the ceiling wins", %{owner: owner} do
      settings(%{"item_limit" => 100, "free_card_limit" => 5})
      assert Quota.limit(owner, :items) == 5

      {:ok, _} = Settings.update(%{"item_limit" => 3})
      assert Quota.limit(Repo.reload(owner), :items) == 3
    end
  end

  describe "the board ceiling" do
    test "refuses a board past the limit", %{owner: owner} do
      settings(%{"board_limit" => 1})

      assert Quota.used(owner, :boards) == 1

      assert {:error, changeset} =
               Boards.create_board(%{"name" => "Another"}, owner_id: owner.id)

      assert Quota.limit_kind(changeset) == :boards
    end

    test "sub-boards do not count, so subcards are not secretly capped", %{
      owner: owner,
      column: column
    } do
      settings(%{"board_limit" => 1})
      card = card_fixture(column)

      assert {:ok, _} = Boards.create_sub_board(card, template_fixture())
      assert Quota.used(owner, :boards) == 1
    end

    test "an archived board gives its place back", %{owner: owner, board: board} do
      settings(%{"board_limit" => 1})
      {:ok, _} = Boards.archive_board(board)

      assert Quota.used(owner, :boards) == 0
      assert {:ok, _} = Boards.create_board(%{"name" => "Next"}, owner_id: owner.id)
    end

    test "a board nobody owns is refused, not let through uncounted" do
      settings(%{"board_limit" => 1})
      assert {:error, changeset} = Boards.create_board(%{"name" => "Ownerless"})
      assert {"can't be blank", _} = changeset.errors[:owner_id]
    end
  end

  describe "the storage ceiling" do
    test "weighs the file being uploaded, not just the ones already there", %{column: column} do
      # 1 MB, and a file that would take it past.
      settings(%{"storage_limit_mb" => 1})
      card = card_fixture(column)

      assert {:ok, _} = upload(card, 500_000)
      assert {:error, changeset} = upload(card, 900_000)
      assert Quota.limit_kind(changeset) == :storage
      assert files_on(card) == 1
    end

    test "deleting a file gives the space back", %{column: column, owner: owner} do
      settings(%{"storage_limit_mb" => 1})
      card = card_fixture(column)
      {:ok, attachment} = upload(card, 500_000)

      assert Quota.used(owner, :storage) == 500_000
      {:ok, _} = Boards.delete_attachment(attachment)
      assert Quota.used(owner, :storage) == 0
    end
  end

  describe "the free trial" do
    test "does not apply while it is switched off", %{owner: owner} do
      settings(%{})
      assert %{applies?: false, expired?: false} = Quota.trial(owner)
    end

    test "counts from the day the account was made", %{owner: owner} do
      settings(%{"trial_days" => 30, "trial_enabled" => true})

      assert %{applies?: true, days: 30, days_left: 30, expired?: false} = Quota.trial(owner)
    end

    test "runs out, and then nothing new can be added", %{owner: owner, column: column} do
      settings(%{"trial_days" => 30, "trial_enabled" => true})
      owner = age(owner, 31)

      assert Quota.trial_expired?(owner)
      assert Quota.check(owner) == {:error, :trial_expired}

      assert {:error, changeset} = Boards.create_card(column, %{"title" => "Too late"})
      assert Quota.limit_kind(changeset) == :trial
    end

    test "stands alongside the counts rather than inside them", %{owner: owner} do
      # No card limit at all, and still out of trial: the user asked for these
      # two to be independent, and this is the test that keeps them so.
      settings(%{
        "trial_days" => 7,
        "trial_enabled" => true,
        "free_card_limit" => nil,
        "item_limit_enabled" => false
      })

      owner = age(owner, 8)

      assert Quota.limit(owner, :items) == nil
      assert Quota.check(owner) == {:error, :trial_expired}
    end

    test "a paid-up date takes somebody off the clock and off the free tier", %{
      owner: owner,
      column: column
    } do
      settings(%{"trial_days" => 30, "trial_enabled" => true, "free_card_limit" => 1})
      owner = age(owner, 31)

      {:ok, owner} =
        Accounts.update_standing(owner, %{
          "paid_until" => Date.to_iso8601(Date.add(Date.utc_today(), 30))
        })

      refute Quota.free?(owner)
      assert %{applies?: false} = Quota.trial(owner)
      assert Quota.limit(owner, :items) == 250_000
      assert {:ok, _} = Boards.create_card(column, %{"title" => "Paid for"})
    end

    test "a paid-up date in the past is a free account again", %{owner: owner} do
      settings(%{"trial_days" => 30, "trial_enabled" => true})

      {:ok, owner} =
        Accounts.update_standing(owner, %{
          "paid_until" => Date.to_iso8601(Date.add(Date.utc_today(), -1))
        })

      assert Quota.free?(owner)
      assert %{applies?: true} = Quota.trial(owner)
    end

    test "an admin is never expired", %{owner: owner} do
      settings(%{"trial_days" => 1, "trial_enabled" => true})
      {:ok, admin} = Accounts.promote(age(owner, 10))

      refute Quota.trial_expired?(admin)
      assert Quota.check(admin) == :ok
    end

    test "an unlimited account is off the clock and off the free tier, with no date", %{
      owner: owner,
      column: column
    } do
      settings(%{"trial_days" => 30, "trial_enabled" => true, "free_card_limit" => 1})
      owner = age(owner, 31)
      assert Quota.check(owner) == {:error, :trial_expired}

      {:ok, owner} = Accounts.update_standing(owner, %{"unlimited" => true})

      assert owner.paid_until == nil
      refute Quota.free?(owner)
      assert %{applies?: false} = Quota.trial(owner)
      refute Quota.trial_warning?(owner)
      assert Quota.limit(owner, :items) == 250_000
      assert {:ok, _} = Boards.create_card(column, %{"title" => "One"})
      assert {:ok, _} = Boards.create_card(column, %{"title" => "Two"})
    end

    test "taking unlimited away puts somebody back on the free tier", %{owner: owner} do
      settings(%{"trial_days" => 30, "trial_enabled" => true, "free_card_limit" => 1})
      owner = age(owner, 31)
      {:ok, owner} = Accounts.update_standing(owner, %{"unlimited" => true})
      {:ok, owner} = Accounts.update_standing(owner, %{"unlimited" => false})

      assert Quota.free?(owner)
      assert Quota.check(owner) == {:error, :trial_expired}
    end

    test "warns before the end, not only after it", %{owner: owner} do
      settings(%{"trial_days" => 30, "trial_enabled" => true})

      refute Quota.trial_warning?(owner)
      assert Quota.trial_warning?(age(owner, 25))
    end
  end

  describe "what people are told" do
    test "nothing, with no limit and no trial", %{owner: owner} do
      off()
      assert Quota.message(owner, :items) == nil
      assert Quota.message(owner, :trial) == nil
    end

    test "how many items are left, and that they are full", %{owner: owner, column: column} do
      settings(%{"item_limit" => 2})
      assert Quota.message(owner) == "2 items left of 2."

      card_fixture(column)
      assert Quota.message(owner) == "1 item left of 2."

      card_fixture(column)
      assert Quota.message(owner) =~ "You have used all 2 cards, pages and files"
    end

    test "that the boards are all used", %{owner: owner} do
      settings(%{"board_limit" => 1})
      assert Quota.message(owner, :boards) =~ "You own all 1 boards"
    end

    test "storage in bytes a person can read", %{owner: owner, column: column} do
      settings(%{"storage_limit_mb" => 1})
      {:ok, _} = upload(card_fixture(column), 512 * 1024)

      assert Quota.message(owner, :storage) == "512 KB left of 1 MB."
    end

    test "the trial's days, and its end", %{owner: owner} do
      settings(%{"trial_days" => 30, "trial_enabled" => true})
      assert Quota.message(owner, :trial) == "30 days left of your free trial."
      assert Quota.message(age(owner, 29), :trial) == "1 day left of your free trial."
      assert Quota.message(age(owner, 31), :trial) =~ "Your 30-day free trial has ended."
    end

    test "which limits are near enough to warn about", %{owner: owner, column: column} do
      settings(%{"item_limit" => 5, "board_limit" => 100})
      assert Quota.warnings(owner) == []

      for _ <- 1..4, do: card_fixture(column)
      assert Quota.warnings(owner) == [:items]
    end
  end

  describe "the report" do
    test "carries every dimension, the breakdown and the trial", %{
      owner: owner,
      board: board,
      column: column
    } do
      settings(%{"trial_days" => 30, "trial_enabled" => true})
      card = card_fixture(column)
      page_fixture(board, %{"title" => "Notes"}, user: owner)
      {:ok, _} = upload(card, 42)

      report = Quota.report(owner)

      assert report.breakdown == %{cards: 1, pages: 1, files: 1}
      assert report.items.used == 3
      assert report.boards.used == 1
      assert report.storage.used == 42
      assert report.items.limit == 250_000
      assert report.trial.applies?
      assert report.free
    end
  end

  # Moves an account's birthday backwards, which is the only way to test a
  # clock without waiting for one.
  defp age(user, days) do
    moved = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)

    user
    |> Ecto.Changeset.change(inserted_at: DateTime.truncate(moved, :second))
    |> Repo.update!()
  end

  defp files_on(card) do
    Repo.aggregate(
      Ecto.Query.from(a in Slipdock.Boards.Attachment, where: a.card_id == ^card.id),
      :count
    )
  end

  defp template_fixture do
    {:ok, template} =
      Boards.create_template(%{
        "name" => "Simple #{System.unique_integer([:positive])}",
        "columns" => [%{"name" => "To Do"}, %{"name" => "Done"}]
      })

    template
  end
end
