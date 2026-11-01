defmodule SlipdockCLI.PageTagsTest do
  @moduledoc """
  `page edit --tag`, `--set-tag` and `--no-tags`: a page's board tags (#1586).
  Giving `--no-tags` and `--set-tag` together ends in `System.halt/1`, so it is
  not run here.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  @page ~s({"page":{"code":"W-3","title":"Launch","url":"/w"}})

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-ptags-#{System.unique_integer([:positive])}")
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

  defp edit(opts) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, @page}]))
    capture_io(fn -> Wiki.run("page", ["edit", "W-3"], opts) end)
    assert_received {:request, "PATCH", "/api/pages/W-3", body}
    JSON.decode!(body)
  end

  test "--tag adds, and repeats" do
    assert edit(tag: "bug", tag: "ops") == %{"add_tags" => ~w(bug ops)}
  end

  test "--tag --off takes them off, and adds nothing" do
    assert edit(tag: "bug", off: true) == %{"remove_tags" => ~w(bug)}
  end

  test "--set-tag replaces the whole set" do
    assert edit(set_tag: "bug", set_tag: "ops") == %{"tags" => ~w(bug ops)}
  end

  test "--no-tags clears them: an empty list goes, not nothing" do
    assert edit(no_tags: true) == %{"tags" => []}
  end
end
