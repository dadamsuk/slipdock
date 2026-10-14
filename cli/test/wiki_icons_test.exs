defmodule SlipdockCLI.WikiIconsTest do
  @moduledoc "`--icon` and `--color` on wiki folders and pages from the command line (#792)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-icons-#{System.unique_integer([:positive])}")
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

  @folder ~s({"folder":{"id":4,"path":"Ideas","slug":"ideas","icon":"star","color":"amber"}})

  defp run(command, args, opts, response) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, response}]))
    out = capture_io(fn -> Wiki.run(command, args, opts) end)
    assert_received {:request, method, path, body}
    {method, path, JSON.decode!(body), out}
  end

  test "folder new sends the icon and colour, and prints what it wears" do
    {method, path, body, out} =
      run("folder", ["new", "notes", "Ideas"], [icon: "star", color: "amber"], @folder)

    assert {method, path} == {"POST", "/api/boards/notes/folders"}
    assert body == %{"name" => "Ideas", "icon" => "star", "color" => "amber"}
    assert out =~ "Ideas"
    assert out =~ "star amber"
  end

  test "folder new without them sends neither" do
    {_method, _path, body, out} = run("folder", ["new", "notes", "Ideas"], [], @folder)
    assert body == %{"name" => "Ideas"}
    assert out =~ "id 4"
  end

  test "folder mv takes an icon or colour alone as something to change" do
    {method, path, body, _out} =
      run("folder", ["mv", "notes", "Ideas"], [icon: "bolt"], @folder)

    assert {method, path} == {"PATCH", "/api/boards/notes/folders/Ideas"}
    assert body == %{"icon" => "bolt"}
  end

  test "folder mv --no-icon --no-color clears both, said as blanks" do
    {_method, _path, body, out} =
      run(
        "folder",
        ["mv", "notes", "Ideas"],
        [no_icon: true, no_color: true],
        ~s({"folder":{"id":4,"path":"Ideas","slug":"ideas","icon":null,"color":null}})
      )

    assert body == %{"icon" => "", "color" => ""}
    refute out =~ "·  "
    refute out =~ "nil"
  end

  test "page edit --icon sets it, and --no-icon clears it" do
    page = ~s({"page":{"code":"W-3","title":"Launch","url":"/w"}})

    {method, path, body, _} = run("page", ["edit", "W-3"], [icon: "flag", color: "rose"], page)
    assert {method, path} == {"PATCH", "/api/pages/W-3"}
    assert body == %{"icon" => "flag", "color" => "rose"}

    {_, _, body, _} = run("page", ["edit", "W-3"], [no_icon: true], page)
    assert body == %{"icon" => nil}
  end
end
