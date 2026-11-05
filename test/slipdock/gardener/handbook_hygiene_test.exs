defmodule Slipdock.Gardener.HandbookHygieneTest do
  @moduledoc """
  The handbook hygiene checks together (#1790): in the gardener after the
  others, off on a board without a handbook, their settings in `garden
  settings` (the API the CLI reads), and a page comment named on the
  Tidy-up page.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Gardener, Handbook, Repo, Wiki}
  alias Slipdock.Wiki.Revision

  @keys ~w(long_section broad_covers rule_without_check stale_decision)

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  # A page with all four kinds of trouble, wherever it is filed.
  defp trouble(board, user, attrs) do
    body =
      "## Deploy\n\n" <>
        String.duplicate("word ", 400) <>
        "\n\n## Rules\n\n- **OPS-1** must · judgement · Old.\n- **OPS-1** must · judgement · Twice.\n" <>
        "\nSupersedes Decision: Use Postgres.\n"

    {:ok, page} =
      Wiki.create_page(
        board,
        Map.merge(
          %{
            "body" => body,
            "front_matter" => "---\nhandbook: operations\ncovers: [lib/**]\n---\n"
          },
          attrs
        ),
        user: user
      )

    at = DateTime.add(DateTime.utc_now(:second), -90 * 86_400)
    Repo.update_all(from(r in Revision, where: r.page_id == ^page.id), set: [inserted_at: at])
    page
  end

  test "they come last in the gardener, in order, each with its label" do
    assert Gardener.check_keys() |> Enum.take(-4) == @keys
    assert Gardener.check_keys() |> Enum.take(11) |> List.last() == "handbook_gap"

    assert Enum.map(@keys, &Gardener.label/1) == [
             "Long handbook sections",
             "Handbook pages that cover everything",
             "Rules without a test",
             "Decisions out of order"
           ]

    assert Enum.take(Gardener.suggestion_keys(), -5) == @keys ++ ["proposal"]
  end

  test "off on a board without a handbook, on with one", %{user: user} do
    board = board_fixture(%{}, owner: user)
    trouble(board, user, %{"title" => "Decision: Use Postgres"})
    trouble(board, user, %{"title" => "Ops notes"})

    {:ok, run} = Gardener.run(board, only: @keys)
    assert run.counts["total"] == 0

    {:ok, _} = Handbook.install(user, board)
    {:ok, folder} = Wiki.Folders.find(board, "/" <> Handbook.folder())
    {:ok, dec} = Wiki.Folders.find(board, "/" <> Handbook.decisions_folder())
    trouble(board, user, %{"title" => "More ops", "folder_id" => folder.id})
    trouble(board, user, %{"title" => "Decision: Use Postgres", "folder_id" => dec.id})
    trouble(board, user, %{"title" => "Use SQLite", "folder_id" => dec.id})

    {:ok, run} = Gardener.run(board, only: @keys)
    for key <- @keys, do: assert(run.counts[key] >= 1, "#{key} found nothing")
  end

  test "garden settings lists them with their defaults, and changes them", %{user: user} do
    board = board_fixture(%{}, owner: user)
    path = "/api/boards/#{board.code}/garden"

    assert %{"checks" => checks} = as(user) |> get(path) |> json_response(200)
    by_key = Map.new(checks, &{&1["key"], &1})

    assert %{"enabled" => true, "settings" => %{"chars" => 1500}} = by_key["long_section"]
    assert %{"enabled" => true, "settings" => s} = by_key["broad_covers"]
    assert s == %{}
    assert %{"enabled" => true, "settings" => %{"days" => 30}} = by_key["rule_without_check"]
    assert %{"enabled" => true, "label" => "Decisions out of order"} = by_key["stale_decision"]

    assert %{"checks" => checks} =
             as(user)
             |> patch(path <> "/settings", %{"check" => "long_section", "chars" => "2000"})
             |> json_response(200)

    assert %{"settings" => %{"chars" => 2000}} = Enum.find(checks, &(&1["key"] == "long_section"))

    assert %{"error" => "chars must be a whole number above 0"} =
             as(user)
             |> patch(path <> "/settings", %{"check" => "long_section", "chars" => "0"})
             |> json_response(422)

    assert %{"error" => "unknown setting: days"} =
             as(user)
             |> patch(path <> "/settings", %{"check" => "stale_decision", "days" => "3"})
             |> json_response(422)

    assert %{"checks" => checks} =
             as(user)
             |> patch(path <> "/settings", %{"check" => "broad_covers", "enabled" => "false"})
             |> json_response(200)

    assert %{"enabled" => false} = Enum.find(checks, &(&1["key"] == "broad_covers"))
  end

  test "the Tidy-up page names the Index a fix comments on", %{conn: conn, user: user} do
    board = board_fixture(%{}, owner: user)
    {:ok, _} = Handbook.install(user, board)
    {:ok, dec} = Wiki.Folders.find(board, "/" <> Handbook.decisions_folder())
    {:ok, _} = Wiki.create_page(board, %{"title" => "Use Redis", "folder_id" => dec.id})
    {:ok, _} = Gardener.run(board, only: ["stale_decision"])

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/tidy")
    assert has_element?(view, "#garden-stale_decision", "Decisions out of order")
    assert render(view) =~ "Comment on “Index”: “**Handbook upkeep.** “Use Redis” is filed"
  end
end
