# CI's test partitions, balanced by runtime (#1858). Plain `elixir`, run
# from the repository root; nothing needs compiling first.
#
#   elixir test/support/test_partitions.exs split 4 2
#     The test files partition 2 of 4 runs, one per line.
#
#   elixir test/support/test_partitions.exs weights DIR...
#     Rewrites test/support/partition_weights.tsv from the timings files
#     (test-timings-*.tsv) under the given directories, averaging each file
#     over the runs. To refresh it from the last few green CI runs:
#
#       for run in $(gh run list --workflow ci.yml --status success --limit 3 \
#                      --json databaseId --jq '.[].databaseId'); do
#         gh run download "$run" --pattern 'test-timings-*' --dir "/tmp/timings/$run"
#       done
#       elixir test/support/test_partitions.exs weights /tmp/timings
#
#     then commit the file. Refresh when a partition runs well over the others
#     (the test job's summary shows each one's time), not on every change.

Code.require_file("test_partitions.ex", __DIR__)

alias Slipdock.TestPartitions

case System.argv() do
  ["split", count, index] ->
    count = String.to_integer(count)
    index = String.to_integer(index)

    unless index in 1..count//1 do
      IO.puts(:stderr, "partition #{index} is not between 1 and #{count}")
      System.halt(2)
    end

    weights =
      case File.read(TestPartitions.weights_path()) do
        {:ok, text} -> TestPartitions.parse(text)
        {:error, _} -> %{}
      end

    files =
      TestPartitions.test_files()
      |> TestPartitions.split(weights, count)
      |> Enum.at(index - 1)

    # An empty list would make `mix test` run the whole suite.
    if files == [] do
      IO.puts(:stderr, "partition #{index} of #{count} has no test files")
      System.halt(1)
    end

    IO.puts(Enum.join(files, "\n"))

  ["weights" | [_ | _] = dirs] ->
    runs =
      for dir <- dirs,
          path <- Path.wildcard(Path.join(dir, "**/test-timings-*.tsv")),
          do: path |> File.read!() |> TestPartitions.parse()

    if runs == [] do
      IO.puts(:stderr, "no test-timings-*.tsv under #{Enum.join(dirs, ", ")}")
      System.halt(1)
    end

    weights = TestPartitions.merge(runs, TestPartitions.test_files())
    File.write!(TestPartitions.weights_path(), TestPartitions.render(weights))
    IO.puts("#{map_size(weights)} files written to #{TestPartitions.weights_path()}")

  _ ->
    IO.puts(:stderr, "usage: test_partitions.exs split COUNT INDEX | weights DIR...")
    System.halt(2)
end
