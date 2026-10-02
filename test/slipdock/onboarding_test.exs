defmodule Slipdock.OnboardingTest do
  @moduledoc """
  The “Getting Started” board is the first thing a new account sees, so it has
  to keep building — and, because the tour is written in the app's own
  features, its pages have to keep rendering. A `[[link]]` to a page somebody
  renamed, or a query block with a typo in it, is a broken welcome.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Onboarding, Wiki}
  alias Slipdock.Automations.Rule
  alias Slipdock.Boards.Board
  alias Slipdock.Search.Indexer
  alias SlipdockWeb.Wiki.Renderer

  # Building a board queues every card for embedding, and that queue is global:
  # left full, it drains into whichever search test runs next.
  setup do
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()

    # Off in config/test.exs so it does not fire in every sign-in test. These
    # are the tests that are about it.
    previous = Application.get_env(:slipdock, :welcome_board)
    Application.put_env(:slipdock, :welcome_board, true)

    on_exit(fn ->
      Application.put_env(:slipdock, :welcome_board, previous)
      drain(20)
    end)
  end

  defp drain(0), do: :ok

  defp drain(tries) do
    if Indexer.pending() > 0 do
      Indexer.flush()
      drain(tries - 1)
    end
  end

  defp fresh(email \\ "newcomer@example.com") do
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    user
  end

  test "builds a board with a tour on it" do
    board = Onboarding.build!(fresh())

    assert board.name == "Getting Started"
    assert ["Backlog", "To Do", "In Progress", "Done"] == Enum.map(board.columns, & &1.name)

    cards = Boards.list_cards(board)
    written = Enum.map_join(cards, "\n", &"#{&1.title}\n#{&1.description}") |> String.downcase()

    # Every list has something in it: a Done list with nothing in it is the one
    # part of a new board that reads as broken.
    for column <- board.columns, do: refute(column.cards == [], "#{column.name} is empty")

    # The tour covers the features it claims to.
    for subject <- ["wiki", "subcard", "automation", "assistant", "agent", "cli", "share"] do
      assert written =~ subject, "nothing in the tour is about #{subject}"
    end

    # Tags, a checklist, a comment and a completed card, because the cards
    # explaining those things are made of them.
    assert length(Boards.list_tags(board.id)) == 4
    assert Enum.any?(cards, & &1.completed)

    moving = Enum.find(cards, &(&1.title == "Move this card to Done"))
    moving = Boards.get_card!(moving.id)
    assert length(moving.checklist_items) == 3
    assert Enum.any?(moving.checklist_items, & &1.done)
    assert [_comment] = moving.comments
  end

  test "the epic has a board of its own, with a real dependency on it" do
    board = Onboarding.build!(fresh())

    epic =
      board
      |> Boards.list_cards()
      |> Enum.find(&(&1.title =~ "Break a big job"))

    sub = Repo.get_by!(Board, parent_card_id: epic.id)
    subcards = Boards.list_cards(sub)
    assert length(subcards) == 4

    blocked =
      subcards
      |> Enum.find(&(&1.title =~ "cannot start"))
      |> then(&Boards.get_card!(&1.id))

    assert [blocker] = blocked.blocked_by
    assert blocker.title =~ "next piece"
  end

  test "the wiki pages are written, nested, pinned, and render cleanly" do
    user = fresh()
    board = Onboarding.build!(user)

    pages = Wiki.list_pages(board)
    assert length(pages) == 3

    welcome = Enum.find(pages, &(&1.title == "Welcome to your wiki"))
    assert Enum.count(pages, &(&1.parent_id == welcome.id)) == 2

    # Pinned to the card that sends you to it.
    wiki_card = board |> Boards.list_cards() |> Enum.find(&(&1.title =~ "wiki"))
    docs = Wiki.pages_for_card(wiki_card, user)
    assert Enum.any?(docs, &(&1.pinned and &1.page.id == welcome.id))

    for page <- pages do
      html = Renderer.to_html(page.body, page: page, board: board, as: user)

      refute html =~ "wiki-query-error",
             "a query block on “#{page.title}” did not parse: #{html}"

      refute html =~ "wiki-wanted",
             "a link on “#{page.title}” points at a page nobody wrote"
    end
  end

  test "the automation is real, harmless, and fires on Done" do
    user = fresh()
    board = Onboarding.build!(user)

    assert [rule] = Slipdock.Automations.list_rules(board.id)
    assert rule.spec["trigger"]["type"] == "card_moved"
    assert [%{"type" => "comment"}] = rule.spec["actions"]

    # Nothing in the tour emails anybody or waits on a clock.
    refute Enum.any?(rule.spec["actions"], &(&1["type"] in ["email", "notify_assignee"]))
    assert Repo.aggregate(Rule, :count) == 1
  end

  describe "when it is built" do
    test "a first sign-in gets one; a second does not" do
      user = fresh()
      assert Onboarding.wanted?(user)
      assert {:ok, _board} = Onboarding.ensure_for(user)

      # Signing in is what marks the account as having been here.
      :ok = Accounts.touch_last_signed_in(user)
      refute Onboarding.wanted?(Accounts.get_user!(user.id))
      assert :skipped = Onboarding.ensure_for(Accounts.get_user!(user.id))
    end

    test "somebody who already owns a board is left alone" do
      user = fresh()
      board_fixture(%{}, owner: user)

      refute Onboarding.wanted?(user)
      assert :skipped = Onboarding.ensure_for(user)
    end

    test "SLIPDOCK_WELCOME_BOARD=0 turns the automatic half off" do
      Application.put_env(:slipdock, :welcome_board, false)

      user = fresh()
      refute Onboarding.enabled?()
      assert :skipped = Onboarding.ensure_for(user)

      # The manual half still works.
      assert %Board{} = Onboarding.build!(user)
    end

    test "the release shim builds one, and refuses a second without --force" do
      user = fresh()

      assert ExUnit.CaptureIO.capture_io(fn -> Slipdock.Release.welcome([user.email]) end) =~
               "Built “Getting Started”"

      assert ExUnit.CaptureIO.capture_io(fn -> Slipdock.Release.welcome([user.email]) end) =~
               "already has"

      assert ExUnit.CaptureIO.capture_io(fn ->
               Slipdock.Release.welcome([user.email, "--force"])
             end) =~ "Built “Getting Started”"

      assert ExUnit.CaptureIO.capture_io(fn ->
               Slipdock.Release.welcome(["nobody@example.com"])
             end) =~
               "No user"
    end

    test "exists_for? sees the board, archived or not" do
      user = fresh()
      refute Onboarding.exists_for?(user)

      board = Onboarding.build!(user)
      assert Onboarding.exists_for?(user)

      {:ok, _} = Boards.archive_board(board)
      assert Onboarding.exists_for?(user)
    end
  end
end
