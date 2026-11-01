defmodule SlipdockCLI.HeaderLinksTest do
  @moduledoc """
  `slipdock header` (#1205): the boards and vaults pinned left of quick add.
  The usage refusals end in `System.halt/1`, so they are not run here; the
  server's own refusals are in SlipdockWeb.API.HeaderLinksTest.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    saved = Map.new(~w(SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.delete_env("KANBAN_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @two ~s({"header_links":[{"id":5,"icon":"star","board":{"id":3,"name":"Plan","code":"plan"}},{"id":6,"icon":"book-open","vault":{"id":7,"name":"Notes"}}],"icons":["star","book-open"]})

  test "header lists each link, its icon and where it goes, and the icons" do
    serve([{200, @two}])
    out = capture_io(fn -> Boards.run("header", [], []) end)

    assert_received {:request, "GET", "/api/header-links", _}
    assert out =~ ~r/5\s+star\s+Plan\s+plan\s+3/
    assert out =~ ~r/6\s+book-open\s+Your wiki\s+wiki/
    refute out =~ "Notes"
    assert out =~ "icons: star book-open"
  end

  test "header with nothing pinned says how to pin one" do
    serve([{200, ~s({"header_links":[],"icons":["star"]})}])
    out = capture_io(fn -> Boards.run("header", [], []) end)
    assert out =~ "nothing pinned"
    assert out =~ "icons: star"
  end

  test "header add board sends the board and the icon" do
    serve([
      {201,
       ~s({"header_link":{"id":9,"icon":"fire","board":{"id":3,"name":"Plan","code":"plan"}},"header_links":[]})}
    ])

    out = capture_io(fn -> Boards.run("header", ["add", "board", "plan"], icon: "fire") end)

    assert_received {:request, "POST", "/api/header-links", body}
    assert JSON.decode!(body) == %{"board" => "plan", "icon" => "fire"}
    assert out =~ "pinned Plan to the header as fire"
  end

  test "header add wiki pins your one wiki, which nothing names" do
    response =
      ~s({"header_link":{"id":9,"icon":"fire","vault":{"id":7,"name":"Notes"}},"header_links":[]})

    # The old `add vault <ref>` lands on the same wiki: there is only one.
    for args <- [["add", "wiki"], ["add", "vault", "Notes"]] do
      serve([{201, response}])
      out = capture_io(fn -> Boards.run("header", args, icon: "fire") end)

      assert_received {:request, "POST", "/api/header-links", body}
      assert JSON.decode!(body) == %{"wiki" => true, "icon" => "fire"}
      assert out =~ "pinned your wiki to the header as fire"
    end
  end

  test "header move and rm call the link by id" do
    serve([{200, @two}, {200, ~s({"header_links":[]})}])

    out = capture_io(fn -> Boards.run("header", ["move", "5", "right"], []) end)
    assert_received {:request, "PATCH", "/api/header-links/5", body}
    assert JSON.decode!(body) == %{"move" => "right"}
    assert out =~ "Plan"

    out = capture_io(fn -> Boards.run("header", ["rm", "5"], []) end)
    assert_received {:request, "DELETE", "/api/header-links/5", _}
    assert out =~ "header link 5 removed"
  end
end
