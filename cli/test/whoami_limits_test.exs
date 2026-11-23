defmodule SlipdockCLI.WhoamiLimitsTest do
  @moduledoc """
  What `whoami` says about limits (#3655): a free account's item allowance is
  stated, but the server's guardrails, which every account has, are stated
  only once they are close, so an unlimited account isn't shown a card limit.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Auth, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-whoami-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp status(used, limit),
    do: %{
      "used" => used,
      "limit" => limit,
      "remaining" => max(limit - used, 0),
      "limited?" => true
    }

  defp whoami(limits) do
    body = %{"user" => %{"email" => "someone@example.com", "name" => nil}, "limits" => limits}
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, JSON.encode!(body)}]))
    capture_io(fn -> Auth.run("whoami", [], []) end)
  end

  defp limits(free?, items, boards, storage) do
    %{
      "free" => free?,
      "items" => items,
      "boards" => boards,
      "storage" => storage,
      "trial" => %{"applies?" => false}
    }
  end

  test "an unlimited account sees its usage, not the guardrails as limits" do
    out =
      whoami(limits(false, status(4887, 250_000), status(12, 1000), status(1024, 10_737_418_240)))

    assert out =~ "items: 4887 used\n"
    assert out =~ "boards: 12 used\n"
    assert out =~ "files: 1.0 KB used\n"
    refute out =~ " of "
  end

  test "a guardrail within a fifth of its limit is stated, whoever the account is" do
    out = whoami(limits(false, status(210_000, 250_000), status(800, 1000), status(0, 1000)))

    assert out =~ "items: 210000 of 250000 used"
    assert out =~ "boards: 800 of 1000 used"
    assert out =~ "files: 0 bytes used\n"
  end

  test "a free account's item allowance is stated even when far from it" do
    out = whoami(limits(true, status(3, 100), status(1, 1000), status(0, 1000)))

    assert out =~ "items: 3 of 100 used"
    assert out =~ "boards: 1 used\n"
  end

  test "an item count with no limit at all prints nothing" do
    out =
      whoami(limits(false, %{"used" => 5, "limited?" => false}, status(1, 1000), status(0, 1000)))

    refute out =~ "items:"
  end
end
