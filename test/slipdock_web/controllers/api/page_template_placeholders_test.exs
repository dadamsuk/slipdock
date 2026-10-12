defmodule SlipdockWeb.API.PageTemplatePlaceholdersTest do
  @moduledoc "`POST /boards/:b/pages/from-template` fills Obsidian's {{title}}, {{date}} and {{time}} (W-103 R7.2)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki

  test "an Obsidian template works as it is", %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Notes", "code" => "tplapi"}, owner: user)

    {:ok, _} =
      Wiki.create_page(
        board,
        %{
          "title" => "Meeting",
          "template" => true,
          "body" => "# {{title}}\n{{date}} {{time:HH}}h"
        },
        user: user
      )

    page =
      conn
      |> put_req_header("accept", "application/json")
      |> post("/api/boards/tplapi/pages/from-template", %{
        "template" => "Meeting",
        "title" => "Standup"
      })
      |> json_response(201)
      |> Map.fetch!("page")

    assert page["title"] == "Standup"
    assert page["body"] =~ ~r/\A# Standup\n\d{4}-\d{2}-\d{2} \d{2}h\z/
  end
end
