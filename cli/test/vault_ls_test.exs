defmodule SlipdockCLI.VaultLsTest do
  @moduledoc "`slipdock vault ls`: its boards, page count and the folders a vault is synced to."
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

  test "prints each board, the page count and every synced folder" do
    out =
      ls(
        ~s({"vaults":[{"id":1,"name":"Notes","pages":202,"boards":[
        {"id":5,"code":"kb","name":"Keystone","path":"/Keystone","archived":false},
        {"id":6,"code":"jobs","name":"Journal Desk","path":"/Journal Desk","archived":false}],
        "mirrors":[{"label":"slipdock CLI on laptop","last_synced_at":"2026-10-13T10:00:00Z"}]}]})
      )

    assert out =~ ~r{/Keystone\s+kb$}m
    assert out =~ ~r{/Journal Desk\s+jobs$}m
    assert out =~ "202 pages"
    assert out =~ "synced to slipdock CLI on laptop, last 2026-10-13T10:00:00Z"
  end

  test "with one page and no mirrors" do
    out = ls(~s({"vaults":[{"id":1,"name":"Notes","pages":1,"boards":[],"mirrors":[]}]}))
    assert out =~ "1 page"
    refute out =~ "1 pages"
    refute out =~ "synced to"
  end
end
