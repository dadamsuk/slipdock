defmodule SlipdockCLI.ShipViaTest do
  @moduledoc """
  Ship by PR 1 (#1654) on the CLI: `set-board --ship-via`, `done --pr` and
  the pull request in `card`'s Evidence block.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-shipvia-#{System.unique_integer([:positive])}")
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

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  defp parse(argv) do
    {opts, _args, []} = OptionParser.parse(argv, strict: SlipdockCLI.switches())
    opts
  end

  @board ~s({"board":{"id":3,"name":"Docs"}})
  @card ~s({"card":{"id":12,"title":"Work","column":"To Do","board_id":3,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0,"items":[]}}})

  test "set-board --ship-via pull-request sends pull_request, and push sends push" do
    serve([{200, @board}, {200, @board}])

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--ship-via", "pull-request"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"ship_via" => "pull_request"}

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--ship-via", "push"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"ship_via" => "push"}
  end

  test "done --pr sends the pull request with the completion" do
    serve([{200, @card}])
    url = "https://github.com/acme/app/pull/7"

    capture_io(fn -> Boards.run("done", ["12"], parse(["--pr", url])) end)
    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"completed" => true, "evidence_pr" => url}
  end

  test "done --pr --evidence-commit sends the PR with the commit it merges at (#1976)" do
    serve([{200, @card}])
    url = "https://github.com/acme/app/pull/7"

    capture_io(fn ->
      Boards.run("done", ["12"], parse(["--pr", url, "--evidence-commit", "abc1234"]))
    end)

    assert_received {:request, "PATCH", "/api/cards/12", body}

    assert JSON.decode!(body) == %{
             "completed" => true,
             "evidence_pr" => url,
             "evidence_commit" => "abc1234"
           }
  end

  test "done --no-code sends why the card changes no code (#1938)" do
    serve([{200, @card}])

    capture_io(fn ->
      Boards.run("done", ["12"], parse(["--no-code", "a sweep", "--evidence", "filed two"]))
    end)

    assert_received {:request, "PATCH", "/api/cards/12", body}

    assert JSON.decode!(body) == %{
             "completed" => true,
             "evidence" => "filed two",
             "evidence_no_code" => "a sweep"
           }
  end

  test "card shows why it changes no code under Evidence (#1938)" do
    out = capture_io(fn -> Render.card(card(%{"evidence_no_code" => "a sweep"})) end)
    assert out =~ "Evidence"
    assert out =~ "no code: a sweep"
    refute capture_io(fn -> Render.card(card(%{})) end) =~ "no code"
  end

  test "card shows the pull request under Evidence, and nothing without one" do
    url = "https://github.com/acme/app/pull/7"
    out = capture_io(fn -> Render.card(card(%{"evidence_pr" => url})) end)
    assert out =~ "Evidence"
    assert out =~ "pull request: " <> url
    refute capture_io(fn -> Render.card(card(%{})) end) =~ "pull request"
  end

  test "card shows how it ships on a pull_request board (#1655), and nothing on a push board" do
    shipping = %{
      "via" => "pull_request",
      "branch" => "card-12",
      "instructions" => "This board ships by pull request: never push the default branch."
    }

    out = capture_io(fn -> Render.card(card(%{"shipping" => shipping})) end)
    assert out =~ "Ships by pull request"
    assert out =~ "branch card-12"
    assert out =~ "never push the default branch"
    refute capture_io(fn -> Render.card(card(%{})) end) =~ "Ships by pull request"
  end

  test "card says when the pull request is to be neutral, a security card's (#1794)" do
    shipping = %{
      "via" => "pull_request",
      "branch" => "card-12",
      "neutral" => true,
      "instructions" => "Describe the change neutrally."
    }

    out = capture_io(fn -> Render.card(card(%{"shipping" => shipping})) end)
    assert out =~ "branch card-12 · security: a neutral PR"
    assert out =~ "Describe the change neutrally."

    plain = Map.put(shipping, "neutral", false)
    refute capture_io(fn -> Render.card(card(%{"shipping" => plain})) end) =~ "neutral PR"
  end

  defp card(extra) do
    Map.merge(
      %{
        "id" => 12,
        "title" => "Work",
        "board_id" => 3,
        "blocked_by" => [],
        "blocks" => [],
        "flags" => [],
        "tags" => [],
        "assignees" => [],
        "checklist" => %{"done" => 0, "total" => 0, "items" => []},
        "comments" => [],
        "urls" => [],
        "links" => [],
        "attachments" => []
      },
      extra
    )
  end
end
