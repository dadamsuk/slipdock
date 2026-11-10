Code.require_file("../../credo/checks/in_outside_guard.ex", __DIR__)

defmodule Slipdock.CredoChecksTest do
  @moduledoc """
  This codebase's own credo checks (credo/checks/, configured in .credo.exs
  and run by CI on what a pull request adds).
  """
  use Credo.Test.Case

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
end
