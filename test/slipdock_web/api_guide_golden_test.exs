defmodule SlipdockWeb.APIGuideGoldenTest do
  @moduledoc """
  The guide `GET /api/guide` serves, held to a copy of it (#2800). Its prose
  is Markdown under `lib/slipdock_web/api_guide/`, compiled into
  `SlipdockWeb.APIGuide` as EEx templates, so a slip in a template (a lost
  newline, an assign that renders wrong, a section left out) changes the
  output, and this says where.

  Two readers: one with no token, and one signed in with a board that has
  every switch on, so the sections only such a reader sees (*Verified work*,
  *Lanes*, *Profiles*, the board lines) are held too. Each is held in both
  the whole guide and the short one, whose boards section differs (#2925). The board's ids are
  replaced with placeholders, as they differ from run to run.

  A change to the guide's text changes these on purpose: regenerate them with
  `GOLDEN=1 mix test test/slipdock_web/api_guide_golden_test.exs` and read
  the diff of `test/support/fixtures/api_guide/` before committing it.
  """
  use SlipdockWeb.ConnCase, async: true

  alias SlipdockWeb.APIGuide

  @dir Path.expand("../support/fixtures/api_guide", __DIR__)
  @base "https://slipdock.example.com"

  defp golden(name, text) do
    path = Path.join(@dir, name)

    if System.get_env("GOLDEN") == "1" do
      File.mkdir_p!(@dir)
      File.write!(path, text)
    end

    expected = File.read!(path)

    if text != expected do
      flunk("""
      #{name}: the guide differs from its copy, first at line #{first_difference(text, expected)}.
      If the change is meant, regenerate it with GOLDEN=1 (see the moduledoc).
      """)
    end
  end

  defp first_difference(a, b) do
    Enum.zip(String.split(a, "\n"), String.split(b, "\n"))
    |> Enum.find_index(fn {x, y} -> x != y end)
    |> case do
      nil -> min(length(String.split(a, "\n")), length(String.split(b, "\n"))) + 1
      i -> i + 1
    end
  end

  defp signed_in do
    owner = Slipdock.Fixtures.user_fixture("guide-golden@example.com")
    {:ok, owner} = owner |> Ecto.Changeset.change(name: "Golden Reader") |> Slipdock.Repo.update()

    board =
      Slipdock.Fixtures.board_fixture(%{"name" => "Golden", "code" => "golden"}, owner: owner)

    {:ok, board} =
      Slipdock.Boards.update_board(board, %{
        "bar_required" => true,
        "evidence_required" => true,
        "verify_work" => true,
        "ship_via" => "pull_request",
        "lane_mode" => "hold",
        "shared_paths" => ["docs/manual.md"],
        "profiles" => true
      })

    board = Slipdock.Repo.preload(board, :columns, force: true)
    {owner, board}
  end

  # What a fresh database hands out (the ids, the fixture's unique email),
  # as placeholders. Only in the board's own lines: the guide's examples
  # have ids of their own (`(#57)`), which a list or board given the same
  # number must not take with it (#2925).
  defp scrub(text, owner, board) do
    board.columns
    |> Enum.reduce(text, fn col, acc ->
      String.replace(acc, "“#{col.name}” (##{col.id})", "“#{col.name}” (#COLUMN)")
    end)
    |> String.replace("**##{board.id} #{board.name}**", "**#BOARD #{board.name}**")
    |> String.replace(owner.email, "reader@example.com")
  end

  test "the whole guide, read with no token" do
    golden("anonymous.md", APIGuide.markdown(base_url: @base))
  end

  test "the short guide, read with no token" do
    golden("short.md", APIGuide.short(base_url: @base))
  end

  test "the whole guide, read signed in with every switch on" do
    {owner, board} = signed_in()
    guide = APIGuide.markdown(base_url: @base, user: owner)

    # The sections only this reader is shown are there to be held.
    for heading <- ["## Verified work", "## Lanes", "## Profiles", "## Your boards right now"],
        do: assert(guide =~ heading)

    golden("signed_in.md", scrub(guide, owner, board))
  end

  # The short guide's boards section is the signed-in reader's alone (#2925):
  # the copy read with no token takes the anonymous one, so this holds the
  # boards list with the Housekeeping note left out of it.
  test "the short guide, read signed in with every switch on" do
    {owner, board} = signed_in()
    guide = APIGuide.short(base_url: @base, user: owner)

    assert guide =~ "## Your boards right now"
    assert guide =~ "- **##{board.id} Golden** (`golden`)"
    refute guide =~ "A Housekeeping list comes last"

    # The whole guide is where that note is, for the same reader.
    assert APIGuide.markdown(base_url: @base, user: owner) =~ "A Housekeeping list comes last"

    golden("short_signed_in.md", scrub(guide, owner, board))
  end

  # One board and nothing archived never reaches the short guide's limits,
  # so a reader past both is held here: ten boards with their lists, the
  # rest by name, and five archived boards named with the rest counted.
  test "the short guide lists ten boards and names five archived ones" do
    owner = Slipdock.Fixtures.user_fixture("guide-many@example.com")

    # Codes of the module's own (TEST-10), so no other async test waits on them.
    for n <- 1..12 do
      Slipdock.Fixtures.board_fixture(
        %{"name" => "Open #{n}", "code" => Slipdock.Fixtures.unique_code()},
        owner: owner
      )
    end

    for n <- 1..6 do
      board =
        Slipdock.Fixtures.board_fixture(
          %{"name" => "Shelved #{n}", "code" => Slipdock.Fixtures.unique_code()},
          owner: owner
        )

      {:ok, _} = Slipdock.Boards.Arrangement.archive_board(board)
    end

    short = APIGuide.short(base_url: @base, user: owner)
    whole = APIGuide.markdown(base_url: @base, user: owner)

    with_lists = fn guide -> length(Regex.scan(~r/^- \*\*#\d+ Open \d+\*\* \(`/m, guide)) end
    also = fn guide -> length(Regex.scan(~r/[:,] #\d+ Open \d+ \(`/, guide)) end
    shelved = fn guide -> length(Regex.scan(~r/#\d+ Shelved \d+ \(`/, guide)) end

    assert with_lists.(short) == 10
    assert short =~ "\n- Also: #"
    assert also.(short) == 2
    assert short =~ "\n6 boards are archived"
    assert shelved.(short) == 5
    assert short =~ ~r/Shelved \d+ \(`[^`]+`\) and 1 more\.\n/

    assert with_lists.(whole) == 12
    refute whole =~ "- Also: "
    assert also.(whole) == 0
    assert shelved.(whole) == 6
    refute whole =~ "and 1 more"
  end

  # The copies above sign in a reader with a name, so the one without is
  # held here: nothing stands between the address and the full stop.
  test "a signed-in reader with no name is named by address alone" do
    owner = Slipdock.Fixtures.user_fixture("guide-nameless@example.com")
    assert owner.name == nil

    guide = APIGuide.markdown(base_url: @base, user: owner)

    assert guide =~ "Your token works: you are **#{owner.email}**.\n"
    refute guide =~ "**#{owner.email}** ("
  end

  test "a signed-in reader with a name has it in brackets after the address" do
    owner = Slipdock.Fixtures.user_fixture("guide-named@example.com")
    {:ok, owner} = owner |> Ecto.Changeset.change(name: "Named Reader") |> Slipdock.Repo.update()

    guide = APIGuide.markdown(base_url: @base, user: owner)

    assert guide =~ "Your token works: you are **#{owner.email}** (Named Reader).\n"
  end

  # Without `@external_resource`, an edit to a section's Markdown doesn't
  # recompile the module in an incremental build (the dev server, a restored
  # `_build` cache), which then serves the old text.
  test "every section's Markdown file is an external resource of the module" do
    files =
      "../../lib/slipdock_web/api_guide/*.md"
      |> Path.expand(__DIR__)
      |> Path.wildcard()

    resources =
      for {:external_resource, paths} <- APIGuide.__info__(:attributes), path <- paths, do: path

    assert files != []
    assert Enum.sort(files) == Enum.sort(resources)
  end

  test "GET /api/guide serves the same text" do
    body = build_conn() |> get("/api/guide") |> response(200)
    copy = @dir |> Path.join("anonymous.md") |> File.read!()
    assert body == String.replace(copy, @base, "http://www.example.com")
  end
end
