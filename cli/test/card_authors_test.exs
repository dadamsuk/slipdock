defmodule SlipdockCLI.CardAuthorsTest do
  @moduledoc """
  `slipdock card` names who created the card and who changed it last
  (#2028), and shows the time alone when the server recorded nobody.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  defp card(attrs) do
    Map.merge(
      %{
        "id" => 12,
        "title" => "Ship",
        "board_id" => 3,
        "priority" => "none",
        "blocked" => false,
        "blocked_by" => [],
        "blocks" => [],
        "flags" => [],
        "tags" => [],
        "assignees" => [],
        "checklist" => %{"done" => 0, "total" => 0, "items" => []},
        "comments" => [],
        "attachments" => [],
        "urls" => [],
        "links" => [],
        "inserted_at" => "2026-11-01T09:00:00Z",
        "updated_at" => "2026-11-07T10:00:00Z"
      },
      attrs
    )
  end

  test "both lines name who" do
    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "created_by" => %{"kind" => "person", "name" => "Robin", "user_id" => 1},
            "updated_by" => %{"kind" => "runner", "name" => "Dev server loop", "job_id" => 4}
          })
        )
      end)

    assert out =~ ~r/Created:\s+2026-11-01T09:00:00Z by Robin\n/
    assert out =~ ~r/Updated:\s+2026-11-07T10:00:00Z by Dev server loop\n/
  end

  test "nobody recorded is the time alone" do
    out =
      capture_io(fn ->
        Render.card(card(%{"created_by" => nil, "updated_by" => %{"name" => ""}}))
      end)

    assert out =~ ~r/Created:\s+2026-11-01T09:00:00Z\n/
    assert out =~ ~r/Updated:\s+2026-11-07T10:00:00Z\n/
    refute out =~ " by "
  end

  test "an older server, without the fields, is the time alone" do
    out = capture_io(fn -> Render.card(card(%{})) end)
    assert out =~ ~r/Created:\s+2026-11-01T09:00:00Z\n/
    refute out =~ " by "
  end
end
