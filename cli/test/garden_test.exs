defmodule SlipdockCLI.GardenTest do
  @moduledoc "`slipdock garden`: what it sends, and what it shows (W-1807)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Garden}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-garden-#{System.unique_integer([:positive])}")
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

    :ok
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @stale %{
    "id" => 41,
    "check" => "stale_in_progress",
    "label" => "In progress, untouched",
    "state" => "open",
    "explanation" => "“Fix login” is in “Doing” with no activity since 2 Aug 2026",
    "cards" => [%{"id" => 7, "title" => "Fix login"}],
    "pages" => [],
    "proposal" => [%{"op" => "move", "card" => 7, "column" => 9}],
    "alternatives" => %{"snooze" => [%{"op" => "snooze", "card" => 7, "until" => "2026-10-25"}]},
    "needs_keep" => false
  }

  @dupe %{
    "id" => 42,
    "check" => "duplicate_cards",
    "label" => "Possible duplicates",
    "state" => "open",
    "explanation" => "“A” (#1) and “B” (#2) read alike (similarity 0.95)",
    "cards" => [%{"id" => 1, "title" => "A"}, %{"id" => 2, "title" => "B"}],
    "pages" => [],
    "proposal" => [
      %{"op" => "link_duplicate", "card" => "pick", "other" => "keep", "from" => [1, 2]},
      %{"op" => "archive", "card" => "pick", "from" => [1, 2]}
    ],
    "alternatives" => %{},
    "needs_keep" => true
  }

  defp listing(suggestions),
    do:
      JSON.encode!(%{
        "suggestions" => suggestions,
        "last_run" => %{"finished_at" => "2026-10-18T09:00:00Z"},
        "checks" => []
      })

  test "garden <board> lists the open suggestions, grouped, with their fixes" do
    serve([{200, listing([@stale, @dupe])}])
    out = capture_io(fn -> Garden.run("garden", ["ops"], []) end)

    assert_received {:request, "GET", "/api/boards/ops/garden", _}
    assert out =~ "In progress, untouched (1)"
    assert out =~ "#41 “Fix login” is in “Doing”"
    assert out =~ "→ move #7 to list 9"
    assert out =~ ~s(or --choice "snooze": snooze #7 until 2026-10-25)
    assert out =~ "Possible duplicates (1)"
    assert out =~ "link the one not kept as a duplicate of the one kept, archive the one not kept"
    assert out =~ "needs --keep: #1 or #2"
    assert out =~ "2 suggestion(s). Last looked over 2026-10-18T09:00."
  end

  test "--run posts a run, --check narrows it" do
    serve([{200, listing([])}])
    out = capture_io(fn -> Garden.run("garden", ["ops"], run: true, check: "epic_done") end)
    assert_received {:request, "POST", "/api/boards/ops/garden", body}
    assert JSON.decode!(body) == %{"check" => "epic_done"}
    assert out =~ "Nothing to tidy."
  end

  test "--check alone narrows the listing" do
    serve([{200, listing([])}])
    capture_io(fn -> Garden.run("garden", ["ops"], check: "orphan_pages") end)
    assert_received {:request, "GET", path, _}
    assert path =~ "check=orphan_pages"
  end

  test "apply sends keep and choice, for each id; dismiss and undo send nothing" do
    applied = JSON.encode!(%{"suggestion" => %{@dupe | "state" => "applied"}})
    serve([{200, applied}, {200, applied}, {200, applied}, {200, applied}])

    out = capture_io(fn -> Garden.run("garden", ["apply", "42", "#43"], keep: "1") end)
    assert_received {:request, "POST", "/api/garden/suggestions/42/apply", a}
    assert_received {:request, "POST", "/api/garden/suggestions/43/apply", _}
    assert JSON.decode!(a) == %{"keep" => "1"}
    assert out =~ "applied #42 [applied]"

    capture_io(fn -> Garden.run("garden", ["dismiss", "42"], []) end)
    assert_received {:request, "POST", "/api/garden/suggestions/42/dismiss", d}
    assert JSON.decode!(d) == %{}

    out = capture_io(fn -> Garden.run("garden", ["undo", "42"], []) end)
    assert_received {:request, "POST", "/api/garden/suggestions/42/undo", _}
    assert out =~ "undid #42"
  end

  test "settings shows the checks, and key=value changes one" do
    checks = %{
      "checks" => [
        %{"key" => "stale_in_progress", "enabled" => true, "settings" => %{"days" => 21}},
        %{"key" => "abandoned_backlog", "enabled" => false, "settings" => %{"days" => 180}}
      ]
    }

    serve([{200, JSON.encode!(checks)}, {200, JSON.encode!(checks)}])

    out = capture_io(fn -> Garden.run("garden", ["settings", "ops"], []) end)
    assert_received {:request, "GET", "/api/boards/ops/garden", _}
    assert out =~ ~r/on\s+stale_in_progress\s+days=21/
    assert out =~ ~r/off\s+abandoned_backlog\s+days=180/

    capture_io(fn ->
      Garden.run("garden", ["settings", "ops", "stale_in_progress", "days=21"], [])
    end)

    assert_received {:request, "PATCH", "/api/boards/ops/garden/settings", body}
    assert JSON.decode!(body) == %{"check" => "stale_in_progress", "days" => "21"}
  end

  test "the arguments" do
    assert Garden.suggestion_ids(["#4", "5"]) == {:ok, ["4", "5"]}
    assert {:error, "which suggestions?" <> _} = Garden.suggestion_ids([])
    assert {:error, "suggestion ids are numbers" <> _} = Garden.suggestion_ids(["x"])

    assert Garden.settings_args([]) == {:ok, nil}
    assert {:error, "say what to change" <> _} = Garden.settings_args(["epic_done"])
    assert {:error, "settings are key=value" <> _} = Garden.settings_args(["epic_done", "on"])

    assert Garden.settings_args(["epic_done", "enabled=false"]) ==
             {:ok, %{"check" => "epic_done", "enabled" => "false"}}
  end

  test "every step reads as words" do
    assert Garden.steps([
             %{"op" => "complete", "card" => 1},
             %{"op" => "flag", "card" => 1, "flag" => "review"},
             %{"op" => "comment", "card" => 1, "body" => "No next step"},
             %{"op" => "redate", "card" => 1, "due" => "2026-10-25"},
             %{"op" => "archive", "page" => 5},
             %{"op" => "rewrite_link", "page" => 5, "from" => "Runbok", "to" => "Runbook"},
             %{"op" => "file_page", "page" => 5, "folder" => 3}
           ]) ==
             "complete #1, flag #1 review, comment on #1: \"No next step\", re-date #1 to 2026-10-25, " <>
               "archive page 5, rewrite [[Runbok]] to [[Runbook]] on page 5, file page 5 into folder 3"
  end
end
