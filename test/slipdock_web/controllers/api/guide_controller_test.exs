defmodule SlipdockWeb.API.GuideControllerTest do
  @moduledoc """
  `GET /api/guide?section=`: the short guide, the whole one or one section,
  each the text `APIGuide` gives (the same cut `get_guide` serves), and the
  plain URL unchanged.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias SlipdockWeb.APIGuide

  @base "http://www.example.com"

  defp get_guide(conn, query), do: get(conn, "/api/guide" <> query)

  describe "without a token" do
    @describetag :anonymous

    test "no section and ?section=all are the whole guide, as before", %{conn: conn} do
      whole = APIGuide.markdown(base_url: @base)

      plain = get_guide(conn, "")
      assert response(plain, 200) == whole
      assert response_content_type(plain, :markdown) =~ "text/markdown"

      assert conn |> get_guide("?section=all") |> response(200) == whole
      assert conn |> get_guide("?section=") |> response(200) == whole
    end

    test "?section=short is the short guide, ending with the rest by name", %{conn: conn} do
      body = conn |> get_guide("?section=short") |> response(200)

      assert body == APIGuide.short(base_url: @base)
      assert body =~ "## The rest of the guide"
      assert body =~ "`GET /api/guide?section=<name>`"
      assert body =~ "- `wiki`"
      assert byte_size(body) < byte_size(APIGuide.markdown(base_url: @base))
    end

    test "?section=<key> is that section alone, whatever its case", %{conn: conn} do
      {:ok, wiki} = APIGuide.section("wiki", base_url: @base)

      assert conn |> get_guide("?section=wiki") |> response(200) == wiki
      assert conn |> get_guide("?section=Wiki") |> response(200) == wiki
      assert wiki =~ "## The wiki: writing things down"
      assert wiki =~ "recordings_folder"

      {:ok, mcp} = APIGuide.section("mcp", base_url: @base)
      assert conn |> get_guide("?section=mcp") |> response(200) == mcp
    end

    test "an unknown key is a 404 naming the keys, short and all", %{conn: conn} do
      body = conn |> get_guide("?section=nope") |> response(404)
      {:error, message} = APIGuide.section("nope", base_url: @base)

      assert body == message <> "\n"
      assert body =~ ~s(no section "nope" in the guide; there are: intro, getting-in)
      assert body =~ "wiki"
      assert body =~ "short, all"
    end

    test "?format=json carries the chosen section in guide", %{conn: conn} do
      body = conn |> get_guide("?section=wiki&format=json") |> json_response(200)
      {:ok, wiki} = APIGuide.section("wiki", base_url: @base)

      assert body["section"] == "wiki"
      assert body["guide"] == wiki
      assert body["vocabulary"]["priority_order"] == ~w(critical high medium low none)

      short = conn |> get_guide("?section=short&format=json") |> json_response(200)
      assert short["section"] == "short"
      assert short["guide"] == APIGuide.short(base_url: @base)

      whole = conn |> get_guide("?format=json") |> json_response(200)
      refute Map.has_key?(whole, "section")
      assert whole["guide"] == APIGuide.markdown(base_url: @base)
    end

    test "an Accept: application/json asks for the same", %{conn: conn} do
      body =
        conn
        |> put_req_header("accept", "application/json")
        |> get_guide("?section=epics")
        |> json_response(200)

      assert body["section"] == "epics"
      assert body["guide"] =~ "## Epics and subcards"
    end

    test "an unknown key in JSON is a 404 with the same message", %{conn: conn} do
      body = conn |> get_guide("?section=nope&format=json") |> json_response(404)

      assert body["error"] == "unknown_section"
      assert body["message"] =~ "short, all"
    end

    test "the guide documents the parameter where it describes itself", %{conn: conn} do
      body = conn |> get_guide("") |> response(200)

      [_, getting_in] = String.split(body, "## Getting in", parts: 2)
      assert getting_in =~ "#{@base}/api/guide?section=short"

      [_, endpoints] = String.split(body, "## Every endpoint", parts: 2)
      assert endpoints =~ "`GET /api/guide` takes `?section=short|all|<name>`"
    end
  end

  test "?section=short with a token still ends with the caller's boards",
       %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Launch"}, owner: user)

    body = conn |> get_guide("?section=short") |> response(200)

    # The short guide's last section is the reader's boards, then the list
    # of the sections left out.
    [guide, rest] = String.split(body, "## The rest of the guide", parts: 2)
    [_, boards] = String.split(guide, ~r/^## Your boards.*$/m, parts: 2)

    assert boards =~ "**##{board.id} Launch** (`#{board.code}`)"
    assert boards =~ "take work from: “To Do”"
    refute rest =~ "## "
  end
end
