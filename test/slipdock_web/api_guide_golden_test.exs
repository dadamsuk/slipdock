defmodule SlipdockWeb.APIGuideGoldenTest do
  @moduledoc """
  The guide `GET /api/guide` serves, held to a copy of it (#2800). Its prose
  is Markdown under `lib/slipdock_web/api_guide/`, compiled into
  `SlipdockWeb.APIGuide` as EEx templates, so a slip in a template (a lost
  newline, an assign that renders wrong, a section left out) changes the
  output, and this says where.

  Two readers: one with no token, and one signed in with a board that has
  every switch on, so the sections only such a reader sees (*Verified work*,
  *Lanes*, *Profiles*, the board lines) are held too. The board's ids are
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
  # as placeholders.
  defp scrub(text, owner, board) do
    board.columns
    |> Enum.reduce(text, fn col, acc -> String.replace(acc, "(##{col.id})", "(#COLUMN)") end)
    |> String.replace("##{board.id} ", "#BOARD ")
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

  test "GET /api/guide serves the same text" do
    body = build_conn() |> get("/api/guide") |> response(200)
    copy = @dir |> Path.join("anonymous.md") |> File.read!()
    assert body == String.replace(copy, @base, "http://www.example.com")
  end
end
