defmodule SlipdockCLI.AgentHeaderTest do
  @moduledoc """
  The CLI says when an agent is driving it (`x-slipdock-agent`, and
  `x-slipdock-job` under a runner job), so the server files the agent's card
  moves as an agent's rather than as the person's whose token it uses.
  """
  use ExUnit.Case, async: false

  alias SlipdockCLI.{FakeServer, HTTP}

  @vars ~w(HOME CLAUDECODE SLIPDOCK_JOB_ID SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN)

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-agent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "tok")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    :ok
  end

  # What the server saw on one request.
  defp sent_headers do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, "{}"}]))
    assert {:ok, %{}} = HTTP.post("/cards/1/move", %{column: 2})
    assert_received {:headers, "POST", "/api/cards/1/move", headers}
    headers
  end

  test "under Claude Code it sends the agent header, and no job" do
    System.put_env("CLAUDECODE", "1")
    headers = sent_headers()

    assert headers["x-slipdock-client"] == "cli"
    assert headers["x-slipdock-agent"] == "1"
    refute Map.has_key?(headers, "x-slipdock-job")
    assert headers["authorization"] == "Bearer tok"
  end

  test "under a runner job it sends both, with the job's id" do
    System.put_env("SLIPDOCK_JOB_ID", "42")
    headers = sent_headers()

    assert headers["x-slipdock-agent"] == "1"
    assert headers["x-slipdock-job"] == "42"
  end

  test "with neither set it sends neither: a person at a shell" do
    headers = sent_headers()

    assert headers["x-slipdock-client"] == "cli"
    refute Map.has_key?(headers, "x-slipdock-agent")
    refute Map.has_key?(headers, "x-slipdock-job")
  end

  test "a blank variable counts as unset" do
    System.put_env("CLAUDECODE", "")
    System.put_env("SLIPDOCK_JOB_ID", "  ")
    assert HTTP.client_headers() == [{~c"x-slipdock-client", ~c"cli"}]
  end

  test "downloads say it too" do
    System.put_env("SLIPDOCK_JOB_ID", "7")
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, "data"}]))
    dest = Path.join(System.get_env("HOME"), "file.bin")

    assert :ok = HTTP.download("/attachments/9", dest)
    assert_received {:headers, "GET", "/api/attachments/9", headers}
    assert headers["x-slipdock-agent"] == "1"
    assert headers["x-slipdock-job"] == "7"
  end
end
