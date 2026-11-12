Code.require_file("../../credo/checks/in_outside_guard.ex", __DIR__)
Code.require_file("../../credo/checks/abc_size.ex", __DIR__)
Code.require_file("../../credo/checks/duplicated_code.ex", __DIR__)

defmodule Slipdock.CredoChecksTest do
  @moduledoc """
  This codebase's own credo checks (credo/checks/, configured in .credo.exs
  and run by CI on what a pull request adds).
  """
  use Credo.Test.Case

  alias Slipdock.Credo.ABCSize
  alias Slipdock.Credo.DuplicatedCode
  alias Slipdock.Credo.InOutsideGuard

  setup_all do
    {:ok, _} = Application.ensure_all_started(:credo)
    :ok
  end

  describe "InOutsideGuard" do
    test "flags `in` and `not in` in a body" do
      """
      defmodule M do
        def a?(x), do: x in [:a, :b]
        def b?(x), do: x not in [:a, :b]
        def c(xs), do: for(x <- xs, x in [:a], do: x)
      end
      """
      |> to_source_file()
      |> run_check(InOutsideGuard)
      |> assert_issues(fn issues -> assert length(issues) == 3 end)
    end

    test "leaves guards alone, in a def, a case clause or a defguard" do
      """
      defmodule M do
        defguard is_ab(x) when x in [:a, :b]
        def a(x) when x in [:a, :b], do: :yes
        def b(x) do
          case x do
            y when y in [1, 2] -> :small
            _ -> :big
          end
        end
        def c(x), do: Enum.member?([:a, :b], x)
      end
      """
      |> to_source_file()
      |> run_check(InOutsideGuard)
      |> refute_issues()
    end

    test "but still sees the body of a guarded function" do
      """
      defmodule M do
        def a(x, ys) when x in [:a, :b], do: x in ys
      end
      """
      |> to_source_file()
      |> run_check(InOutsideGuard)
      |> assert_issue(fn issue -> assert issue.line_no == 2 end)
    end

    test "leaves Ecto queries alone, where `in` is the query's" do
      """
      defmodule M do
        import Ecto.Query
        def a(ids), do: from(p in Post, where: p.id in ^ids)
        def b(q, ids), do: q |> where([p], p.id in ^ids) |> join(:inner, [p], c in assoc(p, :c))
        def c(ids), do: Ecto.Query.where(Post, [p], p.id in ^ids)
        def d(ids), do: dynamic([p], p.id in ^ids)
      end
      """
      |> to_source_file()
      |> run_check(InOutsideGuard)
      |> refute_issues()
    end

    test "a call of the same name on another module is not a query" do
      """
      defmodule M do
        def a(m, ys), do: Map.update(m, :k, false, fn x -> x in ys end)
      end
      """
      |> to_source_file()
      |> run_check(InOutsideGuard)
      |> assert_issue()
    end

    test "leaves a rescue clause's `e in [Mod]` and `e in Mod` alone (#2726)" do
      """
      defmodule M do
        def a(path) do
          try do
            File.read!(path)
          rescue
            e in [File.Error] -> e.reason
            e in ArgumentError -> e.message
            _ in [KeyError, RuntimeError] -> :other
            e -> e
          end
        end

        def b(path) do
          File.read!(path)
        rescue
          e in [File.Error] -> e.reason
          e in ArgumentError -> e.message
        end
      end
      """
      |> to_source_file()
      |> run_check(InOutsideGuard)
      |> refute_issues()
    end

    test "but still sees a rescue clause's body, and the rest of the try" do
      """
      defmodule M do
        def a(x, ys) do
          try do
            x in ys
          rescue
            e in [File.Error] -> e.reason in ys
            e in ArgumentError -> e.message in ys
            e -> e in ys
          catch
            :exit, r -> r in ys
          else
            v -> v in ys
          after
            x in ys
          end
        end

        def b(x, ys) do
          x in ys
        rescue
          e in [File.Error] -> e.reason in ys
        end
      end
      """
      |> to_source_file()
      |> run_check(InOutsideGuard)
      |> assert_issues(fn issues ->
        assert Enum.sort(Enum.map(issues, & &1.line_no)) == [4, 6, 7, 8, 10, 12, 14, 19, 21]
      end)
    end

    test "a `rescue:` key that holds no clauses is walked as any other term" do
      """
      defmodule M do
        def a(x, ys), do: [rescue: x in ys]
        def b(x, ys), do: {:rescue, [x in ys]}
      end
      """
      |> to_source_file()
      |> run_check(InOutsideGuard)
      |> assert_issues(fn issues ->
        assert Enum.map(issues, & &1.line_no) |> Enum.sort() == [2, 3]
      end)
    end
  end

  # A function of n assignments and nothing else has an ABC size of exactly n.
  defp assignments(name, n) do
    lines = Enum.map_join(1..n, "\n", &"    a#{&1} = #{&1}")
    "  def #{name} do\n#{lines}\n    a1\n  end\n"
  end

  defp module(body), do: "defmodule M do\n#{body}end\n"

  describe "ABCSize (#2789)" do
    test "flags a function over the limit, and not one at it" do
      module(assignments("over", 51) <> assignments("at", 50))
      |> to_source_file()
      |> run_check(ABCSize, max_size: 50)
      |> assert_issue(fn issue ->
        assert issue.trigger == "over"
        assert issue.message == "Function is too complex (ABC size is over 50)."
        assert issue.check == ABCSize
      end)
    end

    test "its message doesn't move with the score, so credo diff keeps an old issue old" do
      messages =
        for n <- [51, 80, 60] do
          module(assignments("f", n))
          |> to_source_file()
          |> run_check(ABCSize, max_size: 50)
          |> Enum.map(&{&1.message, &1.trigger})
        end

      assert [[one], [one], [one]] = messages
    end

    test "takes its limit and the calls it doesn't count from the config" do
      source = module(assignments("f", 31))

      source |> to_source_file() |> run_check(ABCSize, max_size: 30) |> assert_issue()
      source |> to_source_file() |> run_check(ABCSize) |> refute_issues()

      # 31 assignments of a call: 31 of each, sqrt(2) * 31, about 44.
      calls = Enum.map_join(1..31, "\n", &"    a#{&1} = bar(#{&1})")
      calls = module("  def g do\n#{calls}\n    a1\n  end\n")

      calls |> to_source_file() |> run_check(ABCSize, max_size: 40) |> assert_issue()

      calls
      |> to_source_file()
      |> run_check(ABCSize, max_size: 40, excluded_functions: ["bar"])
      |> refute_issues()
    end
  end

  # A block well over a mass of 40.
  defp block(name) do
    """
      def #{name}(conn, params) do
        case Map.fetch(params, "board") do
          {:ok, board} ->
            items = Enum.map(board.cards, fn c -> {c.id, c.title, c.position} end)
            json(conn, %{board: board.id, items: items, count: length(items)})

          :error ->
            conn |> put_status(422) |> json(%{error: "board is required"})
        end
      end
    """
  end

  defp file(name, body, padding \\ 0) do
    to_source_file(
      "defmodule #{name} do\n" <> String.duplicate("\n", padding) <> body <> "end\n",
      "lib/#{name}.ex"
    )
  end

  describe "DuplicatedCode (#2789)" do
    test "flags each copy, naming the others by path and without lines" do
      [file("a", block("x")), file("b", block("y")), file("c", "  def z, do: :ok\n")]
      |> run_check(DuplicatedCode, mass_threshold: 40)
      |> assert_issues(fn issues ->
        assert issues |> Enum.map(&{&1.filename, &1.message}) |> Enum.sort() ==
                 [
                   {"lib/a.ex", "Duplicate code found in lib/b.ex (mass: 52)."},
                   {"lib/b.ex", "Duplicate code found in lib/a.ex (mass: 52)."}
                 ]
      end)
    end

    test "names three or more copies in order, whichever order the files come in" do
      files = [file("c", block("x")), file("a", block("y")), file("b", block("z"))]

      for order <- [files, Enum.reverse(files)] do
        order
        |> run_check(DuplicatedCode, mass_threshold: 40)
        |> assert_issues(fn issues ->
          issue = Enum.find(issues, &(&1.filename == "lib/c.ex"))
          assert issue.message == "Duplicate code found in lib/a.ex, lib/b.ex (mass: 52)."
        end)
      end
    end

    test "its message doesn't move when a copy's line does, so credo diff keeps an old issue old" do
      before = [file("a", block("x")), file("b", block("y"))]
      later = [file("a", block("x")), file("b", block("y"), 7)]

      [one, two] =
        for files <- [before, later] do
          files
          |> run_check(DuplicatedCode, mass_threshold: 40)
          |> Enum.find(&(&1.filename == "lib/a.ex"))
          |> Map.take([:message, :line_no, :trigger, :column, :category])
        end

      assert one == two
    end

    test "leaves alone a block under the mass, and a block with one copy" do
      [file("a", block("x")), file("b", block("y"))]
      |> run_check(DuplicatedCode, mass_threshold: 200)
      |> refute_issues()

      [file("a", block("x")), file("b", "  def y, do: :ok\n")]
      |> run_check(DuplicatedCode, mass_threshold: 40)
      |> refute_issues()
    end

    # Two copies under `dir`, named by their absolute paths, as credo names
    # the files on the side of `credo diff` it checks out in a temporary
    # directory. (Credo itself shortens a name under the current directory
    # when it parses the file, so the name is put back here.)
    defp files_under(dir) do
      for {name, fun} <- [{"a", "x"}, {"b", "y"}] do
        path = Path.join(dir, "lib/#{name}.ex")
        source_file = to_source_file("defmodule #{name} do\n#{block(fun)}end\n", path)
        %{source_file | filename: path}
      end
    end

    defp run_in(source_files, exec) do
      :ok = DuplicatedCode.run_on_all_source_files(exec, source_files, mass_threshold: 40)

      source_files
      |> Enum.flat_map(&Credo.Execution.ExecutionIssues.get(exec, &1))
      |> Enum.map(& &1.message)
      |> Enum.sort()
    end

    test "run in credo diff's temporary checkout (--working-dir), names the copies from there" do
      root = Path.join(System.tmp_dir!(), "credo-diff-20261112004249264975")
      refute String.starts_with?(root, File.cwd!())

      exec = %{Credo.Execution.build() | cli_options: %Credo.CLI.Options{path: root}}

      there = run_in(files_under(root), exec)

      assert there == [
               "Duplicate code found in lib/a.ex (mass: 52).",
               "Duplicate code found in lib/b.ex (mass: 52)."
             ]

      # The same messages as the project's own side gives, so credo diff
      # matches them.
      here = %{Credo.Execution.build() | cli_options: %Credo.CLI.Options{path: "."}}
      assert run_in(files_under(File.cwd!()), here) == there
    end

    test "given no working dir, names absolute paths from the current directory" do
      assert run_in(files_under(File.cwd!()), Credo.Execution.build()) == [
               "Duplicate code found in lib/a.ex (mass: 52).",
               "Duplicate code found in lib/b.ex (mass: 52)."
             ]
    end

    test "a file holding the block twice gets one issue, at one of its copies" do
      [file("a", block("x") <> block("y"))]
      |> run_check(DuplicatedCode, mass_threshold: 40)
      |> assert_issue(fn issue ->
        assert issue.message == "Duplicate code found in lib/a.ex (mass: 52)."
        assert issue.line_no in [3, 13]
      end)

      [file("a", block("x") <> block("y")), file("b", block("z"))]
      |> run_check(DuplicatedCode, mass_threshold: 40)
      |> assert_issues(fn issues ->
        assert issues |> Enum.map(&{&1.filename, &1.message}) |> Enum.sort() ==
                 [
                   {"lib/a.ex", "Duplicate code found in lib/a.ex, lib/b.ex (mass: 52)."},
                   {"lib/b.ex", "Duplicate code found in lib/a.ex (mass: 52)."}
                 ]
      end)
    end

    test "leaves alone a block inside a macro the config excludes" do
      files = fn -> [file("a", block("x")), file("b", block("y"))] end

      files.()
      |> run_check(DuplicatedCode, mass_threshold: 40, excluded_macros: [:case])
      |> refute_issues()

      # Another macro's name excludes nothing.
      files.()
      |> run_check(DuplicatedCode, mass_threshold: 40, excluded_macros: [:schema])
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end

    test "names a copy on credo diff's other side by its path in the project" do
      root = "/tmp/credo-diff-20261112004249264975"

      assert DuplicatedCode.relative(Path.join(root, "lib/slipdock/a.ex"), root) ==
               "lib/slipdock/a.ex"

      assert DuplicatedCode.relative("lib/slipdock/a.ex", File.cwd!()) == "lib/slipdock/a.ex"
    end
  end

  describe ".credo.exs (#2789)" do
    setup do
      {config, _} = Code.eval_file(Path.expand("../../.credo.exs", __DIR__))
      [default] = config.configs
      %{enabled: default.checks.enabled, disabled: default.checks.disabled}
    end

    test "gates both with the baseline's thresholds (W-1950 §Credo's size checks)", ctx do
      assert {_, dup} = List.keyfind(ctx.enabled, DuplicatedCode, 0)
      assert dup[:mass_threshold] == 40

      assert {_, abc} = List.keyfind(ctx.enabled, ABCSize, 0)
      assert abc[:max_size] == 50
      assert abc[:files] == %{excluded: ["priv/repo/migrations/"]}
    end

    test "keeps credo's own two off, whose messages credo diff can't match", ctx do
      for check <- [Credo.Check.Design.DuplicatedCode, Credo.Check.Refactor.ABCSize] do
        assert List.keymember?(ctx.disabled, check, 0)
        refute List.keymember?(ctx.enabled, check, 0)
      end
    end
  end
end
