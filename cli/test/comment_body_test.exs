defmodule SlipdockCLI.CommentBodyTest do
  @moduledoc """
  A comment written as Markdown keeps its lines: `comment` takes the text as
  words, or `--body`, `--file` or `--body -` (stdin), and `job-progress
  --message -` pipes its note in the same way. A comment with no text at all
  ends in the usage error's `System.halt/1`, so it is not run here.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Runners}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-comment-#{System.unique_integer([:positive])}")
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

    %{home: home}
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @added ~s({"comment":{"id":42}})
  @markdown "**Picked up.**\n\n- one\n- two\n"

  defp posted do
    assert_received {:request, "POST", "/api/cards/7/comments", body}
    JSON.decode!(body)["body"]
  end

  test "words are joined into one line, as before" do
    serve([{201, @added}])
    out = capture_io(fn -> Boards.run("comment", ["7", "Picked", "up."], []) end)
    assert posted() == "Picked up."
    assert out =~ "added comment #42"
  end

  test "--body keeps the line breaks" do
    serve([{201, @added}])
    capture_io(fn -> Boards.run("comment", ["7"], body: @markdown) end)
    assert posted() == @markdown
  end

  test "--file reads the comment from a file", %{home: home} do
    path = Path.join(home, "c.md")
    File.write!(path, @markdown)
    serve([{201, @added}])
    capture_io(fn -> Boards.run("comment", ["7"], file: path) end)
    assert posted() == @markdown
  end

  test "--body - reads it from stdin" do
    serve([{201, @added}])
    capture_io([input: @markdown], fn -> Boards.run("comment", ["7"], body: "-") end)
    assert posted() == @markdown
  end

  test "words win over --body when both are given" do
    serve([{201, @added}])
    capture_io(fn -> Boards.run("comment", ["7", "short"], body: "long") end)
    assert posted() == "short"
  end

  describe "job-progress --message" do
    test "- reads the note from stdin, line breaks and all" do
      serve([{200, ~s({"status":"ok"})}])

      out =
        capture_io([input: @markdown], fn -> Runners.run("job-progress", ["9"], message: "-") end)

      assert_received {:request, "POST", "/api/jobs/9/progress", body}
      assert JSON.decode!(body) == %{"note" => @markdown}
      assert out =~ "ok"
    end

    test "empty stdin sends no note, only the renewal" do
      serve([{200, ~s({"status":"ok"})}])
      capture_io([input: ""], fn -> Runners.run("job-progress", ["9"], message: "-") end)
      assert_received {:request, "POST", "/api/jobs/9/progress", body}
      assert JSON.decode!(body) == %{}
    end

    test "a plain message is sent as given" do
      serve([{200, ~s({"status":"ok"})}])
      capture_io(fn -> Runners.run("job-progress", ["9"], message: "halfway") end)
      assert_received {:request, "POST", "/api/jobs/9/progress", body}
      assert JSON.decode!(body) == %{"note" => "halfway"}
    end
  end
end
