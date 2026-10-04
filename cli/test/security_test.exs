defmodule SlipdockCLI.SecurityTest do
  @moduledoc """
  A token goes only to the server that issued it, the files holding it are
  the owner's alone, and nothing the server says can drive the terminal.
  """
  use ExUnit.Case, async: false

  alias SlipdockCLI.{HTTP, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-test-#{System.unique_integer([:positive])}")
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

    %{dir: Path.join([home, ".config", "slipdock"])}
  end

  describe "tokens are bound to a server" do
    test "a token saved for one server is not sent to another" do
      System.put_env("SLIPDOCK_URL", "https://a.example")
      HTTP.save_token("tok-a")
      assert HTTP.token() == "tok-a"

      System.put_env("SLIPDOCK_URL", "https://evil.example")
      assert HTTP.token() == nil

      System.put_env("SLIPDOCK_URL", "https://a.example:443/")
      assert HTTP.token() == "tok-a"
    end

    test "the old single token file is bound to the saved url, once", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "url"), "https://a.example\n")
      File.write!(Path.join(dir, "token"), "old\n")

      System.put_env("SLIPDOCK_URL", "https://evil.example")
      assert HTTP.token() == nil

      System.delete_env("SLIPDOCK_URL")
      assert HTTP.token() == "old"

      # A different server written into the url file afterwards (another
      # install's install.sh, say) does not inherit it.
      File.write!(Path.join(dir, "url"), "https://evil.example\n")
      assert HTTP.token() == nil
    end

    test "logout forgets this server's token only" do
      System.put_env("SLIPDOCK_URL", "https://a.example")
      HTTP.save_token("tok-a")
      System.put_env("SLIPDOCK_URL", "https://b.example")
      HTTP.save_token("tok-b")
      HTTP.forget_token()
      assert HTTP.token() == nil
      System.put_env("SLIPDOCK_URL", "https://a.example")
      assert HTTP.token() == "tok-a"
    end
  end

  test "token and url files are 0600 in a 0700 folder", %{dir: dir} do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o775)
    System.put_env("SLIPDOCK_URL", "https://a.example")
    path = HTTP.save_token("tok")
    url = HTTP.save_url("https://a.example")

    for file <- [path, url, Path.join(dir, "token")],
        do: assert(File.stat!(file).mode |> Bitwise.band(0o777) == 0o600)

    for d <- [dir, Path.dirname(path)],
        do: assert(File.stat!(d).mode |> Bitwise.band(0o777) == 0o700)

    assert Path.wildcard(Path.join(dir, "**/*.tmp")) == []
  end

  describe "plain http" do
    test "is fine to somewhere local" do
      for url <-
            ~w(http://localhost:4000 http://127.0.0.1 http://10.1.2.3 http://172.20.0.1
               http://192.168.1.5 http://100.101.102.103:4000 http://box.tail1234.ts.net
               http://[::1]:4000 https://example.com),
          do: refute(HTTP.insecure?(url), url)
    end

    test "is not to the internet" do
      for url <- ~w(http://example.com http://8.8.8.8 http://172.32.0.1 http://100.128.0.1),
          do: assert(HTTP.insecure?(url), url)
    end
  end

  describe "scrub" do
    test "drops terminal controls but keeps newlines and tabs" do
      assert Render.scrub("a\e]52;c;ZXZpbA==\a b") == "a]52;c;ZXZpbA== b"
      assert Render.scrub("ok\e[2K\rFAKE") == "ok[2KFAKE"
      assert Render.scrub("one\ntwo\tthree") == "one\ntwo\tthree"
      assert Render.scrub("c1 \u009b31m") == "c1 31m"
      assert Render.scrub("café — ✓") == "café — ✓"
    end

    test "walks maps and lists, and survives invalid UTF-8" do
      assert Render.scrub(%{"t" => ["x\e[8my"], "n" => 3, "z" => nil}) ==
               %{"t" => ["x[8my"], "n" => 3, "z" => nil}

      assert is_binary(Render.scrub(<<0xFF, 27, ?a>>))
      assert String.valid?(Render.scrub(<<0xFF, 27, ?a>>))
    end
  end
end
