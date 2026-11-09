defmodule Slipdock.TrustContractTest do
  @moduledoc """
  The trust contract (#2581, W-2544 §9) is one text,
  `daemon/internal/contract/contract.md`: the daemon embeds it for
  `slipdock-runner show`, the server reads it at compile time for the
  Machines page, Help › Agents and the API guide, and the manual carries a
  copy held equal to it here. README and `docs/agents.md` link to the
  manual's copy. The production image has to have the file to compile.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Machines.TrustContract

  @root Path.expand("../..", __DIR__)
  @manual "docs/manual/machines.md"
  @anchor "#{@manual}#what-the-server-can-and-cannot-do"

  defp read(path), do: File.read!(Path.join(@root, path))
  defp words(text), do: text |> String.split() |> Enum.join(" ")

  describe "the one text" do
    test "is the file, as it is now" do
      assert TrustContract.markdown() == read(TrustContract.source())
    end

    test "says what nothing here bounds, as W-2544 §9 lists it" do
      text = words(TrustContract.markdown())

      for promise <- [
            "#### What the server can do",
            "#### What the server cannot do",
            "Run a command on this machine.",
            "Install an update that isn't signed",
            "#### What nothing here bounds",
            "First-install trust.",
            "the operator who runs the server is also the one who signs the releases",
            "unless its runner uses the `container` executor with the network off",
            "Prompts are the board members' instructions.",
            "within the runner's permission mode"
          ] do
        assert text =~ promise, "the contract no longer says #{promise}"
      end
    end

    test "says, for every executor a runner may name, what it stops and what it doesn't" do
      [_, section] = String.split(TrustContract.markdown(), "#### What each executor stops")
      items = section |> String.split("\n- ") |> Enum.map(&words/1)

      for executor <- Slipdock.Runners.Config.executors() do
        item = Enum.find(items, &String.starts_with?(&1, "`#{executor}`:"))
        assert item, "no paragraph for #{executor}"
        assert item =~ "stops"
        if executor != "me", do: assert(item =~ "doesn't stop", "#{executor}: #{item}")
      end
    end
  end

  describe "the manual's copy" do
    test "is the text, word for word" do
      assert TrustContract.carried?(read(@manual)),
             "#{@manual} no longer carries #{TrustContract.source()}: copy it between the markers"
    end

    test "sits under the section README and docs/agents.md link to" do
      [_, after_heading] = String.split(read(@manual), "### What the server can and cannot do\n")
      [section | _] = String.split(after_heading, "\n### ")
      assert {:ok, _} = TrustContract.copy_in(section)
    end

    test "a changed, missing or doubled copy is caught" do
      manual = read(@manual)
      {:ok, copy} = TrustContract.copy_in(manual)

      reworded =
        String.replace(manual, copy, String.replace(copy, "cannot", "can", global: false))

      refute TrustContract.carried?(reworded)

      shortened =
        String.replace(manual, copy, String.replace(copy, ~r/\n- Read files.*?\n- /s, "\n- "))

      refute TrustContract.carried?(shortened)

      refute TrustContract.carried?(String.replace(manual, TrustContract.copy_end(), ""))
      refute TrustContract.carried?(String.replace(manual, TrustContract.copy_start(), ""))

      block = TrustContract.copy_start() <> "\n" <> copy <> "\n" <> TrustContract.copy_end()
      assert TrustContract.copy_in(manual <> "\n" <> block <> "\n") == :error

      # Only the edges' whitespace is forgiven.
      assert TrustContract.carried?(String.replace(manual, copy, "\n" <> copy <> "\n\n"))
    end
  end

  test "README and docs/agents.md link to the manual's copy" do
    assert read("README.md") =~ "](#{@anchor})"
    assert read("docs/agents.md") =~ "](#{String.replace_prefix(@anchor, "docs/", "")})"

    readme = words(read("README.md"))

    for unbounded <- [
          "first-install download trust",
          "the hosted operator also being the signer",
          "the network outside a container",
          "prompts being the board members' instructions within the runner's permission mode"
        ] do
      assert readme =~ unbounded
    end
  end

  test "the API guide carries the whole text" do
    assert words(SlipdockWeb.APIGuide.markdown()) =~ words(TrustContract.markdown())
  end

  describe "the production image" do
    test "copies the text into the build before mix compile" do
      [before_compile, _] = String.split(read("Dockerfile"), "\nRUN mix compile\n", parts: 2)
      source = TrustContract.source()
      assert before_compile =~ ~r/^COPY #{Regex.escape(source)} #{Path.dirname(source)}\/?$/m
    end

    test "doesn't leave it out of the build context" do
      refute ignored?(read(".dockerignore"), TrustContract.source())
    end

    test "the ignore check finds a pattern that would leave it out" do
      source = TrustContract.source()

      for pattern <- [
            "daemon",
            "daemon/",
            "daemon/internal",
            "daemon/*/contract",
            "**/*.md",
            "daemon/**"
          ] do
        assert ignored?(pattern, source), pattern
      end

      for pattern <- ["# daemon", "cli/_build", "*.md", "daemon/cmd", "!daemon"] do
        refute ignored?(pattern, source), pattern
      end
    end
  end

  # Whether a .dockerignore leaves `path` out of the build context: a pattern
  # matching the path or a directory above it, matched against the whole path
  # as Docker does (so `*.md` is only the root's). `!` exceptions aren't weighed
  # (the file has none for this path), so they count as not ignoring.
  defp ignored?(dockerignore, path) do
    parts = Path.split(path)
    prefixes = for n <- 1..length(parts), do: parts |> Enum.take(n) |> Path.join()

    dockerignore
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["#", "!"])))
    |> Enum.any?(fn pattern ->
      regex = glob(String.trim_trailing(pattern, "/"))
      Enum.any?(prefixes, &Regex.match?(regex, &1))
    end)
  end

  defp glob(pattern) do
    body =
      pattern
      |> String.replace_prefix("**/", "\u0001")
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\u0001", "(.*/)?")

    Regex.compile!("^" <> body <> "$")
  end
end
