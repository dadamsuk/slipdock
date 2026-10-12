defmodule SlipdockCLI.PagePropsTest do
  @moduledoc "`slipdock page props`: read a page's front matter, replace it, or clear it."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-props-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp run(opts, response) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, response}]))

    err =
      capture_io(:stderr, fn ->
        send(self(), {:out, capture_io(fn -> Wiki.run("page", ["props", "W-31"], opts) end)})
      end)

    assert_received {:request, method, path, body}
    assert_received {:out, out}
    {method, path, body, out, err}
  end

  @page ~s({"page":{"code":"W-31","title":"Note","url":"/x","front_matter":"rating: 5\\n# mine"}})

  test "with nothing to set, prints the YAML bare" do
    {"GET", path, _, out, _} = run([], @page)
    assert path =~ "/pages/W-31"
    assert out =~ "rating: 5\n# mine"
  end

  test "says so when there is none" do
    {"GET", _, _, _, err} = run([], ~s({"page":{"code":"W-31","front_matter":null}}))
    assert err =~ "W-31 has no front matter"
  end

  test "--body replaces it" do
    {"PATCH", path, body, out, _} = run([body: "rating: 4"], @page)
    assert path =~ "/pages/W-31"
    assert body =~ ~s("front_matter":"rating: 4")
    assert out =~ "saved the properties of W-31"
  end

  test "--clear sends an empty one" do
    {"PATCH", _, body, _, _} = run([clear: true], @page)
    assert body =~ ~s("front_matter":"")
  end
end
