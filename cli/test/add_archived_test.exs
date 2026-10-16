defmodule SlipdockCLI.AddArchivedTest do
  @moduledoc """
  `slipdock add --archived`: the card is made straight into the archive, the
  request says so only when asked, and the line printed back shows it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-add-#{System.unique_integer([:positive])}")
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

  defp card(archived_at) do
    JSON.encode!(%{
      card: %{
        id: 7,
        title: "Old notes",
        column: "Done",
        completed: false,
        priority: "none",
        flags: [],
        tags: [],
        checklist: %{total: 0, done: 0},
        comments: [],
        archived_at: archived_at
      }
    })
  end

  defp add(opts, archived_at) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{201, card(archived_at)}]))
    output = capture_io(fn -> Boards.run("add", ["b", "Old", "notes"], opts) end)
    assert_received {:request, "POST", "/api/boards/b/cards", body}
    {JSON.decode!(body), output}
  end

  test "--archived asks for it archived, and the reply is marked" do
    {body, output} = add([archived: true], "2026-10-16T12:00:00Z")
    assert body["archived"] == true
    assert body["title"] == "Old notes"
    assert output =~ "(archived)"
  end

  test "without it nothing about archiving is sent, and nothing is marked" do
    {body, output} = add([], nil)
    refute Map.has_key?(body, "archived")
    refute output =~ "archived"
  end
end
