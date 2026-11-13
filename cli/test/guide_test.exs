defmodule SlipdockCLI.GuideTest do
  @moduledoc """
  `slipdock guide [section]` (#1960): the short guide by default, `all` the
  whole one, any other word one section, each asked of the server as
  `GET /api/guide?section=`. A key the server doesn't have prints its message
  (the list of keys) to stderr and exits non-zero; that ends in
  `System.halt/1`, so it runs in a separate `elixir` of its own here.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  @message ~s(no section "nope" in the guide; there are: intro, getting-in, wiki, short, all)

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-guide-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")

    on_exit(fn ->
      File.rm_rf!(home)

      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    %{home: home}
  end

  defp serve(status, body) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{status, json(body)}]))
  end

  defp json(term), do: term |> :json.encode() |> IO.iodata_to_binary()

  defp guide(args), do: capture_io(fn -> Boards.run("guide", args, []) end)

  test "no section asks for the short guide and prints it" do
    serve(200, %{section: "short", guide: "# Slipdock for agents\n\n## The rest of the guide"})

    assert guide([]) =~ "## The rest of the guide"
    assert_received {:request, "GET", "/api/guide?section=short", _}
  end

  test "all asks for the whole guide" do
    serve(200, %{guide: "# Slipdock for agents, all of it"})

    assert guide(["all"]) =~ "all of it"
    assert_received {:request, "GET", "/api/guide?section=all", _}
  end

  test "any other word is one section by its key, whatever its case" do
    serve(200, %{section: "wiki", guide: "## The wiki: writing things down"})

    assert guide(["Wiki"]) == "## The wiki: writing things down\n"
    assert_received {:request, "GET", "/api/guide?section=wiki", _}
  end

  test "--json prints the server's answer as it came" do
    serve(200, %{section: "wiki", guide: "## The wiki"})

    out = capture_io(fn -> Boards.run("guide", ["wiki"], json: true) end)
    assert out =~ ~s("section")
    assert out =~ ~s("wiki")
  end

  test "an unknown key prints the server's list of keys to stderr and exits 1", %{home: home} do
    url = FakeServer.start([{404, json(%{error: "unknown_section", message: @message})}])
    main = ~s|SlipdockCLI.main(["guide", "nope"])|

    # stdout thrown away, stderr kept: what comes back is the stderr alone.
    {stderr, status} =
      System.cmd(
        "sh",
        ["-c", ~s|elixir -pa "$EBIN" -e '#{main}' 2>&1 >/dev/null|],
        env: [
          {"EBIN", Mix.Project.compile_path()},
          {"HOME", home},
          {"SLIPDOCK_URL", url},
          {"SLIPDOCK_TOKEN", "test-token"}
        ]
      )

    assert status == 1
    assert stderr == "error: " <> @message <> "\n"
    assert_received {:request, "GET", "/api/guide?section=nope", _}
  end
end
