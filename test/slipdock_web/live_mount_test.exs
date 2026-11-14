defmodule SlipdockWeb.LiveMountTest do
  # The retry itself; flow_test.exs holds it through the help page too.
  use ExUnit.Case, async: true

  alias SlipdockWeb.LiveMount

  # Replies in turn, and counts the mounts.
  defp scripted(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    fn -> Agent.get_and_update(agent, fn [reply | rest] -> {reply, rest} end) end
  end

  @path "/boards/7/table?page=2"

  test "a refusal back to the same page, query and host aside, is tried once more" do
    refused = {:error, {:redirect, %{to: "http://www.example.com/boards/7/table?page=2&view=9"}}}

    assert LiveMount.retry_refused(@path, scripted([refused, {:ok, :view, "html"}])) ==
             {:ok, :view, "html"}

    assert LiveMount.retry_refused(@path, scripted([refused, refused, {:ok, :view, "html"}])) ==
             refused
  end

  test "a redirect to another page, or a mount that works, comes back as it came" do
    elsewhere = {:error, {:redirect, %{to: "/boards/7"}}}
    assert LiveMount.retry_refused(@path, scripted([elsewhere, {:ok, :v, "h"}])) == elsewhere
    assert LiveMount.retry_refused(@path, scripted([{:ok, :v, "h"}, elsewhere])) == {:ok, :v, "h"}
  end
end
