defmodule SlipdockCLI.VaultLsTest do
  @moduledoc "`slipdock vault ls`: each mapping's page count and the folders a vault is synced to."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Vaults}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-vaultls-#{System.unique_integer([:positive])}")
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

  defp ls(response) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, response}]))
    capture_io(fn -> Vaults.run("vault", ["ls"], []) end)
  end

  test "prints each mapping's pages and every synced folder" do
    out =
      ls(
        ~s({"vaults":[{"id":1,"name":"GMinds","mappings":[
        {"id":3,"path":"/","board":{"id":5,"code":"kb","name":"KnowledgeBase"},"folder":null,"pages":201},
        {"id":4,"path":"/Jobs","board":{"id":6,"code":"jobs","name":"Job Hunt"},"folder":null,"pages":1}],
        "mirrors":[{"label":"slipdock CLI on laptop","last_synced_at":"2026-10-13T10:00:00Z"}]}]})
      )

    assert out =~ ~r{/\s+→ KnowledgeBase wiki.*kb · 201 pages}
    assert out =~ ~r{/Jobs\s+→ Job Hunt wiki.*jobs · 1 page$}m
    assert out =~ "synced to slipdock CLI on laptop, last 2026-10-13T10:00:00Z"
  end

  test "an older server's reply, without counts or mirrors, still prints" do
    out =
      ls(
        ~s({"vaults":[{"id":1,"name":"GMinds","mappings":[
        {"id":3,"path":"/","board":{"id":5,"code":"kb","name":"KnowledgeBase"},"folder":null}]}]})
      )

    assert out =~ "KnowledgeBase wiki"
    refute out =~ "pages"
    refute out =~ "synced to"
  end
end
