defmodule SlipdockCLI.QualityTest do
  @moduledoc """
  `slipdock quality <board>` (#1796): asks for the board's quality numbers,
  passes `--days` on, and prints first-time-right, rework by area, job
  outcomes per 100 and health; an empty window says so rather than printing
  zero rates.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-quality-#{System.unique_integer([:positive])}")
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

  defp verified(accepted, ftr, rate, rejections, per_card, extra \\ %{}) do
    Map.merge(
      %{
        "accepted" => accepted,
        "first_time_right" => ftr,
        "rate" => rate,
        "rejections" => rejections,
        "per_card" => per_card,
        "reopened" => 0,
        "in_rework" => 0
      },
      extra
    )
  end

  defp quality(v, opts) do
    %{
      "days" => opts[:days] || 30,
      "since" => "2026-10-07T12:00:00Z",
      "until" => "2026-11-06T12:00:00Z",
      "verified" => v,
      "previous" => opts[:previous] || verified(0, 0, nil, 0, nil),
      "areas" => opts[:areas] || [],
      "jobs" =>
        opts[:jobs] ||
          %{
            "jobs" => 0,
            "timeouts" => 0,
            "failed" => 0,
            "requeues" => 0,
            "gave_up" => 0,
            "per_100" => %{
              "timeouts" => nil,
              "failed" => nil,
              "requeues" => nil,
              "gave_up" => nil
            }
          },
      "health" => %{"incidents" => 3, "fixed" => 2, "flagged" => 1, "cleared" => 0, "open" => 0}
    }
  end

  defp serve(body),
    do:
      System.put_env(
        "SLIPDOCK_URL",
        FakeServer.start([{200, JSON.encode!(%{"board" => %{"id" => 3}, "quality" => body})}])
      )

  test "prints each number, the areas and the job rates, passing --days on" do
    serve(
      quality(verified(4, 3, 0.75, 2, 0.5, %{"reopened" => 1, "in_rework" => 2}),
        days: 7,
        previous: verified(2, 1, 0.5, 1, 0.5),
        areas: [
          %{
            "code" => "W-1948",
            "title" => "Data model",
            "cards" => 3,
            "rate" => 0.667,
            "rejections" => 2,
            "per_card" => 0.67
          },
          %{
            "code" => nil,
            "title" => "unmapped",
            "cards" => 1,
            "rate" => 1.0,
            "rejections" => 0,
            "per_card" => 0.0
          }
        ],
        jobs: %{
          "jobs" => 20,
          "timeouts" => 1,
          "failed" => 2,
          "requeues" => 1,
          "gave_up" => 0,
          "per_100" => %{"timeouts" => 5.0, "failed" => 10.0, "requeues" => 5.0, "gave_up" => 0.0}
        }
      )
    )

    out = capture_io(fn -> Boards.run("quality", ["ship"], days: 7) end)

    assert_received {:request, "GET", path, _}
    assert path =~ "/api/boards/ship/quality?days=7"

    assert out =~ "last 7 days"
    assert out =~ "first-time-right: 75% (3 of 4 accepted) · 50% the window before"
    assert out =~ "rework: 2 rejections, 0.5 per card · 1 reopened"
    assert out =~ "in rework now: 2 rejected, not yet accepted"
    assert out =~ ~r/W-1948 Data model\s+3\s+67%\s+2\s+0.67/
    assert out =~ ~r/unmapped\s+1\s+100%\s+0/

    assert out =~
             "jobs: 20 finished · per 100: 5.0 timeouts, 10.0 failed, 5.0 requeues, 0.0 give-ups"

    assert out =~ "health: 3 incidents · 2 fixed, 1 flagged, 0 cleared, 0 open"
  end

  test "an empty window says so; without --days it asks for the server's default" do
    serve(quality(verified(0, 0, nil, 0, nil), []))
    out = capture_io(fn -> Boards.run("quality", ["ship"], []) end)

    assert_received {:request, "GET", path, _}
    assert String.ends_with?(path, "/api/boards/ship/quality")
    assert out =~ "first-time-right: no cards accepted in the window"
    refute out =~ "rework:"
    refute out =~ "in rework now"
    refute out =~ "area"
    assert out =~ "jobs: none finished in the window"
  end

  test "--json prints the server's answer" do
    serve(quality(verified(1, 1, 1.0, 0, 0.0), []))
    out = capture_io(fn -> Boards.run("quality", ["ship"], json: true) end)
    assert %{"quality" => %{"verified" => %{"accepted" => 1}}} = JSON.decode!(out)
  end
end
