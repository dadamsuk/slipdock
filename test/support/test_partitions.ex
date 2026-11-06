defmodule Slipdock.TestPartitions do
  @moduledoc """
  Splits the test files into CI's partitions by how long each took, rather
  than `mix test --partitions`' round robin over the sorted file list, which
  lands the slow files wherever the alphabet puts them and reshuffles them
  all whenever a file is added (#1858).

  The runtimes are in `test/support/partition_weights.tsv`, one line per file
  (`path<TAB>async|sync<TAB>milliseconds`), written by `Slipdock.TestTimings`
  in CI and merged by `test/support/test_partitions.exs weights`. A file
  costs a partition its milliseconds if it is sync, but a seventh of them if
  it is async: ExUnit runs the async modules side by side first (CI's
  4-core runners run 8 at once, `max_cases`), then the sync ones one at a
  time. Fitted over twenty CI partition runs, a partition's Test step took
  its sync total plus its async total over 7.2, within 8 seconds (#1858). A file the weights don't know yet goes where a stable
  hash of its path puts it, so it never moves the others.

  This file is also loaded on its own by `test/support/test_partitions.exs`
  (plain `elixir`, before anything is compiled), so it uses nothing but
  Elixir itself.
  """

  @weights "test/support/partition_weights.tsv"

  @typedoc "A file's runtime: whether it holds a sync module, and milliseconds."
  @type weight :: {sync? :: boolean, ms :: non_neg_integer}

  @doc "The weights file, relative to the repository root."
  def weights_path, do: @weights

  @doc "Every test file `mix test` would run, relative to `root`, sorted."
  def test_files(root \\ ".") do
    root
    |> Path.join("test/**/*_test.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  @doc "Parses a weights or timings file's text into `%{path => weight}`."
  @spec parse(String.t()) :: %{String.t() => weight}
  def parse(text) do
    for line <- String.split(text, "\n", trim: true),
        not String.starts_with?(line, "#"),
        [file, kind, ms] <- [String.split(line, "\t")],
        into: %{} do
      {file, {kind == "sync", String.to_integer(ms)}}
    end
  end

  @doc """
  Merges the timings of several runs into one set of weights: each file's
  milliseconds averaged over the runs that have it, sync if any run said so.
  Only files in `files` are kept, so a deleted test file drops out.
  """
  @spec merge([%{String.t() => weight}], [String.t()]) :: %{String.t() => weight}
  def merge(runs, files) do
    keep = MapSet.new(files)

    runs
    |> Enum.flat_map(&Map.to_list/1)
    |> Enum.filter(fn {file, _} -> MapSet.member?(keep, file) end)
    |> Enum.group_by(fn {file, _} -> file end, fn {_, weight} -> weight end)
    |> Map.new(fn {file, weights} ->
      sync? = Enum.any?(weights, &elem(&1, 0))
      ms = div(Enum.sum(Enum.map(weights, &elem(&1, 1))), length(weights))
      {file, {sync?, ms}}
    end)
  end

  @doc "The weights file's text for `weights`."
  def render(weights) do
    header =
      "# Test runtimes for CI's partitions (#1858): path, async|sync, milliseconds.\n" <>
        "# Regenerate with test/support/test_partitions.exs weights (see its header).\n"

    body =
      for {file, {sync?, ms}} <- Enum.sort(weights),
          do: "#{file}\t#{if sync?, do: "sync", else: "async"}\t#{ms}\n"

    IO.iodata_to_binary([header | body])
  end

  # How much async time costs one second of a CI partition (see the moduledoc).
  @async_parallelism 7

  # Partition 1 also checks formatting, runs the browser scripts' tests and
  # saves the build cache (.github/workflows/ci.yml): 16 to 20 s in CI. It
  # starts that much behind, so it gets that much less of the suite.
  @first_partition_extra_ms 15_000

  @doc "The milliseconds of other work partition 1 starts with."
  def first_partition_extra_ms, do: @first_partition_extra_ms

  @doc """
  Splits `files` into `count` partitions, a list of `count` sorted lists.
  Every file lands in exactly one.
  """
  @spec split([String.t()], %{String.t() => weight}, pos_integer) :: [[String.t()]]
  def split(files, weights, count) when is_integer(count) and count > 0 do
    {known, unknown} = Enum.split_with(files, &Map.has_key?(weights, &1))

    bins =
      known
      |> pack(weights, [@first_partition_extra_ms | List.duplicate(0, count - 1)])
      |> Enum.with_index()
      |> Map.new(fn {{_, files}, index} -> {index, files} end)

    unknown
    |> Enum.reduce(bins, fn file, bins ->
      Map.update!(bins, :erlang.phash2(file, count), &[file | &1])
    end)
    |> Enum.sort()
    |> Enum.map(fn {_, files} -> Enum.sort(files) end)
  end

  @doc "What a file costs a partition, in milliseconds of its wall time."
  @spec cost(weight) :: number
  def cost({true, ms}), do: ms
  def cost({false, ms}), do: ms / @async_parallelism

  @doc "The cost the weights give each partition of a split (unknown files 0)."
  def loads(partitions, weights) do
    for files <- partitions do
      files |> Enum.map(&cost(Map.get(weights, &1, {false, 0}))) |> Enum.sum()
    end
  end

  # Costliest first into the cheapest bin: within a few percent of the best
  # split for files this many and this small. Ties go by path, so the same
  # weights always give the same split.
  defp pack(files, weights, head_starts) do
    empty = for start <- head_starts, do: {start, []}

    files
    |> Enum.sort_by(fn file -> {-cost(weights[file]), file} end)
    |> Enum.reduce(empty, fn file, bins ->
      {{load, members}, index} =
        bins |> Enum.with_index() |> Enum.min_by(fn {{load, _}, i} -> {load, i} end)

      List.replace_at(bins, index, {load + cost(weights[file]), [file | members]})
    end)
  end
end
