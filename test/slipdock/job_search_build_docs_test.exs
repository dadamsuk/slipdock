defmodule Slipdock.JobSearchBuildDocsTest do
  @moduledoc """
  Runs the Python tests for the job-search Tool's build script
  (`packages/job-search/skills/job-search-generate/scripts/build_docs.py`,
  #1151) with the suite. The script is Python because it runs in the person's
  own shell, beside pandoc and LibreOffice; its tests are in
  `test/packages/job_search/build_docs_test.py` and skip whatever needs a tool
  this machine lacks.
  """
  use ExUnit.Case, async: true

  @tests Path.expand("../packages/job_search/build_docs_test.py", __DIR__)

  @tag timeout: 180_000
  test "the build script's own tests pass" do
    python = System.find_executable("python3")
    assert python, "python3 is needed to test the job-search build script"

    {out, status} = System.cmd(python, ["-I", @tests], stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ ~r/Ran \d+ tests/
  end
end
