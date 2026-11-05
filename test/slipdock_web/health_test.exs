defmodule SlipdockWeb.HealthTest do
  # `/healthz`, which the deploy job polls after a restart and fails unless it
  # says `ok` on the commit it deployed.
  use SlipdockWeb.ConnCase, async: true

  alias SlipdockWeb.Health

  test "answers ok with the commit it was built from, and both clocks", %{conn: conn} do
    conn = get(conn, "/healthz")

    assert %{"status" => "ok", "sha" => sha, "scheduler" => scheduler, "monitor" => monitor} =
             json_response(conn, 200)

    assert sha == Slipdock.Build.sha()
    # Both clocks are manual in tests: reported, never stale.
    assert %{"stale" => false, "stale_after_seconds" => nil} = scheduler
    assert %{"stale" => false, "stale_after_seconds" => nil} = monitor
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "answers HEAD too, with no body", %{conn: conn} do
    conn = head(conn, "/healthz")
    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "sets no session cookie and is not behind sign-in", %{conn: conn} do
    conn = get(conn, "/healthz")
    assert conn.status == 200
    refute Map.has_key?(conn.resp_cookies, "_slipdock_key")
  end

  test "is 503 when the database does not answer, still naming the commit" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/healthz")
      |> Health.call(check: fn -> {:error, :timeout} end)

    assert conn.halted
    assert conn.status == 503

    assert Jason.decode!(conn.resp_body) == %{
             "status" => "unavailable",
             "sha" => Slipdock.Build.sha()
           }
  end

  test "any answer from the check but :ok is unavailable" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/healthz")
      |> Health.call(check: fn -> :anything_else end)

    assert conn.status == 503
  end

  test "leaves every other request alone" do
    for {method, path} <- [{:post, "/healthz"}, {:get, "/healthz/x"}, {:get, "/login"}] do
      conn = Phoenix.ConnTest.build_conn(method, path) |> Health.call([])
      refute conn.halted, "#{method} #{path} was answered by Health"
      assert conn.state == :unset
    end
  end

  describe "the pulse (#1765)" do
    @now ~U[2026-11-05 12:00:00Z]
    @intervals %{"scheduler" => 60, "monitor" => 300}

    defp pulse(last, uptime \\ 3_600) do
      Slipdock.Health.pulse(now: @now, uptime_seconds: uptime, last: last, intervals: @intervals)
    end

    defp ago(seconds), do: DateTime.add(@now, -seconds)

    defp healthz(pulse) do
      Phoenix.ConnTest.build_conn(:get, "/healthz")
      |> Health.call(check: fn -> :ok end, pulse: fn -> pulse end)
    end

    test "both ages are reported, and fresh clocks are ok" do
      p = pulse(%{"scheduler" => ago(30), "monitor" => ago(240)})

      assert p["scheduler"] == %{
               "last" => "2026-11-05T11:59:30Z",
               "age_seconds" => 30,
               "stale_after_seconds" => 300,
               "stale" => false
             }

      assert %{"age_seconds" => 240, "stale_after_seconds" => 900, "stale" => false} =
               p["monitor"]

      conn = healthz(p)
      assert conn.status == 200

      assert %{
               "status" => "ok",
               "scheduler" => %{"age_seconds" => 30},
               "monitor" => %{"age_seconds" => 240}
             } =
               Jason.decode!(conn.resp_body)
    end

    test "a stopped scheduler is unhealthy, with the reason" do
      p = pulse(%{"scheduler" => ago(720), "monitor" => ago(240)})
      assert p["scheduler"]["stale"]

      conn = healthz(p)
      assert conn.status == 503

      assert %{"status" => "stale", "reason" => "the scheduler last ran 12 minutes ago"} =
               Jason.decode!(conn.resp_body)
    end

    test "a monitor that stopped running, or never ran, is unhealthy" do
      conn = healthz(pulse(%{"scheduler" => ago(30), "monitor" => ago(1_200)}))
      assert conn.status == 503

      assert Jason.decode!(conn.resp_body)["reason"] ==
               "the health monitor last ran 20 minutes ago"

      conn = healthz(pulse(%{"scheduler" => ago(30), "monitor" => nil}))
      assert Jason.decode!(conn.resp_body)["reason"] == "the health monitor has never run"
    end

    test "both stale name both" do
      reason =
        Slipdock.Health.stale_reason(pulse(%{"scheduler" => ago(600), "monitor" => ago(1_800)}))

      assert reason ==
               "the scheduler last ran 10 minutes ago; the health monitor last ran 30 minutes ago"
    end

    test "a fresh boot is healthy within the grace period, so the deploy's wait passes" do
      # The old container's pulse, long stale, and nothing ticked yet.
      p = pulse(%{"scheduler" => ago(7_200), "monitor" => nil}, 30)
      refute p["scheduler"]["stale"] or p["monitor"]["stale"]
      assert healthz(p).status == 200

      # Past the grace period the same pulse is stale.
      assert healthz(pulse(%{"scheduler" => ago(7_200), "monitor" => nil}, 601)).status == 503
    end

    test "a manual clock is never stale" do
      p =
        Slipdock.Health.pulse(
          now: @now,
          uptime_seconds: 3_600,
          last: %{"scheduler" => nil, "monitor" => nil},
          intervals: %{"scheduler" => :manual, "monitor" => :manual}
        )

      assert Slipdock.Health.stale_reason(p) == nil
    end

    test "the pulse is read from the database by default" do
      Slipdock.Health.Pulse.beat("monitor", ago(60))
      assert Slipdock.Health.pulse(now: @now)["monitor"]["age_seconds"] == 60
    end
  end

  test "the database check is :ok against a working repo" do
    assert Health.database() == :ok
  end
end
