defmodule Slipdock.SyncSaysWhyTest do
  @moduledoc """
  TEST-9 (#2607): a test module is `async: true` unless it shares something
  that can't be rolled back, and a sync one says why in a comment directly
  above its `use` line. Broken twice in 30 days (#2571) while it was only a
  judgement, so this holds every test file to it.

  A `use` line is sync when it says `async: false`, or when it uses
  `ExUnit.Case`, `Slipdock.DataCase` or `SlipdockWeb.ConnCase` with no
  `async:` at all (all three default to sync). The comment is one or more
  `#` lines ending on the line just above; a `@moduledoc` saying why doesn't
  count, since the reason belongs beside the line it explains.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # The cases that are sync when `use`d with no `async:` option.
  @sync_by_default ~w(ExUnit.Case Slipdock.DataCase SlipdockWeb.ConnCase)

  @doc false
  # The line numbers of the sync `use` lines in `source` with no comment
  # directly above them.
  def unexplained(source) do
    lines = String.split(source, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> sync_use?(line) end)
    |> Enum.reject(fn {_, n} -> n > 1 and comment?(Enum.at(lines, n - 2)) end)
    |> Enum.map(fn {_, n} -> n end)
  end

  defp sync_use?(line) do
    case Regex.run(~r/^\s*use\s+([A-Z][\w.]*)\s*(,.*)?$/, line) do
      [_, _case, opts] -> opts =~ ~r/\basync:\s*false\b/
      [_, name] -> name in @sync_by_default
      nil -> false
    end
  end

  defp comment?(line), do: line =~ ~r/^\s*#/

  defp test_files do
    @root
    |> Path.join("test/**/*_test.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.sort()
  end

  describe "unexplained/1" do
    test "a sync module with a comment directly above its use line passes" do
      source = """
      defmodule A do
        # Sync: sets the Logger level, which is the node's.
        use Slipdock.DataCase, async: false
      end
      """

      assert unexplained(source) == []
    end

    test "a comment of several lines counts as long as it ends just above" do
      source = """
      defmodule A do
        # Sync: each test resets the rate-limit counts, which are one table
        # for the node.
        use SlipdockWeb.ConnCase, async: false
      end
      """

      assert unexplained(source) == []
    end

    test "async: false with nothing above its use line is named by line" do
      source = """
      defmodule A do
        use Slipdock.DataCase, async: false
      end
      """

      assert unexplained(source) == [2]
    end

    test "a moduledoc saying why is not the comment" do
      source = """
      defmodule A do
        @moduledoc "Sync: it turns the limiter on."
        use SlipdockWeb.ConnCase, async: false
      end
      """

      assert unexplained(source) == [3]
    end

    test "a # inside the code on the line above isn't a comment" do
      source = """
      defmodule A do
        @moduledoc "Deploys are rate-limited per board (#1134)."
        use SlipdockWeb.ConnCase, async: false
      end
      """

      assert unexplained(source) == [3]
    end

    test "a comment with a blank line before the use line doesn't count" do
      source = """
      defmodule A do
        # Sync: Mix.shell is global.

        use ExUnit.Case, async: false
      end
      """

      assert unexplained(source) == [4]
    end

    test "a comment further up, above other code, doesn't count" do
      source = """
      defmodule A do
        # Sync: Mix.shell is global.
        @moduletag :slow
        use ExUnit.Case, async: false
      end
      """

      assert unexplained(source) == [4]
    end

    test "a case that defaults to sync, used with no async option, needs one too" do
      for name <- ["ExUnit.Case", "Slipdock.DataCase", "SlipdockWeb.ConnCase"] do
        assert unexplained("defmodule A do\n  use #{name}\nend\n") == [2], name
      end
    end

    test "async: true, and a case that defaults to async, need nothing" do
      source = """
      defmodule A do
        use Slipdock.DataCase, async: true
      end

      defmodule B do
        use Credo.Test.Case
      end
      """

      assert unexplained(source) == []
    end

    test "every sync module in a file is checked, not just the first" do
      source = """
      defmodule A do
        # Sync: Mix.shell is global.
        use ExUnit.Case, async: false
      end

      defmodule B do
        use ExUnit.Case, async: false
      end
      """

      assert unexplained(source) == [7]
    end

    test "async: false inside a string or an option list isn't a use line" do
      source = """
      defmodule A do
        use ExUnit.Case, async: true

        test "x" do
          src = "use Slipdock.DataCase, async: false"
          Config.override(:findings, async: false)
        end
      end
      """

      assert unexplained(source) == []
    end

    test "a use line on the first line of a file has nothing above it" do
      assert unexplained("use ExUnit.Case, async: false\n") == [1]
    end
  end

  test "every sync test module says why above its use line (TEST-9)" do
    missing =
      for path <- test_files(),
          # Its own examples are sync use lines inside strings.
          path != "test/slipdock/sync_says_why_test.exs",
          n <- unexplained(File.read!(Path.join(@root, path))),
          do: "#{path}:#{n}"

    assert missing == [],
           """
           These test modules are sync with no comment directly above their \
           `use` line saying why (TEST-9, W-1950 §Tests):

             #{Enum.join(missing, "\n  ")}

           Make the module `async: true` if it shares nothing that can't be \
           rolled back; otherwise say what it shares in a `#` comment on the \
           line(s) just above `use`.
           """
  end
end
