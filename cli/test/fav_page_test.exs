defmodule SlipdockCLI.FavPageTest do
  @moduledoc """
  `slipdock fav page <page>` and `slipdock unfav page <page>` (#1165). A page
  the server doesn't find ends in `System.halt/1`, so it is not run here; the
  server's own refusals are in SlipdockWeb.API.FavouritesTest.
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

  @page ~s({"page":{"id":42,"code":"W-31","title":"Retry policy","slug":"retry-policy"}})

  test "fav page resolves the page's code to its id and names what it favourited" do
    serve([
      {200, @page},
      {200,
       ~s({"favourites":[{"id":7,"kind":"page","resource_id":42,"name":"Retry policy","url":"/boards/3/wiki/retry-policy"}]})}
    ])

    out = capture_io(fn -> Boards.run("fav", ["page", "W-31"], []) end)

    assert_received {:request, "GET", "/api/pages/W-31", _}
    assert_received {:request, "POST", "/api/favourites", body}
    assert JSON.decode!(body) == %{"kind" => "page", "id" => 42}
    assert out =~ "favourited: page “Retry policy” — /boards/3/wiki/retry-policy"
  end

  test "a board/slug reference is passed on encoded" do
    serve([{200, @page}, {200, ~s({"favourites":[]})}])
    out = capture_io(fn -> Boards.run("fav", ["page", "slipdock/retry-policy"], []) end)

    assert_received {:request, "GET", "/api/pages/slipdock%2Fretry-policy", _}
    # Nothing came back naming it, so the confirmation falls back to the id.
    assert out =~ "favourited: page 42"
  end

  test "unfav page, and fav page --off, delete the page's favourite" do
    for {cmd, opts} <- [{"unfav", []}, {"fav", [off: true]}] do
      serve([{200, @page}, {200, ~s({"favourites":[]})}])
      out = capture_io(fn -> Boards.run(cmd, ["page", "W-31"], opts) end)

      assert_received {:request, "GET", "/api/pages/W-31", _}
      assert_received {:request, "DELETE", "/api/favourites/page/42", _}
      assert out =~ "no longer a favourite: page 42"
    end
  end
end
