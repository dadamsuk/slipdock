defmodule SlipdockCLI.RenderBoardsTest do
  @moduledoc "`slipdock boards`: no VAULT column, every board you own being in your vault."
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  defp board(id, code, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "code" => code,
        "name" => String.upcase(code),
        "cards" => 0,
        "completed" => 0
      },
      extra
    )
  end

  test "lists boards with no VAULT column, whatever an older server says" do
    out = capture_io(fn -> Render.boards([board(2, "jobs", %{"inside_vault" => "Notes"})]) end)
    assert out =~ "JOBS"
    refute out =~ "VAULT"
    refute out =~ "in Notes"
  end
end
