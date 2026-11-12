defmodule Slipdock.Credo.DuplicatedCode do
  @moduledoc false

  alias Credo.Check.Design.DuplicatedCode, as: Upstream
  alias Credo.Execution

  use Credo.Check,
    id: "SD0003",
    run_on_all: true,
    base_priority: :higher,
    category: :design,
    param_defaults: [mass_threshold: 40, nodes_threshold: 2, excluded_macros: []],
    explanations: [
      check: """
      A block of code (of at least `mass_threshold` AST nodes) isn't copied
      from somewhere else in the codebase: credo's
      `Credo.Check.Design.DuplicatedCode`, with a message `credo diff` can
      match (handbook W-1950 §Credo's size checks).

      Credo's own message names every copy by its path and line. On the side
      `credo diff` compares against, those paths are in a temporary checkout,
      and a copy's line moves whenever its file is edited above it, so every
      duplicate already in the codebase would read as new. This one names the
      other copies by their path relative to the project, without lines,
      sorted, so `credo diff` flags only a new copy.
      """,
      params: [
        mass_threshold: "The smallest mass (AST nodes) a block needs to count.",
        nodes_threshold: "How many copies make a duplicate.",
        excluded_macros: "Macros whose blocks are never flagged."
      ]
    ]

  @doc false
  @impl true
  def run_on_all_source_files(exec, source_files, params) do
    mass_threshold = Params.get(params, :mass_threshold, __MODULE__)
    nodes_threshold = Params.get(params, :nodes_threshold, __MODULE__)
    excluded_macros = Params.get(params, :excluded_macros, __MODULE__)
    root = root(exec)
    by_name = Map.new(source_files, &{&1.filename, &1})

    for nodes <- duplicates(source_files, mass_threshold, nodes_threshold),
        # One issue a file, as credo's own check gives, at one of its copies there.
        this <- Enum.uniq_by(nodes, & &1.filename),
        Upstream.create_issue?(this.node, excluded_macros) do
      source_file = Map.fetch!(by_name, this.filename)
      issue_meta = IssueMeta.for(source_file, params)
      issue = issue_for(issue_meta, this, List.delete(nodes, this), root)
      Execution.ExecutionIssues.append(exec, source_file, issue)
    end

    :ok
  end

  # Each set of copies, as credo's own check finds them (its hashes are
  # public), in chunks of files at once as it does.
  defp duplicates(source_files, mass_threshold, nodes_threshold) do
    source_files
    |> Enum.chunk_every(30)
    |> Task.async_stream(&hashes(&1, mass_threshold), timeout: :infinity)
    |> Enum.reduce(%{}, fn {:ok, hashes}, acc ->
      Map.merge(acc, hashes, fn _hash, nodes1, nodes2 -> nodes1 ++ nodes2 end)
    end)
    |> Upstream.prune_hashes(mass_threshold)
    |> Upstream.add_masses()
    |> Map.values()
    |> Enum.filter(&(length(&1) >= nodes_threshold))
  end

  defp hashes(source_files, mass_threshold) do
    Enum.reduce(source_files, %{}, fn source_file, acc ->
      source_file
      |> SourceFile.ast()
      |> Upstream.calculate_hashes(acc, source_file.filename, mass_threshold)
    end)
  end

  defp issue_for(issue_meta, this, others, root) do
    elsewhere =
      others
      |> Enum.map(&relative(&1.filename, root))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join(", ")

    format_issue(issue_meta,
      message: "Duplicate code found in #{elsewhere} (mass: #{this.mass}).",
      line_no: Upstream.line_no_for(this.node),
      trigger: Issue.no_trigger(),
      severity: Credo.Severity.compute(1 + length(others), 1)
    )
  end

  # The directory credo was run in (`--working-dir`), the current one when it
  # was given none (in a test, say).
  defp root(%Execution{cli_options: %{path: path}}) when is_binary(path), do: Path.expand(path)
  defp root(_exec), do: File.cwd!()

  @doc false
  # A path as the project names it: relative to the directory credo was run
  # in, which on `credo diff`'s other side is a temporary checkout.
  def relative(filename, root), do: Path.relative_to(filename, root)
end
