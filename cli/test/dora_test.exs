defmodule SlipdockCLI.DoraTest do
  @moduledoc "`slipdock dora` (#1134): what it asks for, and how it prints on and off."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Deploy, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-dora-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "api-token")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  defp metrics(overrides) do
    Map.merge(
      %{
        "deployment_frequency" => %{"deploys" => 4, "per_week" => 1.0, "band" => "high"},
        "lead_time" => %{"p50" => 7200, "p85" => 90_000, "commits" => 9, "band" => "elite"},
        "change_failure_rate" => %{"rate" => 0.25, "failed" => 1, "deploys" => 4, "band" => "low"},
        "time_to_restore" => %{"p50" => 1800, "p85" => 1800, "restores" => 1, "band" => "elite"},
        "rework_rate" => %{"rate" => 0.0, "rework" => 0, "deploys" => 4},
        "idea_to_production" => %{"p50" => nil, "p85" => nil, "cards" => 0}
      },
      overrides
    )
  end

  test "prints each metric with its band and trend" do
    report =
      metrics(%{
        "environment" => "production",
        "environments" => ["production", "staging"],
        "days" => 30,
        "last_deploy" => %{
          "sha" => "abcdef123456",
          "tag" => "v2",
          "status" => "succeeded",
          "at" => "2026-10-19T10:00:00Z"
        },
        "previous" => metrics(%{"deployment_frequency" => %{"deploys" => 2}})
      })

    serve([{200, JSON.encode!(%{"enabled" => true, "dora" => report})}])
    out = capture_io(fn -> Deploy.run("dora", ["ship"], env: "production", days: 30) end)

    assert_received {:request, "GET", path, _}
    assert path =~ "/api/boards/ship/dora?"
    assert path =~ "environment=production"
    assert path =~ "days=30"

    assert out =~ "production · last 30 days"
    assert out =~ "also: staging"
    assert out =~ "last deploy: abcdef1 (v2) succeeded"
    assert out =~ ~r/deployment frequency\s+4 deploys · 1.0\/week · high\s+↑ from 2/
    assert out =~ ~r/lead time for changes\s+P50 2h · P85 1d over 9 commits · elite/
    assert out =~ "25% (1 of 4) · low"
    assert out =~ ~r/idea to production\s+- over 0 cards/
  end

  test "off: says so" do
    serve([
      {200,
       JSON.encode!(%{
         "enabled" => false,
         "dora" => nil,
         "message" => "delivery metrics are off for board ship"
       })}
    ])

    assert capture_io(fn -> Deploy.run("dora", ["ship"], []) end) ==
             "delivery metrics are off for board ship\n"

    assert_received {:request, "GET", "/api/boards/ship/dora", _}
  end
end
