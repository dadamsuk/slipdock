defmodule Slipdock.Fixtures do
  @moduledoc "Helpers for building boards, cards and tags in tests."

  alias Slipdock.{Accounts, Boards}

  @default_email "tester@example.com"

  @doc "The default test user (the one ConnCase signs in), created on first use."
  def user_fixture(email \\ @default_email) do
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    user
  end

  @doc "Creates a board owned by `opts[:owner]` (default: the default test user)."
  def board_fixture(attrs \\ %{}, opts \\ []) do
    owner = opts[:owner] || user_fixture()

    {:ok, board} =
      Boards.create_board(
        Map.merge(
          %{"name" => "Board #{System.unique_integer([:positive])}"},
          attrs
        ),
        template: opts[:template],
        owner_id: owner.id
      )

    Boards.get_board!(board.id)
  end

  def tag_fixture(board, name, color \\ "sky") do
    {:ok, tag} = Boards.create_tag(board, %{"name" => name, "color" => color})
    tag
  end

  def card_fixture(column, attrs \\ %{}) do
    {:ok, card} =
      Boards.create_card(
        column,
        Map.merge(%{"title" => "Card #{System.unique_integer([:positive])}"}, attrs)
      )

    card
  end

  @doc """
  An automation rule on `board`, straight from a spec (no model involved).
  `spec` is `%{"trigger" => …, "conditions" => …, "actions" => …}`.
  """
  def rule_fixture(board, spec, attrs \\ %{}) do
    {:ok, rule} =
      Slipdock.Automations.create_rule(
        Map.merge(
          %{
            "name" => "Rule #{System.unique_integer([:positive])}",
            "spec" => spec,
            "board_id" => board.id
          },
          attrs
        )
      )

    rule
  end

  @doc "A wiki page on `board`, written by `opts[:user]` (default: the test user)."
  def page_fixture(board, attrs \\ %{}, opts \\ []) do
    user = opts[:user] || user_fixture()

    {:ok, page} =
      Slipdock.Wiki.create_page(
        board,
        Map.merge(%{"title" => "Page #{System.unique_integer([:positive])}"}, attrs),
        Keyword.merge([user: user, via: "web"], Keyword.delete(opts, :user))
      )

    page
  end

  def reload(board), do: Boards.get_board!(board.id)

  @doc """
  A three-level tree for rollup tests, as of 15 Jan 2030:

      Root: Epic (due 15 Jan) ─┬─ B (done, due 10 Jan)
                               └─ C (5 → 20 Jan) ─┬─ D (done)
                                                  └─ E (due 1 Feb)
            Late (due 1 Jan, open), Stuck (blocked by Late), Loose
  """
  def tree_fixture do
    board = board_fixture(%{"name" => "Root"})
    [backlog | _] = board.columns
    {:ok, t} = Boards.find_template("Simple")

    epic = card_fixture(backlog, %{"title" => "Epic", "due_date" => "2030-01-15"})
    {:ok, sub} = Boards.create_sub_board(epic, t)
    sub = Boards.get_board!(sub.id)

    b =
      card_fixture(hd(sub.columns), %{
        "title" => "B",
        "completed" => true,
        "due_date" => "2030-01-10"
      })

    c =
      card_fixture(hd(sub.columns), %{
        "title" => "C",
        "start_date" => "2030-01-05",
        "due_date" => "2030-01-20"
      })

    {:ok, subsub} = Boards.create_sub_board(c, t)
    subsub = Boards.get_board!(subsub.id)
    d = card_fixture(hd(subsub.columns), %{"title" => "D", "completed" => true})
    e = card_fixture(hd(subsub.columns), %{"title" => "E", "due_date" => "2030-02-01"})

    late = card_fixture(backlog, %{"title" => "Late", "due_date" => "2030-01-01"})
    stuck = card_fixture(backlog, %{"title" => "Stuck"})
    {:ok, _} = Boards.add_dependency(stuck, late)
    loose = card_fixture(backlog, %{"title" => "Loose"})

    %{
      board: board,
      sub: sub,
      subsub: subsub,
      template: t,
      epic: epic,
      b: b,
      c: c,
      d: d,
      e: e,
      late: late,
      stuck: stuck,
      loose: loose
    }
  end
end
