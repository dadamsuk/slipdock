defmodule SlipdockCLI.ProfilesVerifyTest do
  @moduledoc """
  The verifier's spend (#1953) on the CLI: `claim-job` says the job's
  profile, `slipdock card` shows a defect review's findings (only an
  important one marked as failing) and a docs card accepted unverified,
  and the ledger line reads "not verified (docs)".
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Ledger, Render, Runners}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-spend-#{System.unique_integer([:positive])}")
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

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  defp card(extra) do
    Map.merge(
      %{
        "id" => 12,
        "title" => "Work",
        "board_id" => 3,
        "blocked_by" => [],
        "blocks" => [],
        "flags" => [],
        "tags" => [],
        "assignees" => [],
        "checklist" => %{"done" => 0, "total" => 0, "items" => []},
        "comments" => [],
        "urls" => [],
        "links" => [],
        "attachments" => []
      },
      extra
    )
  end

  test "claim-job prints the job's profile, and nothing with profiles off" do
    serve([
      {200,
       ~s({"job":{"id":12,"kind":"work","card_id":4,"card_url":"u","prompt":"Work","profile":"schema"},"lease_seconds":1200})}
    ])

    out = capture_io(fn -> Runners.run("claim-job", ["b"], pool: "loop") end)
    assert out =~ "profile: schema\n"

    serve([
      {200,
       ~s({"job":{"id":12,"kind":"work","card_id":4,"card_url":"u","prompt":"Work","profile":null},"lease_seconds":1200})}
    ])

    out = capture_io(fn -> Runners.run("claim-job", ["b"], pool: "loop") end)
    refute out =~ "profile:"
  end

  test "card shows each defect finding, failing only on an important one" do
    checks = %{
      "ask" => "ok",
      "defect_review" => [
        %{"severity" => "important", "file" => "lib/a.ex", "line" => 4, "note" => "drops a row"},
        %{"severity" => "nit", "file" => "lib/b.ex", "line" => 9},
        %{"severity" => "pre-existing", "file" => "lib/c.ex", "line" => 1}
      ]
    }

    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "verify_state" => "rejected",
            "verify_by" => %{"kind" => "agent", "agent" => "checker"},
            "verify_checks" => checks
          })
        )
      end)

    assert out =~ "✗ defect important: lib/a.ex:4; drops a row"
    assert out =~ "○ defect nit: lib/b.ex:9"
    assert out =~ "○ defect pre-existing: lib/c.ex:1"
  end

  test "card shows a docs card the server accepted unverified" do
    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "verify_state" => "accepted",
            "verify_by" => %{"kind" => "automation", "agent" => "the server"},
            "verify_checks" => %{
              "not_verified" => "docs",
              "suite" => %{"passed" => 3, "failed" => 0}
            }
          })
        )
      end)

    assert out =~ "○ not verified unverified: profile docs: no verify job runs for it"
    assert out =~ "✓ suite 3 passed, 0 failed"
  end

  test "a ledger line says not verified (docs) for a card no verifier checked" do
    line = %{
      "card" => %{"id" => 12, "title" => "Guide", "profile" => "docs"},
      "events" => ["accepted", "merged"],
      "accepted_by" => nil,
      "not_verified" => "docs"
    }

    assert Enum.at(Ledger.lines(line), 1) == "    not verified (docs)"
    assert Enum.at(Ledger.lines(Map.delete(line, "not_verified")), 1) == "    not verified"
  end
end
