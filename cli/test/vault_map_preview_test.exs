defmodule SlipdockCLI.VaultMapPreviewTest do
  @moduledoc "`slipdock vault map|unmap --dry-run`: what a mapping would do, nothing changed."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Vaults}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-vaultmap-#{System.unique_integer([:positive])}")
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

  defp run(args, opts, response) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, response}]))
    out = capture_io(fn -> Vaults.run("vault", args, opts) end)
    assert_received {:request, method, path, body}
    {method, path, body, out}
  end

  test "map --dry-run sends dry_run and prints what arrives and what is taken over" do
    {method, path, body, out} =
      run(["map", "GMinds", "/Jobs"], [board: "jobs", dry_run: true], ~s({"dry_run":true,
        "preview":{"path":"/Jobs","arriving":{"count":12,"sample":["Jobs/Acme.md"]},
        "moving":{"count":1,"sample":[{"from":"Jobs/Old.md","to":"Jobs/Old.md"}]},
        "mirrors":["slipdock CLI on laptop"]}}))

    assert method == "POST"
    assert path =~ "/vaults/GMinds/mappings"
    assert body =~ ~s("dry_run":true)
    assert out =~ "mapping /Jobs would — nothing is changed yet"
    assert out =~ "bring into the vault: 12"
    assert out =~ "Jobs/Acme.md"
    assert out =~ "… 11 more"
    assert out =~ "take over from another mapping: 1"
    assert out =~ "slipdock CLI on laptop"
  end

  test "unmap --dry-run asks with dry_run and lists what leaves" do
    {method, path, _body, out} =
      run(["unmap", "GMinds", "/Jobs"], [dry_run: true], ~s({"dry_run":true,
        "preview":{"path":"/Jobs","leaving":{"count":1,"sample":["Jobs/Acme.md"]},
        "moving":{"count":0,"sample":[]},"mirrors":[]}}))

    assert method == "DELETE"
    assert path =~ "dry_run=true"
    assert out =~ "take out of the vault (they stay on their board): 1"
    refute out =~ "move to another path"
    refute out =~ "synced folders"
  end

  test "split --dry-run says what moves and that synced files stay put" do
    {method, path, body, out} =
      run(["split", "GMinds", "/Jobs"], [board: "hunt", dry_run: true], ~s({"dry_run":true,
        "preview":{"path":"/Jobs","from":"KnowledgeBase","into":"Job Hunt","new_board":false,
        "unchanged":201,"renamed":[{"from":"Jobs/Plan.md","to":"Jobs/Plan-W-9.md"}],
        "joining":{"count":1,"sample":["Jobs/Old.md"]},
        "move":{"pages":201,"folders":3,"title_clashes":["Plan"],"left_behind":[],
          "tags":{"carried":[],"dropped":["kb"]},"fields":{"carried":[],"dropped":[]}}}}))

    assert method == "POST"
    assert path =~ "/vaults/GMinds/split"
    assert body =~ ~s("board":"hunt")
    assert body =~ ~s("dry_run":true)
    assert out =~ "/Jobs would move from KnowledgeBase to Job Hunt — nothing is changed yet"
    assert out =~ "201 page(s) and 3 folder(s) move"
    assert out =~ "201 file(s) unchanged"
    assert out =~ "renamed: Jobs/Plan.md → Jobs/Plan-W-9.md"
    assert out =~ "the board's own pages arrive: 1"
    assert out =~ "land beside pages of the same title: Plan"
    assert out =~ "drop tags: kb"
  end

  test "split --new-board sends new_board and reports the board made" do
    {_method, _path, body, out} =
      run(["split", "GMinds", "/Jobs"], [new_board: "Careers"], ~s({"result":{"path":"/Jobs",
        "unchanged":2,"renamed":[],"joining":{"count":0,"sample":[]},"move":{"pages":2,"folders":0}},
        "board":{"id":9,"code":"car","name":"Careers"},"vault":{}}))

    assert body =~ ~s("new_board":"Careers")
    assert out =~ "/Jobs now belongs to Careers (car), mapped in the vault"
  end
end
