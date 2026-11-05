defmodule Slipdock.TestPartitions do
  @moduledoc """
  Splits the test files into CI's partitions by how long each took, rather
  than `mix test --partitions`' round robin over the sorted file list, which
  lands the slow files wherever the alphabet puts them and reshuffles them
  all whenever a file is added (#1858).

  The runtimes are in `test/support/partition_weights.tsv`, one line per file
  (`path<TAB>async|sync<TAB>milliseconds`), written by `Slipdock.TestTimings`
  in CI and merged by `test/support/test_partitions.exs weights`. Sync files
  and async files are balanced separately: ExUnit runs the async modules side
  by side first and the sync ones one at a time after, so a millisecond of
  each costs a partition differently, and balancing both evens the total
  whatever the ratio. A file the weights don't know yet goes where a stable
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

  @doc """
  Splits `files` into `count` partitions, a list of `count` sorted lists.
  Every file lands in exactly one.
  """
  @spec split([String.t()], %{String.t() => weight}, pos_integer) :: [[String.t()]]
  def split(files, weights, count) when is_integer(count) and count > 0 do
    {known, unknown} = Enum.split_with(files, &Map.has_key?(weights, &1))
    {sync, async} = Enum.split_with(known, fn file -> elem(weights[file], 0) end)

    # The partition with the most sync time takes the least async time.
    sync_bins = sync |> pack(weights, count) |> Enum.sort_by(&(-elem(&1, 0)))
    async_bins = async |> pack(weights, count) |> Enum.sort_by(&elem(&1, 0))

    bins =
      Enum.zip_with(sync_bins, async_bins, fn {_, a}, {_, b} -> a ++ b end)
      |> Enum.with_index()
      |> Map.new(fn {files, index} -> {index, files} end)

    unknown
    |> Enum.reduce(bins, fn file, bins ->
      Map.update!(bins, :erlang.phash2(file, count), &[file | &1])
    end)
    |> Enum.sort()
    |> Enum.map(fn {_, files} -> Enum.sort(files) end)
  end

  @doc "The total milliseconds the weights give each partition of a split."
  def loads(partitions, weights) do
    for files <- partitions do
      files |> Enum.map(&elem(Map.get(weights, &1, {false, 0}), 1)) |> Enum.sum()
    end
  end

  # Longest first into the lightest bin: within a few percent of the best
  # split for files this many and this small. Ties go by path, so the same
  # weights always give the same split.
  defp pack(files, weights, count) do
    empty = for _ <- 1..count, do: {0, []}

    files
    |> Enum.sort_by(fn file -> {-elem(weights[file], 1), file} end)
    |> Enum.reduce(empty, fn file, bins ->
      {{load, members}, index} =
        bins |> Enum.with_index() |> Enum.min_by(fn {{load, _}, i} -> {load, i} end)

      List.replace_at(bins, index, {load + elem(weights[file], 1), [file | members]})
    end)
  end
end
