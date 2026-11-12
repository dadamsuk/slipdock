defmodule Slipdock.BoundariesTest do
  @moduledoc """
  The boundary between the contexts and the web layer (handbook W-1945
  §Boundaries), read from the compiler's own cross-reference data
  (`mix xref graph`):

    * A context (`lib/slipdock.ex`, `lib/slipdock/**`) doesn't refer to a
      `SlipdockWeb` module. The ones that already did are listed below with
      their reasons; a new one fails.
    * The web layer (`lib/slipdock_web*`) doesn't call `Slipdock.Repo`: it
      reads and writes through the contexts (#2791). The one file that
      may is listed below with its reason; a new one fails.
    * Compile-connected cycles, which make one edit recompile hundreds of
      files, stay at or under the ceiling recorded here. The ceiling only
      goes down: when a change brings the count under it, lower it to match
      in the same change.

  The checks are pure functions over xref's output, so the tests below show
  each one failing on a graph made for the purpose before it is run on the
  real one.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Context file => the web files it may refer to, and why.
  @allowed %{
    "lib/slipdock/application.ex" => {
      ~w(lib/slipdock_web/endpoint.ex lib/slipdock_web/presence.ex lib/slipdock_web/telemetry.ex),
      "the application's supervision tree starts the web processes"
    },
    # Endpoint config, url/0 and broadcast/3: absolute links in mail and
    # notifications, the secret key base, and disconnecting a signed-out
    # user's live sessions. The endpoint is the one place they are set.
    "lib/slipdock/accounts.ex" => {~w(lib/slipdock_web/endpoint.ex), "broadcast, links"},
    "lib/slipdock/automations/runner.ex" => {~w(lib/slipdock_web/endpoint.ex), "links"},
    "lib/slipdock/google.ex" => {~w(lib/slipdock_web/endpoint.ex), "OAuth redirect URL"},
    "lib/slipdock/inbound/tokens.ex" => {~w(lib/slipdock_web/endpoint.ex), "secret key base"},
    # SlipdockWeb.APIGuide.list_roles/0: the card roles agents are told
    # about. Debt: the list belongs in a context, and these move with it.
    "lib/slipdock/blueprint.ex" => {~w(lib/slipdock_web/api_guide.ex), "role list"},
    "lib/slipdock/boards/copy.ex" => {~w(lib/slipdock_web/api_guide.ex), "role list"},
    "lib/slipdock/flow.ex" => {~w(lib/slipdock_web/api_guide.ex), "role list"},
    "lib/slipdock/gardener/context.ex" => {~w(lib/slipdock_web/api_guide.ex), "role list"},
    "lib/slipdock/health/detectors/orphan_in_progress.ex" =>
      {~w(lib/slipdock_web/api_guide.ex), "role list"},
    "lib/slipdock/inbound/cards.ex" => {~w(lib/slipdock_web/api_guide.ex), "role list"},
    "lib/slipdock/lead_time.ex" => {~w(lib/slipdock_web/api_guide.ex), "role list"},
    "lib/slipdock/quick_add/capture.ex" => {~w(lib/slipdock_web/api_guide.ex), "role list"},
    "lib/slipdock/recurrence.ex" => {~w(lib/slipdock_web/api_guide.ex), "role list"},
    # Debt: Markdown from wiki HTML belongs beside the wiki, not the renderer.
    "lib/slipdock/ai/researcher.ex" => {~w(lib/slipdock_web/wiki/renderer.ex), "to_markdown/1"}
  }

  # Web file => why it may call `Slipdock.Repo` itself. Every lookup goes
  # through a context; this list is for what isn't a lookup.
  @repo_allowed %{
    "lib/slipdock_web/health.ex" =>
      "the health check asks the database itself to answer (`SELECT 1`), not for anything in it"
  }

  @repo "lib/slipdock/repo.ex"

  # Today's compile-connected cycles: how many, and how many files in them
  # are joined by a compile-time edge. Only ever lowered.
  @cycle_ceiling %{cycles: 1, compile: 12}

  # ---- the checks ----------------------------------------------------------

  defp context?(file), do: file == "lib/slipdock.ex" or String.starts_with?(file, "lib/slipdock/")
  defp web?(file), do: String.starts_with?(file, "lib/slipdock_web")

  @doc false
  # `graph` is `mix xref graph --format json`: file => %{file => label}.
  def web_references(graph, allowed) do
    for {file, deps} <- graph,
        context?(file),
        {dep, label} <- deps,
        web?(dep),
        not allowed?(allowed, file, dep),
        do: {file, dep, label}
  end

  defp allowed?(allowed, file, dep) do
    case Map.get(allowed, file) do
      {deps, _reason} -> Enum.member?(deps, dep)
      nil -> false
    end
  end

  @doc false
  # The web files in `graph` that refer to `Slipdock.Repo`, beyond `allowed`.
  def repo_references(graph, allowed) do
    for {file, deps} <- graph,
        web?(file),
        Map.has_key?(deps, @repo),
        not Map.has_key?(allowed, file),
        do: {file, deps[@repo]}
  end

  @doc false
  # `text` is `mix xref graph --format cycles --label compile-connected`.
  def cycle_stats(text) do
    compile =
      ~r/^Cycle of length \d+ \((\d+) compile/m
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(fn [n] -> String.to_integer(n) end)

    %{cycles: length(compile), compile: Enum.sum(compile)}
  end

  @doc false
  def over_ceiling(stats, ceiling),
    do: for(key <- [:cycles, :compile], stats[key] > ceiling[key], do: key)

  defp xref(args) do
    {out, 0} =
      System.cmd("mix", ["xref", "graph", "--no-compile" | args],
        cd: @root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: false
      )

    out
  end

  # ---- the checks, shown to fail -------------------------------------------

  describe "web_references/2" do
    test "a context referring to SlipdockWeb is caught, at any label" do
      graph = %{
        "lib/slipdock/boards.ex" => %{
          "lib/slipdock_web/router.ex" => "compile",
          "lib/slipdock/repo.ex" => "runtime"
        },
        "lib/slipdock.ex" => %{"lib/slipdock_web.ex" => "export"},
        "lib/slipdock_web/live/x.ex" => %{"lib/slipdock/boards.ex" => "runtime"}
      }

      assert web_references(graph, %{}) |> Enum.sort() == [
               {"lib/slipdock.ex", "lib/slipdock_web.ex", "export"},
               {"lib/slipdock/boards.ex", "lib/slipdock_web/router.ex", "compile"}
             ]
    end

    test "only the listed web file is allowed, not every one" do
      graph = %{
        "lib/slipdock/flow.ex" => %{
          "lib/slipdock_web/api_guide.ex" => "runtime",
          "lib/slipdock_web/router.ex" => "runtime"
        }
      }

      assert web_references(graph, @allowed) == [
               {"lib/slipdock/flow.ex", "lib/slipdock_web/router.ex", "runtime"}
             ]
    end
  end

  describe "repo_references/2" do
    test "a web file calling Slipdock.Repo is caught, at any label; contexts are not" do
      graph = %{
        "lib/slipdock_web/live/x_live.ex" => %{
          "lib/slipdock/repo.ex" => "runtime",
          "lib/slipdock/boards.ex" => "runtime"
        },
        "lib/slipdock_web.ex" => %{"lib/slipdock/repo.ex" => "compile"},
        "lib/slipdock_web/live/y_live.ex" => %{"lib/slipdock/boards.ex" => "runtime"},
        "lib/slipdock/boards.ex" => %{"lib/slipdock/repo.ex" => "runtime"}
      }

      assert repo_references(graph, %{}) |> Enum.sort() == [
               {"lib/slipdock_web.ex", "compile"},
               {"lib/slipdock_web/live/x_live.ex", "runtime"}
             ]
    end

    test "only the listed web file is allowed, not every one" do
      graph = %{
        "lib/slipdock_web/health.ex" => %{"lib/slipdock/repo.ex" => "runtime"},
        "lib/slipdock_web/router.ex" => %{"lib/slipdock/repo.ex" => "runtime"}
      }

      assert repo_references(graph, @repo_allowed) == [
               {"lib/slipdock_web/router.ex", "runtime"}
             ]
    end
  end

  describe "cycle_stats/1 and the ceiling" do
    @two_cycles """
    2 cycles found. Showing them in decreasing size:

    Cycle of length 12 (3 compile, 9 export):

        lib/a.ex (compile)

    Cycle of length 2 (1 compile, 1 export):

        lib/b.ex (compile)
    """

    test "counts the cycles and their compile files" do
      assert cycle_stats(@two_cycles) == %{cycles: 2, compile: 4}
      assert cycle_stats("No cycles found\n") == %{cycles: 0, compile: 0}
    end

    test "a new cycle, or a new compile edge in one, is over the ceiling" do
      assert over_ceiling(%{cycles: 2, compile: 12}, @cycle_ceiling) == [:cycles]
      assert over_ceiling(%{cycles: 1, compile: 13}, @cycle_ceiling) == [:compile]
      assert over_ceiling(%{cycles: 1, compile: 12}, @cycle_ceiling) == []
    end
  end

  # ---- the real graph --------------------------------------------------------

  describe "this codebase" do
    test "no context refers to the web layer, beyond the listed exceptions" do
      graph = Jason.decode!(xref(["--format", "json", "--output", "-"]))

      assert web_references(graph, @allowed) == [],
             "a context now refers to SlipdockWeb. Move the code across the boundary, " <>
               "or list it in @allowed with its reason (W-1945 §Boundaries)."

      # Every listed exception still exists, so the list can't go stale.
      for {file, {deps, _reason}} <- @allowed, dep <- deps do
        assert Map.has_key?(Map.get(graph, file, %{}), dep),
               "#{file} no longer refers to #{dep}: take it off @allowed"
      end
    end

    test "the web layer calls Slipdock.Repo only where listed" do
      graph = Jason.decode!(xref(["--format", "json", "--output", "-"]))

      assert repo_references(graph, @repo_allowed) == [],
             "a web file now calls Slipdock.Repo. Put the lookup in its context and call that " <>
               "(W-1945 §Boundaries), or list the file in @repo_allowed with its reason."

      # Every listed exception still calls it, so the list can't go stale.
      for {file, _reason} <- @repo_allowed do
        assert Map.has_key?(Map.get(graph, file, %{}), @repo),
               "#{file} no longer calls Slipdock.Repo: take it off @repo_allowed"
      end
    end

    test "compile-connected cycles stay at the recorded ceiling" do
      stats = cycle_stats(xref(["--format", "cycles", "--label", "compile-connected"]))

      assert over_ceiling(stats, @cycle_ceiling) == [],
             "compile-connected cycles went up: #{inspect(stats)} over #{inspect(@cycle_ceiling)}. " <>
               "Break the new compile-time dependency (`mix xref graph --format cycles " <>
               "--label compile-connected` shows it)."

      assert stats == @cycle_ceiling,
             "cycles went down to #{inspect(stats)}: lower @cycle_ceiling to match, so it stays there"
    end
  end
end
