defmodule SlipdockCLI.HandbookTest do
  @moduledoc """
  The handbook in the CLI (#1265): `slipdock card` shows a card's suggested
  sections with the command that reads each, and `slipdock handbook` prints
  a board's index or a card's reading.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  @handbook %{
    "board" => "proj",
    "index_page" => "W-1",
    "more" => 0,
    "index" => [
      %{
        "code" => "W-4",
        "title" => "UX & UI",
        "summary" => "Patterns",
        "read_when" => "building a screen"
      }
    ],
    "suggested" => [
      %{
        "page" => "W-4",
        "title" => "UX & UI",
        "section" => "UX & UI/Patterns",
        "why" => "shares words"
      },
      %{"page" => "W-2", "title" => "Architecture", "section" => nil, "why" => "covers lib/a.ex"}
    ]
  }

  @card %{
    "id" => 7,
    "title" => "Build the menu",
    "column" => "To Do",
    "priority" => "none",
    "flags" => [],
    "tags" => [],
    "checklist" => %{"done" => 0, "total" => 0},
    "comments" => []
  }

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-hb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp serve(body), do: System.put_env("SLIPDOCK_URL", FakeServer.start([{200, body}]))

  test "slipdock card shows the suggested sections and how to read each" do
    out = capture_io(fn -> Render.card(Map.put(@card, "handbook", @handbook)) end)

    assert out =~ "Handbook"
    assert out =~ "close with a Handbook: line"
    assert out =~ "W-4 UX & UI §Patterns"
    assert out =~ ~s(slipdock page section W-4 "UX & UI/Patterns")
    assert out =~ "W-2 Architecture"
    assert out =~ "covers lib/a.ex · slipdock page read W-2"
    assert out =~ "index: slipdock handbook proj (W-1)"
  end

  test "a card with no handbook shows no block" do
    refute capture_io(fn -> Render.card(@card) end) =~ "Handbook"
  end

  test "slipdock handbook <card> asks for the card and prints its reading" do
    serve(JSON.encode!(%{"card" => Map.put(@card, "handbook", @handbook)}))
    out = capture_io(fn -> Boards.run("handbook", ["#7"], []) end)

    assert_received {:request, "GET", "/api/cards/7", _}
    assert out =~ "#7 Build the menu"
    assert out =~ "W-4 UX & UI §Patterns"
  end

  test "slipdock handbook <card> on a board without one says how to install it" do
    serve(JSON.encode!(%{"card" => @card}))
    out = capture_io(fn -> Boards.run("handbook", ["7"], []) end)
    assert out =~ "keeps no handbook"
    assert out =~ "install-board handbook"
  end

  test "slipdock handbook <board> prints the index and decisions" do
    body =
      Map.merge(@handbook, %{
        "more" => 3,
        "decisions" => [%{"code" => "W-9", "title" => "Decision: soft gate"}]
      })

    serve(JSON.encode!(%{"board" => %{"code" => "proj"}, "handbook" => body}))
    out = capture_io(fn -> Boards.run("handbook", ["proj"], []) end)

    assert_received {:request, "GET", "/api/boards/proj/handbook", _}
    assert out =~ "W-4 UX & UI — Patterns"
    assert out =~ "read when: building a screen"
    assert out =~ "and 3 more pages"
    assert out =~ "W-9 Decision: soft gate"
  end

  test "slipdock handbook <board> counts the rules and lists the items it couldn't read (#1773)" do
    rules = %{
      "count" => 4,
      "must" => 3,
      "problems" => [
        %{
          "page" => "W-5",
          "line" => 7,
          "item" => "**DATA-3** must · Never edited.",
          "problem" => "no check: a test path, or `judgement`"
        }
      ]
    }

    serve(
      JSON.encode!(%{
        "board" => %{"code" => "proj"},
        "handbook" => Map.put(@handbook, "rules", rules)
      })
    )

    out = capture_io(fn -> Boards.run("handbook", ["proj"], []) end)

    assert out =~ "Rules  4 (3 must) · 1 not read"
    assert out =~ "W-5 line 7: no check: a test path, or `judgement`"
    assert out =~ "**DATA-3** must · Never edited."
  end

  test "slipdock handbook <board> with every rule read lists no problems" do
    rules = %{"count" => 2, "must" => 1, "problems" => []}

    serve(
      JSON.encode!(%{
        "board" => %{"code" => "proj"},
        "handbook" => Map.put(@handbook, "rules", rules)
      })
    )

    out = capture_io(fn -> Boards.run("handbook", ["proj"], []) end)

    assert out =~ "Rules  2 (1 must)"
    refute out =~ "not read"
  end

  test "slipdock handbook <board> from an older server shows no Rules line" do
    serve(JSON.encode!(%{"board" => %{"code" => "proj"}, "handbook" => @handbook}))
    refute capture_io(fn -> Boards.run("handbook", ["proj"], []) end) =~ "Rules"
  end

  @rule %{
    "id" => "DATA-2",
    "severity" => "must",
    "page" => "W-5",
    "section" => "Data model/Rules",
    "check" => "test/app/migrations_test.exs",
    "text" => "Never edit a run migration.",
    "scope" => ["priv/repo/**"]
  }

  @should %{@rule | "id" => "DATA-1", "severity" => "should", "text" => "Prefer a column."}

  defp rules_body(paths, rules),
    do:
      JSON.encode!(%{
        "board" => %{"code" => "proj"},
        "handbook" => %{
          "board" => "proj",
          "index_page" => "W-1",
          "paths" => paths,
          "rules" => rules
        }
      })

  test "slipdock card shows the rules for the card's paths, and how many more (#1774)" do
    h = Map.merge(@handbook, %{"rules" => [@rule], "rules_more" => 3})
    out = capture_io(fn -> Render.card(Map.put(@card, "handbook", h)) end)

    assert out =~ "Rules  for the card's paths"
    assert out =~ "DATA-2 must  Never edit a run migration."
    assert out =~ "check: test/app/migrations_test.exs · W-5 §Rules"
    assert out =~ "… and 3 more: slipdock handbook proj --paths …"
  end

  test "slipdock card with paths no rule covers says so; without paths, no Rules line" do
    out =
      capture_io(fn ->
        Render.card(Map.put(@card, "handbook", Map.put(@handbook, "rules", [])))
      end)

    assert out =~ "none cover these paths"
    refute capture_io(fn -> Render.card(Map.put(@card, "handbook", @handbook)) end) =~ "Rules"
  end

  test "slipdock handbook <board> --paths asks for those paths and prints the rules" do
    serve(rules_body(["a.ex", "priv/repo/x.exs"], [@rule, @should]))
    out = capture_io(fn -> Boards.run("handbook", ["proj"], paths: "a.ex, priv/repo/x.exs") end)

    assert_received {:request, "GET", path, _}
    assert URI.decode_www_form(path) == "/api/boards/proj/handbook?paths=a.ex,priv/repo/x.exs"
    assert out =~ "Rules  proj · 2 paths"
    assert out =~ "DATA-2 must  Never edit a run migration."
    assert out =~ "DATA-1 should  Prefer a column."
  end

  test "--paths-from - reads a diff from stdin, in chunks, each rule once, must first" do
    paths = for n <- 1..45, do: "priv/repo/m#{n}.exs"
    first = Enum.take(paths, 40)
    rest = Enum.drop(paths, 40)

    System.put_env(
      "SLIPDOCK_URL",
      FakeServer.start([
        {200, rules_body(first, [@should])},
        {200, rules_body(rest, [@rule, @should])}
      ])
    )

    stdin = Enum.join(paths ++ ["", "priv/repo/m1.exs"], "\n") <> "\n"
    out = capture_io(stdin, fn -> Boards.run("handbook", ["proj"], paths_from: "-") end)

    assert_received {:request, "GET", one, _}
    assert_received {:request, "GET", two, _}
    assert URI.decode_www_form(one) =~ "paths=priv/repo/m1.exs,"
    assert URI.decode_www_form(one) =~ ",priv/repo/m40.exs"
    assert URI.decode_www_form(two) =~ "paths=priv/repo/m41.exs,"

    assert out =~ "proj · 45 paths"
    [must_at] = Regex.run(~r/DATA-2 must/, out, return: :index) |> Enum.map(&elem(&1, 0))
    [should_at] = Regex.run(~r/DATA-1 should/, out, return: :index) |> Enum.map(&elem(&1, 0))
    assert must_at < should_at
    assert length(Regex.scan(~r/DATA-1 should/, out)) == 1
  end

  test "--paths on a board without a handbook says so" do
    serve(JSON.encode!(%{"board" => %{"code" => "proj"}, "handbook" => nil}))
    out = capture_io(fn -> Boards.run("handbook", ["proj"], paths: "a.ex") end)
    assert out =~ "proj keeps no handbook"
  end

  test "--paths with nothing matching says so" do
    serve(rules_body(["README.md"], []))
    out = capture_io(fn -> Boards.run("handbook", ["proj"], paths: "README.md") end)
    assert out =~ "proj · 1 path"
    assert out =~ "none cover these paths"
  end

  test "slipdock handbook <board> without one says so" do
    serve(JSON.encode!(%{"board" => %{"code" => "proj"}, "handbook" => nil}))
    out = capture_io(fn -> Boards.run("handbook", ["proj"], []) end)
    assert out =~ "proj keeps no handbook"
  end
end
