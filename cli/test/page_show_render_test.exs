defmodule SlipdockCLI.PageShowRenderTest do
  @moduledoc "`slipdock page show`'s header says when the page was created and updated (#790)."
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  defp page(extra) do
    Map.merge(
      %{
        "title" => "Runbook",
        "code" => "W-1",
        "slug" => "runbook",
        "board_id" => 3,
        "status" => "published",
        "content_hash" => "abcdef1234567890",
        "body" => "Do the thing."
      },
      extra
    )
  end

  test "the header carries both stamps" do
    out =
      capture_io(fn ->
        Render.page(
          page(%{
            "inserted_at" => "2026-01-02T03:04:05Z",
            "updated_at" => "2026-10-14T15:07:43Z"
          })
        )
      end)

    assert out =~ "created 2026-01-02 03:04 · updated 2026-10-14 15:07"
    assert out =~ "Do the thing."
  end

  test "a server that sends no created stamp leaves it blank rather than failing" do
    out = capture_io(fn -> Render.page(page(%{"updated_at" => "2026-10-14T15:07:43Z"})) end)

    assert out =~ "published · updated 2026-10-14 15:07 · hash"
    refute out =~ "created"
  end
end
