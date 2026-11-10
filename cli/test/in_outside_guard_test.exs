defmodule SlipdockCLI.InOutsideGuardTest do
  @moduledoc """
  The sites #2715 rewrote from `x in [...]` to `Enum.member?/2` (TEST-5):
  each list's members, and what falls outside it, so dropping a member or
  inverting a test fails here. A path that ends in `fail/1` or
  `System.halt/1` runs in a child VM, as `guide_test.exs` does.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Admin, Boards, FakeServer, Meld, Render, Tools, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-in-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    saved =
      Map.new(
        ~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN SLIPDOCK_MELD_PASSPHRASE),
        &{&1, System.get_env(&1)}
      )

    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN SLIPDOCK_MELD_PASSPHRASE), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.chmod(Path.join(home, "locked.json"), 0o600)
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  # Runs `code` in a child VM with the CLI on its path: {stdout and stderr, status}.
  # Nothing listens on port 9, so a request the code should not have made fails
  # with an error of its own rather than the one asserted.
  defp child(code, home) do
    System.cmd("elixir", ["-pa", Mix.Project.compile_path(), "-e", code],
      env: [
        {"HOME", home},
        {"SLIPDOCK_URL", "http://127.0.0.1:9"},
        {"SLIPDOCK_TOKEN", "test-token"}
      ],
      stderr_to_stdout: true
    )
  end

  defp main(argv, home), do: child("SlipdockCLI.main(#{inspect(argv)})", home)

  defp plain(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  describe "slipdock_cli.ex: a closed stdout exits quietly, nothing else does" do
    # A stand-in area whose command raises the error a write to a closed
    # stdout raises; the real dispatch and rescue in `main/1` handle it.
    defp raising(original) do
      """
      Code.compiler_options(ignore_module_conflict: true)
      defmodule SlipdockCLI.Now do
        def commands, do: ["explode"]
        def run(_, _, _), do: :erlang.error(#{inspect(original)})
      end
      SlipdockCLI.main(["explode"])
      IO.puts(:stderr, "not halted")
      """
    end

    for original <- [:terminated, :epipe, :ebadf] do
      test "#{original} halts 0", %{home: home} do
        assert {out, 0} = child(raising(unquote(original)), home)
        refute out =~ "not halted"
      end
    end

    test "any other error is raised again", %{home: home} do
      assert {out, status} = child(raising(:enoent), home)
      assert status != 0
      assert out =~ "enoent"
    end

    test "a command an area claims reaches it, and one none claims is bad usage", %{home: home} do
      assert {_, 0} = child(raising(:epipe), home)
      assert {out, status} = main(["no-such-command"], home)
      assert status != 0
      assert out =~ "no-such-command"
    end
  end

  describe "wiki.ex: import" do
    defp import_reply(source),
      do:
        JSON.encode!(%{
          "imported" => %{"cards" => 2, "pages" => 3, "source" => source, "boards" => []}
        })

    defp import_output(home, source) do
      path = Path.join(home, "export.json")
      File.write!(path, ~s({"boards":[]}))
      serve([{200, import_reply(source)}])
      capture_io(fn -> Wiki.run("import", [path], []) end)
    end

    test "a Slipdock export, or one with no source, says nothing of where it came from",
         %{home: home} do
      assert import_output(home, "slipdock") == "imported 2 card(s) and 3 page(s)\n"
      assert import_output(home, nil) == "imported 2 card(s) and 3 page(s)\n"
    end

    test "another source is named", %{home: home} do
      assert import_output(home, "trello") == "imported 2 card(s) and 3 page(s) from trello\n"
    end

    test "a file that can't be read says so", %{home: home} do
      path = Path.join(home, "locked.json")
      File.write!(path, "{}")
      File.chmod!(path, 0o000)

      assert {out, 1} = main(["import", path], home)
      assert out =~ "error: couldn't read #{path}: "
      refute out =~ "valid JSON"
    end

    test "a file that isn't JSON says so", %{home: home} do
      path = Path.join(home, "broken.json")
      File.write!(path, "{not json")

      assert {out, 1} = main(["import", path], home)
      assert out =~ "error: #{path} isn't valid JSON"
      refute out =~ "couldn't read"
    end

    test "JSON that isn't an object says so", %{home: home} do
      path = Path.join(home, "list.json")
      File.write!(path, "[1]")

      assert {out, 1} = main(["import", path], home)
      assert out =~ "error: #{path} does not hold a JSON object"
    end
  end

  describe "render.ex: priority facets" do
    defp search_line(priority) do
      result = %{
        "kind" => "card",
        "score" => 0.5,
        "matches" => [],
        "card" => %{
          "id" => 4,
          "title" => "Work",
          "board" => %{"name" => "Main"},
          "priority" => priority
        }
      }

      plain(capture_io(fn -> Render.search_results(%{"results" => [result]}, []) end))
    end

    test "a card's search line shows its priority unless it is nil or none" do
      refute search_line(nil) =~ "priority"
      refute search_line("none") =~ "priority"
      assert search_line("high") =~ "Main · priority high"
    end

    defp page_row(priority) do
      page = %{
        "code" => "W-1",
        "title" => "Notes",
        "priority" => priority,
        "updated_at" => "2026-11-01T00:00:00Z"
      }

      plain(capture_io(fn -> Render.pages([page]) end))
    end

    test "a page's facets show its priority unless it is nil or none" do
      refute page_row(nil) =~ "prio:"
      refute page_row("none") =~ "prio:"
      assert page_row("high") =~ "prio:high"
    end
  end

  describe "render.ex: card" do
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

    defp shown(extra), do: plain(capture_io(fn -> Render.card(card(extra)) end))

    test "Precision only when it is neither nil nor day" do
      refute shown(%{"date_precision" => nil}) =~ "Precision"
      refute shown(%{"date_precision" => "day"}) =~ "Precision"
      assert shown(%{"date_precision" => "month"}) =~ ~r/Precision:\s+month/
    end
  end

  describe "render.ex: small renderers" do
    test "a wait's answer leaves out an empty or missing choice text and answer" do
      assert Render.wait_answer(%{"choice_text" => "", "answer" => "ship it"}) == "ship it"
      assert Render.wait_answer(%{"choice_text" => nil, "answer" => "ship it"}) == "ship it"
      assert Render.wait_answer(%{"choice_text" => "Yes", "answer" => ""}) == "Yes"
      assert Render.wait_answer(%{"choice_text" => "Yes", "answer" => "now"}) == "Yes — now"
    end

    test "a field's details leave out a min or max that is false or missing" do
      fields = [
        %{
          "id" => 1,
          "name" => "Weight",
          "key" => "w",
          "kind" => "number",
          "config" => %{"min" => false, "max" => 10, "unit" => "kg"}
        },
        %{
          "id" => 2,
          "name" => "Size",
          "key" => "s",
          "kind" => "number",
          "config" => %{"min" => 1}
        }
      ]

      out = plain(capture_io(fn -> Render.fields(fields) end))
      assert out =~ ~r/\{w\}\s+number\s+max 10 kg/
      assert out =~ ~r/\{s\}\s+number\s+min 1\s*$/m
      refute out =~ "false"
    end

    defp folder_line(dress),
      do:
        plain(
          capture_io(fn ->
            Render.folder(Map.merge(%{"path" => "/Docs", "slug" => "docs", "id" => 4}, dress))
          end)
        )

    test "a folder's line leaves out an empty or missing icon and colour" do
      assert folder_line(%{"icon" => "", "color" => "red"}) == "/Docs  docs · id 4 · red\n"
      assert folder_line(%{"icon" => nil, "color" => ""}) == "/Docs  docs · id 4\n"
      assert folder_line(%{"icon" => "📁", "color" => "red"}) == "/Docs  docs · id 4 · 📁 red\n"
    end

    defp grid_heading(rows, cols) do
      grid = %{
        "rows" => [],
        "cols" => [],
        "cells" => %{},
        "shown" => 0,
        "hidden" => 0,
        "config" => %{
          "rows" => rows,
          "cols" => cols,
          "unit" => "week",
          "sort" => "position",
          "dir" => "asc"
        }
      }

      capture_io(fn -> Render.swimlanes(grid) end) |> plain() |> String.split("\n") |> hd()
    end

    test "a grid's unit shows only when an axis is a date" do
      for axis <- ~w(due_date schedule created updated) do
        assert grid_heading(axis, "column") =~ "cols: column by week"
        assert grid_heading("column", axis) =~ "cols: #{axis} by week"
      end

      refute grid_heading("column", "priority") =~ "by week"
    end
  end

  describe "boards.ex" do
    test "a rejection, or an audit's disagreement, with an empty or missing reason fails",
         %{home: home} do
      for argv <- [["verify", "5", "reject", "--reason", ""], ["verify", "5", "reject"]] do
        assert {out, 1} = main(argv, home)
        assert out =~ "error: a rejection needs its reason: --reason TEXT"
      end

      assert {out, 1} = main(["verify", "5", "disagree", "--reason", ""], home)
      assert out =~ "error: an audit's disagreement needs its reason: --reason TEXT"
    end

    defp repeat_body(ends) do
      serve([{200, ~s({"recurrence":{}})}])
      capture_io(fn -> Boards.run("repeat", ["12", "every", "week"], ends: ends, json: true) end)
      assert_received {:request, "PUT", "/api/cards/12/recurrence", body}
      JSON.decode!(body)
    end

    test "--ends never or none ends it never, a date ends it on that date" do
      assert %{"ends" => "never"} = body = repeat_body("none")
      refute Map.has_key?(body, "ends_on")
      assert %{"ends" => "never"} = repeat_body("never")
      assert %{"ends" => "on", "ends_on" => "2027-01-01"} = repeat_body("2027-01-01")
    end
  end

  describe "admin.ex" do
    @users ~s({"users":[{"id":7,"email":"sam@example.com"}]})

    defp admin_body(args) do
      serve([{200, @users}, {200, ~s({"user":{}})}])
      capture_io(fn -> Admin.run("admin", args, json: true) end)
      assert_received {:request, "PATCH", "/api/admin/users/7", body}
      JSON.decode!(body)
    end

    test "a limit of '', none or - clears it; a number sets it" do
      for clear <- ["", "none", "-"],
          do: assert(admin_body(["limit", "sam@example.com", clear]) == %{"card_limit" => nil})

      assert admin_body(["limit", "sam@example.com", "50"]) == %{"card_limit" => "50"}
    end

    test "paid '', none or - clears it; a date sets it" do
      for clear <- ["", "none", "-"],
          do: assert(admin_body(["paid", "sam@example.com", clear]) == %{"paid_until" => nil})

      assert admin_body(["paid", "sam@example.com", "2027-01-01"]) ==
               %{"paid_until" => "2027-01-01"}
    end

    defp setting(value) do
      serve([{200, ~s({"settings":{}})}])
      capture_io(fn -> Admin.run("admin", ["set", "trial_enabled=" <> value], json: true) end)
      assert_received {:request, "PATCH", "/api/admin/settings", body}
      JSON.decode!(body)["trial_enabled"]
    end

    test "a switch setting is true for 1, true, yes and on, false otherwise" do
      for on <- ~w(1 true yes on), do: assert(setting(on) == true)
      for off <- ~w(0 false no off), do: assert(setting(off) == false)
    end

    test "a sign-up's note is quoted only when there is one" do
      requests = [
        %{"email" => "a@example.com", "asked_at" => "2026-11-01", "note" => ""},
        %{"email" => "b@example.com", "asked_at" => "2026-11-02", "note" => nil},
        %{"email" => "c@example.com", "asked_at" => "2026-11-03", "note" => "hi"}
      ]

      serve([{200, JSON.encode!(%{"requests" => requests})}])
      out = capture_io(fn -> Admin.run("admin", ["signups"], []) end)

      assert out ==
               "a@example.com  asked 2026-11-01\n" <>
                 "b@example.com  asked 2026-11-02\n" <>
                 "c@example.com  asked 2026-11-03  “hi”\n"
    end
  end

  describe "meld.ex" do
    defp asked(input) do
      capture_io(:stderr, fn ->
        capture_io(input, fn -> send(self(), {:passphrase, Meld.passphrase([])}) end)
      end)

      assert_received {:passphrase, result}
      result
    end

    test "an empty or missing passphrase is refused; one typed is taken" do
      assert asked("\n") == {:error, "no passphrase given"}
      assert asked("") == {:error, "no passphrase given"}
      assert asked("open sesame\n") == {:ok, "open sesame"}
    end

    test "a hint goes in the block only when there is one" do
      refute Meld.encrypt_block("secret", "pw", "") =~ "💡"
      refute Meld.encrypt_block("secret", "pw", nil) =~ "💡"
      assert Meld.encrypt_block("secret", "pw", "the usual") =~ "💡the usual💡"
    end
  end

  describe "tools.ex" do
    test "tools file --out - prints the file, as no --out does", %{home: home} do
      File.cd!(home, fn ->
        serve([{200, "print(1)"}])

        out =
          capture_io(fn -> Tools.run("tools", ["file", "demo", "files/build.py"], out: "-") end)

        assert out == "print(1)"
        refute File.exists?(Path.join(home, "-"))
      end)
    end
  end
end
