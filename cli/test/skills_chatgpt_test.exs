defmodule SlipdockCLI.SkillsChatGPTTest do
  @moduledoc "`slipdock skills chatgpt`: saves the zips the server says exist, and only those."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Skills}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-chatgpt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    Enum.each(~w(SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "downloads each skill's zip into --dir, skipping one with none", %{home: home} do
    {:ok, {_, zip}} = :zip.create(~c"x.zip", [{~c"slipdock-work/SKILL.md", "hi"}], [:memory])

    listing =
      ~s({"skills":[{"name":"slipdock-work","chatgpt_zip":"/api/skills/slipdock-work/chatgpt.zip"},) <>
        ~s({"name":"slipdock-loop","chatgpt_zip":null}]})

    url = FakeServer.start([{200, listing}, {200, zip}])
    System.put_env("SLIPDOCK_URL", url)
    dir = Path.join(home, "out")

    out = capture_io(fn -> Skills.run("skills", ["chatgpt"], dir: dir) end)

    assert_received {:request, "GET", "/api/skills", _}
    assert_received {:request, "GET", "/api/skills/slipdock-work/chatgpt.zip", _}
    refute_received {:request, "GET", "/api/skills/slipdock-loop" <> _, _}

    assert File.read!(Path.join(dir, "slipdock-work.zip")) == zip
    refute File.exists?(Path.join(dir, "slipdock-loop.zip"))
    assert out =~ "saved 1 ChatGPT skill(s) into #{dir}"
    assert out =~ "#{url}/mcp"
  end

  test "saves nothing when the server offers no ChatGPT versions", %{home: home} do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, ~s({"skills":[{"name":"a"}]})}]))
    dir = Path.join(home, "out")

    out = capture_io(fn -> Skills.run("skills", ["chatgpt"], dir: dir) end)

    assert out =~ "saved 0 ChatGPT skill(s)"
    refute File.exists?(dir)
  end
end
