defmodule SlipdockCLI.PersonFieldTest do
  @moduledoc """
  A person field (#3614) from the command line: a card shows its people by
  name, a former member marked.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  defp plain(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  test "a card shows a person field's people by name, a former member marked" do
    card = %{
      "id" => 9,
      "title" => "Release",
      "column" => "To Do",
      "board_id" => 3,
      "priority" => "none",
      "blocked_by" => [],
      "blocks" => [],
      "flags" => [],
      "tags" => [],
      "assignees" => [],
      "checklist" => %{"done" => 0, "total" => 0, "items" => []},
      "comments" => [],
      "fields" => %{
        "reviewers" => [
          %{"id" => 1, "name" => "Ann", "email" => "ann@example.com"},
          %{"id" => 2, "name" => "Zed", "email" => "zed@example.com", "former" => true}
        ]
      }
    }

    out = card |> then(&capture_io(fn -> Render.card(&1) end)) |> plain()
    assert out =~ "reviewers=Ann, Zed (former member)"
  end
end
