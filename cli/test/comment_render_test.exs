defmodule SlipdockCLI.CommentRenderTest do
  @moduledoc """
  `card` names who wrote each comment, and shows one without an author (an
  old comment, or an older server) as it always did (#668).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  defp card(comments) do
    %{
      "id" => 12,
      "title" => "Talked about",
      "board_id" => 3,
      "blocked" => false,
      "blocked_by" => [],
      "blocks" => [],
      "flags" => [],
      "tags" => [],
      "assignees" => [],
      "checklist" => %{"done" => 0, "total" => 0, "items" => []},
      "comments" => comments,
      "attachments" => [],
      "urls" => [],
      "links" => []
    }
  end

  test "a comment's writer is named on its line" do
    out =
      capture_io(fn ->
        Render.card(
          card([
            %{
              "id" => 5,
              "body" => "Looks right",
              "inserted_at" => "2026-10-13T00:41:41Z",
              "author" => %{"id" => 2, "name" => "Ada", "email" => "ada@example.com"}
            }
          ])
        )
      end)

    assert out =~ ~r/2026-10-13T00:41:41Z Ada.*\(comment #5\)/
    assert out =~ "Looks right"
  end

  test "no author, or no author key at all, is just the time" do
    out =
      capture_io(fn ->
        Render.card(
          card([
            %{
              "id" => 6,
              "body" => "Old",
              "inserted_at" => "2026-01-01T00:00:00Z",
              "author" => nil
            },
            %{"id" => 7, "body" => "Older server", "inserted_at" => "2026-01-02T00:00:00Z"}
          ])
        )
      end)

    assert out =~ ~r/2026-01-01T00:00:00Z.{0,12}\(comment #6\)/
    assert out =~ ~r/2026-01-02T00:00:00Z.{0,12}\(comment #7\)/
  end
end
