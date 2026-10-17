defmodule Slipdock.ChunkedUploadsTest do
  @moduledoc """
  The staging behind a chunked `upload_file` (#1016): pieces add up on disk
  for the one user who started them, within the size cap, and an upload
  nobody finishes is swept.
  """
  use ExUnit.Case, async: true

  alias Slipdock.{Boards, ChunkedUploads}

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    :ok
  end

  defp staged(id, ext), do: Path.join([Boards.uploads_dir(), "staging", id <> ext])

  test "pieces add up to the file, for the user who started it" do
    {:ok, id, 3} = ChunkedUploads.start(1, %{"filename" => "a.txt"}, "abc", 100)
    assert {:ok, 6} = ChunkedUploads.append(1, id, "def", 3, 100)
    assert {:ok, 9} = ChunkedUploads.append(1, id, "ghi", nil, 100)

    assert {:ok, %{"filename" => "a.txt", "user_id" => 1}, path, 9} = ChunkedUploads.fetch(1, id)
    assert File.read!(path) == "abcdefghi"

    assert {:error, "unknown_upload" <> _} = ChunkedUploads.append(2, id, "x", nil, 100)
    assert {:error, "unknown_upload" <> _} = ChunkedUploads.fetch(2, id)
  end

  test "a piece already there is not added twice; different bytes at that offset are refused" do
    {:ok, id, 3} = ChunkedUploads.start(1, %{}, "abc", 100)
    {:ok, 6} = ChunkedUploads.append(1, id, "def", 3, 100)

    assert {:ok, 6} = ChunkedUploads.append(1, id, "def", 3, 100)
    assert {:ok, 6} = ChunkedUploads.append(1, id, "bc", 1, 100)
    assert {:error, "offset_mismatch" <> _} = ChunkedUploads.append(1, id, "xyz", 3, 100)
    # Running past the end of what has arrived isn't "already there" either.
    assert {:error, "offset_mismatch" <> _} = ChunkedUploads.append(1, id, "efg", 4, 100)
    assert {:error, "offset_mismatch" <> _} = ChunkedUploads.append(1, id, "g", 7, 100)

    {:ok, _, path, 6} = ChunkedUploads.fetch(1, id)
    assert File.read!(path) == "abcdef"
  end

  test "the assembled file can't pass the cap" do
    assert {:error, "too_big" <> _} = ChunkedUploads.start(1, %{}, "abcdef", 5)

    {:ok, id, 3} = ChunkedUploads.start(1, %{}, "abc", 5)
    assert {:error, "too_big" <> _} = ChunkedUploads.append(1, id, "def", 3, 5)
    assert {:ok, 5} = ChunkedUploads.append(1, id, "de", 3, 5)
  end

  test "one user can have only so many open at once; others aren't counted" do
    for _ <- 1..ChunkedUploads.max_open(), do: {:ok, _, _} = ChunkedUploads.start(1, %{}, "x", 9)

    assert {:error, "too_many_uploads" <> _} = ChunkedUploads.start(1, %{}, "x", 9)
    assert {:ok, _, 1} = ChunkedUploads.start(2, %{}, "x", 9)
  end

  test "discard removes the bytes, and an id that isn't a UUID touches nothing" do
    {:ok, id, 1} = ChunkedUploads.start(1, %{}, "x", 9)
    assert File.exists?(staged(id, ".part"))

    assert :ok = ChunkedUploads.discard(id)
    refute File.exists?(staged(id, ".part"))
    refute File.exists?(staged(id, ".json"))
    assert {:error, "unknown_upload" <> _} = ChunkedUploads.fetch(1, id)

    assert :ok = ChunkedUploads.discard("../../secret")
    assert {:error, "unknown_upload" <> _} = ChunkedUploads.fetch(1, "../" <> id)
  end

  test "an upload untouched for a day is swept; one still being added to stays" do
    {:ok, old, 1} = ChunkedUploads.start(1, %{}, "x", 9)
    {:ok, fresh, 1} = ChunkedUploads.start(1, %{}, "y", 9)

    long_ago = System.os_time(:second) - ChunkedUploads.max_age_seconds() - 60
    File.touch!(staged(old, ".json"), long_ago)
    File.touch!(staged(fresh, ".json"), long_ago)
    # Adding a piece counts as touching it.
    {:ok, 2} = ChunkedUploads.append(1, fresh, "z", 1, 9)

    assert ChunkedUploads.sweep() == 1
    refute File.exists?(staged(old, ".part"))
    assert {:ok, _, _, 2} = ChunkedUploads.fetch(1, fresh)
  end
end
