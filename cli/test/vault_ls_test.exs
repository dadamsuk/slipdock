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
        ~s({"vaults":[{"id":1,"name":"Notes","mappings":[
        {"id":3,"path":"/","board":{"id":5,"code":"kb","name":"Keystone"},"folder":null,"pages":201},
        {"id":4,"path":"/Journal","board":{"id":6,"code":"jobs","name":"Journal Desk"},"folder":null,"pages":1}],
        "mirrors":[{"label":"slipdock CLI on laptop","last_synced_at":"2026-10-13T10:00:00Z"}]}]})
      )

    assert out =~ ~r{/\s+→ Keystone wiki.*kb · 201 pages}
    assert out =~ ~r{/Journal\s+→ Journal Desk wiki.*jobs · 1 page$}m
    assert out =~ "synced to slipdock CLI on laptop, last 2026-10-13T10:00:00Z"
  end

  test "an older server's reply, without counts or mirrors, still prints" do
    out =
      ls(~s({"vaults":[{"id":1,"name":"Notes","mappings":[
        {"id":3,"path":"/","board":{"id":5,"code":"kb","name":"Keystone"},"folder":null}]}]}))

    assert out =~ "Keystone wiki"
    refute out =~ "pages"
    refute out =~ "synced to"
  end

  test "warns about pages at a path another mapping owns" do
    out =
      ls(
        ~s({"vaults":[{"id":1,"name":"Notes","mappings":[],"mirrors":[],
        "overlaps":[{"path":"Journal/Acme.md","board":"Keystone","mapping":"/","under":"/Journal","owner":"Journal Desk"}]}]})
      )

    assert out =~
             "warning: 1 page(s) of Keystone sit under /Journal, which Journal Desk's mapping owns"
  end
end
