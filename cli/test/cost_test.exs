defmodule SlipdockCLI.CostTest do
  @moduledoc """
  Cost on the card (#1954) in the CLI: `slipdock card`'s `Lead time:` and
  `Subcards:` fields and the ledger line's `spent`, with tokens left out
  (never 0) when the logs carried none.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Ledger, Render}

  @cost %{
    "model_seconds" => 750,
    "tool_seconds" => 2400,
    "jobs" => 2,
    "tokens" => %{"input" => 900_000, "output" => 300_000, "total" => 1_200_000}
  }

  @lead %{
    "seconds" => 7200,
    "ends" => "completed",
    "phases" => %{"build" => 3000, "ci" => 1200, "verify" => 600, "backlog" => 60},
    "cost" => %{"total" => @cost, "phases" => %{"build" => @cost}},
    "rollup" => nil
  }

  test "the lead time with its three longest phases and what was spent" do
    assert Render.lead_time_text(@lead) ==
             "2h0m (completed): build 50m, ci 20m, verify 10m · spent model 12m, tools 40m, 1.2M tokens"
  end

  test "tokens are left out when unknown, and spent is left off with no cost" do
    no_tokens = put_in(@lead, ["cost", "total"], Map.delete(@cost, "tokens"))
    assert Render.lead_time_text(no_tokens) =~ ~r/spent model 12m, tools 40m$/

    no_cost = %{@lead | "cost" => nil}
    assert Render.lead_time_text(no_cost) == "2h0m (completed): build 50m, ci 20m, verify 10m"
    assert Render.lead_time_text(%{@lead | "phases" => %{}, "cost" => nil}) == "2h0m (completed)"
    assert Render.lead_time_text(nil) == nil
    assert Ledger.spent(nil) == ""
    assert Ledger.spent(Map.delete(@cost, "tokens")) == " · spent model 12m, tools 40m"
  end

  test "the new tokens beside the total when cache reads make them differ (#3003)" do
    read = %{"total" => 5_759_134, "fresh" => 179_134, "cache_read" => 5_580_000}
    cost = %{@cost | "tokens" => read}

    assert Ledger.spent(cost) ==
             " · spent model 12m, tools 40m, 5.8M tokens (179.1k new)"

    assert Render.lead_time_text(put_in(@lead, ["cost", "total"], cost)) =~
             ~r/5\.8M tokens \(179\.1k new\)$/

    no_reads = put_in(@cost, ["tokens", "fresh"], 1_200_000)
    assert Ledger.spent(no_reads) == " · spent model 12m, tools 40m, 1.2M tokens"
  end

  test "an epic's rollup" do
    rollup = %{"subcards" => 3, "seconds" => 90_000, "cost" => %{"total" => @cost}}

    assert Render.rollup_text(%{@lead | "rollup" => rollup}) ==
             "3 added up, 1d1h · spent model 12m, tools 40m, 1.2M tokens"

    assert Render.rollup_text(%{@lead | "rollup" => %{rollup | "cost" => nil}}) ==
             "3 added up, 1d1h"

    assert Render.rollup_text(@lead) == nil
  end

  test "slipdock card prints the fields" do
    card = %{
      "id" => 7,
      "title" => "Priced",
      "board_id" => 1,
      "column" => "Done",
      "column_id" => 3,
      "position" => 0,
      "priority" => "none",
      "flags" => [],
      "tags" => [],
      "checklist" => %{"total" => 0, "done" => 0, "items" => []},
      "comments" => [],
      "lead_time" => %{@lead | "rollup" => %{"subcards" => 2, "seconds" => 60, "cost" => nil}}
    }

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ ~r/Lead time:\s+2h0m \(completed\): build 50m/
    assert out =~ ~r/Subcards:\s+2 added up, 1m/

    out = capture_io(fn -> Render.card(Map.delete(card, "lead_time")) end)
    refute out =~ "Lead time:"
  end

  test "the ledger's token count, short" do
    assert Ledger.tokens_text(950) == "950"
    assert Ledger.tokens_text(12_340) == "12.3k"
    assert Ledger.tokens_text(1_250_000) == "1.3M"
  end
end
