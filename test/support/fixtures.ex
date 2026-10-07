defmodule Slipdock.Fixtures do
  @moduledoc "Helpers for building boards, cards and tags in tests."

  alias Slipdock.{Accounts, Boards}

  @doc """
  The default test user (the one ConnCase signs in), created on first use.
  Its email is `default_email/0`, different in every test.
  """
  def user_fixture(email \\ nil) do
    {:ok, user} = Accounts.get_or_create_user_by_email(fixture_email(email))
    user
  end

  @doc """
  The address `user_fixture/1` really uses for `email`. In an async test an
  `@example.com` address moves to the test's own domain (see
  `default_email/0`), so "stranger@example.com" in two tests running at once
  is two people rather than one row both wait on; a sync test runs alone and
  keeps the address as written.
  """
  def fixture_email(nil), do: default_email()

  def fixture_email(email) do
    case {Process.get({__MODULE__, :async}), String.split(email, "@")} do
      {true, [local, "example.com"]} -> local <> "@" <> test_domain()
      _ -> email
    end
  end

  @doc "Marks the calling test as async, for `fixture_email/1`. Called by `Slipdock.DataCase`."
  def mark_async(async?), do: Process.put({__MODULE__, :async}, async? == true)

  defp test_domain, do: default_email() |> String.split("@") |> List.last()

  @doc """
  The default test user's email: `tester@` a domain of this test's own, the
  same on every call within one test.

  It used to be `tester@example.com` for every test. Async tests each run in
  an uncommitted sandbox transaction, so every one creating that user waited
  for every other one that had, and two fixed emails taken in opposite orders
  were a deadlock. Kept as `tester@` so it still reads, and matches, as
  "tester".
  """
  def default_email do
    case Process.get({__MODULE__, :default_email}) do
      nil ->
        email = "tester@t#{System.unique_integer([:positive])}.example.com"
        Process.put({__MODULE__, :default_email}, email)
        email

      email ->
        email
    end
  end

  @doc """
  Creates a board owned by `opts[:owner]` (default: the default test user).

  Unless `attrs` names them, the board gets a code and shortcut unique to this
  test run rather than ones derived from its name. Async tests each run in an
  uncommitted sandbox transaction, so two of them deriving the same code or
  shortcut ("Private" → `private`, `p`) block on each other's unique index,
  and with a fixed user email held the other way round that is a deadlock.
  Pass `derive_keys: true` for a test about that derivation itself.
  """
  def board_fixture(attrs \\ %{}, opts \\ []) do
    owner = opts[:owner] || user_fixture()
    n = System.unique_integer([:positive])

    defaults =
      if opts[:derive_keys],
        do: %{"name" => "Board #{n}"},
        else: %{
          "name" => "Board #{n}",
          "code" => unique_code(n),
          "shortcut" => unique_shortcut()
        }

    {:ok, board} =
      Boards.create_board(
        Map.merge(defaults, attrs),
        template: opts[:template],
        owner_id: owner.id
      )

    Boards.get_board!(board.id)
  end

  @shortcut_chars Enum.map(~c"abcdefghijklmnopqrstuvwxyz0123456789", &<<&1>>)

  defp unique_code(n), do: "t" <> String.downcase(Integer.to_string(n, 36))

  @shortcuts __MODULE__.Shortcuts

  @doc """
  Creates the table `board_fixture/2` hands shortcuts out from. Called once,
  from `test/test_helper.exs`, so it lives as long as the run.
  """
  def start_shortcuts do
    :ets.new(@shortcuts, [:set, :public, :named_table])
    :ok
  end

  # Two characters, so never one a name-derived single-letter shortcut takes.
  # That is only 1,296 of them and a run makes far more boards, so they go
  # round in turn, skipping any still held by a test that is running: drawing
  # one of those would wait on that test's uncommitted board until it ended.
  defp unique_shortcut do
    Stream.repeatedly(fn -> :ets.update_counter(@shortcuts, :next, 1, {:next, -1}) end)
    |> Enum.find_value(fn i ->
      i = rem(i, 36 * 36)
      shortcut = Enum.at(@shortcut_chars, div(i, 36)) <> Enum.at(@shortcut_chars, rem(i, 36))
      if claim_shortcut(shortcut, self()), do: shortcut
    end)
  end

  defp claim_shortcut(shortcut, me) do
    :ets.insert_new(@shortcuts, {shortcut, me}) or
      case :ets.lookup(@shortcuts, shortcut) do
        [{_, ^me}] ->
          false

        [{_, pid}] ->
          not Process.alive?(pid) and
            :ets.select_replace(@shortcuts, [{{shortcut, pid}, [], [{{shortcut, me}}]}]) == 1

        [] ->
          claim_shortcut(shortcut, me)
      end
  end

  @doc """
  Shares `board` with each of `users` at `level`, granted by its owner. A card
  can only be assigned to somebody who can open it, so a test that puts people
  on cards shares the board with them first.
  """
  def share_fixture(board, users, level \\ "write") do
    owner = Accounts.get_user!(board.owner_id)

    for user <- List.wrap(users),
        do: {:ok, _} = Slipdock.Access.grant(board, user, level, owner)

    board
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
  `Boards.create_sub_board/2` with a code unique to this run rather than one
  derived from the card's title — for the same reason `board_fixture/2` does
  it: two async tests both giving an "Epic" card subcards would otherwise
  wait on each other's `epic`. Use the real thing in a test about the code.
  """
  def sub_board(card, template),
    do:
      Boards.create_sub_board(card, template,
        code: unique_code(System.unique_integer([:positive]))
      )

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

    {:ok, sub} =
      Boards.create_sub_board(epic, t, code: unique_code(System.unique_integer([:positive])))

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

    {:ok, subsub} =
      Boards.create_sub_board(c, t, code: unique_code(System.unique_integer([:positive])))

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
