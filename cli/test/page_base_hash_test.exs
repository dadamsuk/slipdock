defmodule SlipdockCLI.PageBaseHashTest do
  @moduledoc """
  `slipdock page edit --base-hash` after a refusal (#2818): the hash the
  conflict message prints is one the server takes back. It used to print the
  first 12 characters, which the server refused again with the same message.

  The fake here keeps a page and checks `base_hash` the way the server's
  `Slipdock.Wiki.check_base_hash/2` does: the whole hash, trimmed and
  lowercased, or a 409 carrying the page as it now is.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, HTTP, Util, Wiki}

  @old String.duplicate("0a", 32)
  @new "9cf12b5cf471" <> String.duplicate("e", 52)
  @later String.duplicate("7d", 32)

  setup do
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    home = Path.join(System.tmp_dir!(), "slipdock-basehash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.delete_env("KANBAN_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  # A page whose hash is `hash`: a save is refused unless its base_hash is
  # that whole hash; one that lands moves the page to `next`.
  defp page_at(hash, next) do
    state = Agent.start_link(fn -> hash end) |> elem(1)

    handler = fn "PATCH", "/api/pages/W-9", body ->
      answer(state, :json.decode(body)["base_hash"], next)
    end

    {state, handler}
  end

  defp answer(state, base, next) do
    current = Agent.get(state, & &1)

    if String.downcase(String.trim(base)) == current do
      Agent.update(state, fn _ -> next end)
      {200, encode(%{"page" => page(next)})}
    else
      {409, encode(%{"error" => "conflict", "current" => page(current)})}
    end
  end

  defp page(hash),
    do: %{"code" => "W-9", "title" => "Keys", "url" => "/w/9", "content_hash" => hash}

  defp encode(map), do: map |> :json.encode() |> IO.iodata_to_binary()

  defp save(base), do: HTTP.patch("/pages/W-9", %{"body" => "Mine.", "base_hash" => base})

  # The hash a refusal tells you to save with, read off its message.
  defp printed_hash(current) do
    [_, hash] = Regex.run(~r/--base-hash (\S+)/, Util.conflict_message(current))
    hash
  end

  # `page edit` as a person runs it: a refusal ends in `System.halt/1`, so it
  # runs in an `elixir` of its own. stdout is thrown away and stderr kept.
  defp page_edit(home, url, base) do
    main =
      ~s|SlipdockCLI.main(["page", "edit", "W-9", "--body", "Mine.", "--base-hash", "#{base}"])|

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
  end

  describe "a refused `page edit`, run as a command" do
    test "exits 1 and prints the whole hash on stderr, and that hash then saves" do
      {state, handler} = page_at(@new, @later)
      url = FakeServer.start([handler, handler])

      {stderr, status} = page_edit(System.get_env("HOME"), url, @old)

      assert status == 1
      assert stderr =~ "error: this page changed since you read it. Nothing was overwritten."
      assert stderr =~ ~s(it now reads "Keys", hash #{@new}\n)
      assert stderr =~ "save with --base-hash #{@new}\n"
      assert Agent.get(state, & &1) == @new

      # The hash is read off what the command printed, and passed back as is.
      [_, printed] = Regex.run(~r/--base-hash (\S+)/, stderr)
      assert {"", 0} = page_edit(System.get_env("HOME"), url, printed)
      assert Agent.get(state, & &1) == @later
    end

    test "the hash it printed is refused again, with the newer hash, when someone saved in between" do
      {state, handler} = page_at(@new, @later)
      url = FakeServer.start([handler, handler])

      {stderr, 1} = page_edit(System.get_env("HOME"), url, @old)
      [_, printed] = Regex.run(~r/--base-hash (\S+)/, stderr)

      # Someone else's save lands first.
      other = String.duplicate("3b", 32)
      Agent.update(state, fn _ -> other end)

      {again, status} = page_edit(System.get_env("HOME"), url, printed)

      assert status == 1
      assert again =~ "save with --base-hash #{other}\n"
      refute again =~ @new
      assert Agent.get(state, & &1) == other
    end

    test "the 12-character prefix it used to print is refused, with the whole hash" do
      {state, handler} = page_at(@new, @later)
      url = FakeServer.start([handler])

      {stderr, status} = page_edit(System.get_env("HOME"), url, String.slice(@new, 0, 12))

      assert status == 1
      assert stderr =~ "save with --base-hash #{@new}\n"
      assert Agent.get(state, & &1) == @new
    end
  end

  test "the hash the refusal prints saves, when nobody else saved in between" do
    {state, handler} = page_at(@new, @later)
    System.put_env("SLIPDOCK_URL", FakeServer.start([handler, handler]))

    assert {:error, 409, %{"current" => current}} = save(@old)
    hash = printed_hash(current)
    assert hash == @new

    out = capture_io(fn -> Wiki.run("page", ["edit", "W-9"], body: "Mine.", base_hash: hash) end)

    assert out =~ "saved"
    assert Agent.get(state, & &1) == @later
  end

  test "the hash the refusal printed is refused again when someone saved in between" do
    {state, handler} = page_at(@new, @later)
    System.put_env("SLIPDOCK_URL", FakeServer.start([handler, handler]))

    assert {:error, 409, %{"current" => current}} = save(@old)
    hash = printed_hash(current)

    # Someone else's save lands first.
    Agent.update(state, fn _ -> @later end)

    assert {:error, 409, %{"current" => now}} = save(hash)
    assert now["content_hash"] == @later
    assert printed_hash(now) == @later
  end

  test "a 12-character prefix, or a hash that is not the page's, is refused" do
    {state, handler} = page_at(@new, @later)
    System.put_env("SLIPDOCK_URL", FakeServer.start([handler, handler]))

    assert {:error, 409, _} = save(String.slice(@new, 0, 12))
    assert {:error, 409, _} = save(@old)
    assert Agent.get(state, & &1) == @new
  end

  test "the message names the page and prints the whole hash twice, never a prefix" do
    message = Util.conflict_message(page(@new))

    assert message =~ "this page changed since you read it. Nothing was overwritten."
    assert message =~ ~s(it now reads "Keys", hash #{@new}\n)
    assert message =~ "save with --base-hash #{@new}"
    refute message =~ ~r/hash 9cf12b5cf471(?!e)/
  end
end
