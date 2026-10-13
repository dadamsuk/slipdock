defmodule SlipdockCLI.RenderBoardsTest do
  @moduledoc "`slipdock boards`: the VAULT column for boards kept inside a vault (#757)."
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

  test "a board kept inside a vault is marked in it" do
    out =
      capture_io(fn ->
        Render.boards([board(1, "kb", %{"inside_vault" => "GMinds"}), board(2, "jobs")])
      end)

    assert out =~ "VAULT"
    assert out =~ "in GMinds"
  end

  test "with none, there is no VAULT column" do
    out = capture_io(fn -> Render.boards([board(2, "jobs", %{"inside_vault" => nil})]) end)
    refute out =~ "VAULT"
  end
end
