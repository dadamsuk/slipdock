defmodule Slipdock.OCR.ExtractorCommandTest do
  @moduledoc """
  The extractor's own way of running a program (no `:run` function in its
  place): what it answers when `timeout` can't be started, and that anything
  else raised is not swallowed with it.
  """
  # Sync: one test points the VM's `PATH` at an empty directory, which every
  # process shares.
  use ExUnit.Case, async: false

  alias Slipdock.OCR.Extractor
  alias Slipdock.TestConfig

  setup do
    dir = Path.join(System.tmp_dir!(), "extractor-command-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "file.pdf")
    File.write!(path, "%PDF-1.4")
    %{dir: dir, path: path}
  end

  test "a machine without `timeout` gets an error, not a crash", %{dir: dir, path: path} do
    TestConfig.put(:ocr, [])
    before = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", before) end)
    System.put_env("PATH", dir)

    assert {:error, reason} = Extractor.extract(path, :pdf)
    assert reason =~ "the PDF can't be read"
  end

  test "an error that isn't the program failing to start is raised as it was", %{path: path} do
    # Nothing can write a tuple as the seconds, so the command is never built.
    TestConfig.put(:ocr, timeout_seconds: {:not, :seconds})

    assert_raise Protocol.UndefinedError, fn -> Extractor.extract(path, :pdf) end
  end
end
