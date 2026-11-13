defmodule Slipdock.RunnersDriftTest do
  @moduledoc """
  Skill and CLI drift on the runners list (#1795, W-2310 §Sweeps and static
  checks): a runner says on each claim what it has installed, the server
  compares it with what it serves, shows current, drifted and unknown in the
  API, the UI and the CLI's data, and keeps one alert while it drifts.
  """
  # The CLI escript the server serves is an application setting.
  use SlipdockWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Automations.Alert
  alias Slipdock.Runners.{Drift, Runner}

  @old String.duplicate("a", 64)

  setup %{user: user} do
    board = board_fixture(%{"name" => "Drift", "code" => unique_code()}, owner: user)
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})

    dir = Path.join(System.tmp_dir!(), "slipdock-drift-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    escript = Path.join(dir, "slipdock.escript")
    File.write!(escript, "#!/usr/bin/env escript\nthe CLI\n")
    # A release's: the escript signed beside it. The unsigned server's is
    # its own describe below (#2825).
    File.write!(escript <> ".sig", "-----BEGIN SSH SIGNATURE-----\n")
    saved = Application.get_env(:slipdock, :cli_escript)
    Application.put_env(:slipdock, :cli_escript, escript)

    # And the skills archive the release job signed beside it; the unsigned
    # server's is its own describe below (#2916).
    signed = Path.join(dir, "skills_signed")
    File.mkdir_p!(signed)
    File.write!(Path.join(signed, "slipdock-skills.tar.gz"), "the archive")

    File.write!(
      Path.join(signed, "slipdock-skills.tar.gz.sig"),
      "-----BEGIN SSH SIGNATURE-----\n"
    )

    saved_signed = Application.get_env(:slipdock, :skills_signed_dir)
    Application.put_env(:slipdock, :skills_signed_dir, signed)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:slipdock, :cli_escript, saved),
        else: Application.delete_env(:slipdock, :cli_escript)

      if saved_signed,
        do: Application.put_env(:slipdock, :skills_signed_dir, saved_signed),
        else: Application.delete_env(:slipdock, :skills_signed_dir)

      File.rm_rf!(dir)
    end)

    %{
      board: board,
      runner: runner,
      token: token,
      escript: escript,
      skills_sig: Slipdock.Skills.signed_path() <> ".sig"
    }
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # What a runner with the server's own copy of a skill says: the sum of
  # every file of it, and (a daemon from before #3006) of its SKILL.md alone.
  defp served(name), do: Drift.served_skills() |> Map.fetch!(name) |> hd()
  defp served_md(name), do: Drift.served_skills() |> Map.fetch!(name) |> List.last()

  # The files the server serves for a skill, as {path, contents}.
  defp served_files(name) do
    for file <- Slipdock.Skills.get(name).files do
      {file, Slipdock.DocsText.read!(Path.join([Slipdock.Skills.dir(), name, file]))}
    end
  end

  defp claim(ctx, headers) do
    headers
    |> Enum.reduce(build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> post("/api/runner/claim?wait=0")
  end

  defp alerts(board),
    do: Repo.all(from(a in Alert, where: a.board_id == ^board.id, order_by: a.id))

  describe "what the server serves" do
    test "each packaged skill: the sum of every file of it, then its SKILL.md's alone (#3006)" do
      skills = Drift.served_skills()
      assert Map.has_key?(skills, "slipdock")

      # A skill with reference files: each is in the sum, by path.
      files = served_files("slipdock-wiki")
      assert Enum.any?(files, fn {path, _} -> String.starts_with?(path, "references/") end)
      {"SKILL.md", text} = List.keyfind(files, "SKILL.md", 0)

      lines =
        for {path, body} <- Enum.sort(files), do: path <> <<0>> <> sha(body) <> "\n"

      assert skills["slipdock-wiki"] == [sha(Enum.join(lines)), sha(text)]
      assert served("slipdock-wiki") != served_md("slipdock-wiki")

      for {_name, sums} <- skills do
        assert [sum, md] = sums
        assert sum =~ ~r/\A[0-9a-f]{64}\z/ and md =~ ~r/\A[0-9a-f]{64}\z/
      end
    end

    test "a skill's sum is the daemon's: the same files give the same sum" do
      # The sums `daemon/internal/runner/drift_test.go` pins for these files.
      whole = [
        {"SKILL.md", "a skill\n"},
        {"references/api.md", "the api\n"},
        {"references/markup.md", "the markup\n"}
      ]

      sum = "7b8e3adc347d9f4ebe788382b9924ff5b882e9705e89cd1fb3e20d40433d7ab7"
      assert Drift.skill_sum(whole) == sum

      assert Drift.skill_sum([{"SKILL.md", "a skill\n"}]) ==
               "9a6d16f5221aff4e3b9730271e8ec803c48f8ce699256b2e332010dee8ede178"

      # In any order, and whatever the line endings.
      assert Drift.skill_sum(Enum.reverse(whole)) == sum

      assert Drift.skill_sum(
               Enum.map(whole, fn {p, t} -> {p, String.replace(t, "\n", "\r\n")} end)
             ) == sum

      # A dot file (an editor's, a desktop's) isn't the skill's, as in the daemon.
      assert Drift.skill_sum(whole ++ [{".DS_Store", "x"}, {"references/.api.md.swp", "x"}]) ==
               sum

      # A file's text, its name, one fewer or one more: each is another sum.
      assert Drift.skill_sum(
               List.keyreplace(whole, "references/api.md", 0, {"references/api.md", "old\n"})
             ) != sum

      assert Drift.skill_sum(
               List.keyreplace(whole, "references/api.md", 0, {"references/apis.md", "the api\n"})
             ) != sum

      assert Drift.skill_sum(List.keydelete(whole, "references/markup.md", 0)) != sum
      assert Drift.skill_sum(whole ++ [{"references/old.md", ""}]) != sum
    end

    test "the CLI escript's SHA-256, as /cli/SHA256SUMS publishes it; nil without one", ctx do
      assert Drift.served_cli() == sha(Slipdock.DocsText.read!(ctx.escript))

      body = build_conn() |> get("/cli/SHA256SUMS") |> response(200)
      assert body == Drift.served_cli() <> "  slipdock.escript\n"

      # A rebuilt escript is read again, not served from the cache.
      File.write!(ctx.escript, "#!/usr/bin/env escript\na newer CLI, longer\n")
      assert Drift.served_cli() == sha(Slipdock.DocsText.read!(ctx.escript))

      Application.put_env(:slipdock, :cli_escript, ctx.escript <> ".missing")
      assert Drift.served_cli() == nil
    end
  end

  describe "parsing what a runner says" do
    test "skills: name=sha pairs, slipdock names only, bad pairs dropped" do
      assert Drift.parse_skills(nil) == nil
      assert Drift.parse_skills("none") == %{}
      assert Drift.parse_skills("") == %{}

      assert Drift.parse_skills(
               "slipdock=#{String.upcase(@old)}, slipdock-loop=#{@old},other=#{@old},slipdock-wiki=short"
             ) == %{"slipdock" => @old, "slipdock-loop" => @old}
    end

    test "cli: a SHA-256 or none; anything else is not heard" do
      assert Drift.parse_cli(" #{String.upcase(@old)} ") == @old
      assert Drift.parse_cli("none") == "none"
      assert Drift.parse_cli("1.2.3") == nil
      assert Drift.parse_cli(nil) == nil
    end
  end

  describe "the states" do
    test "skills: unknown, current, or drifted with the names that differ" do
      served = %{"slipdock" => @old, "slipdock-loop" => String.duplicate("b", 64)}

      assert Drift.skills_state(%Runner{skills: nil}, served) == :unknown
      assert Drift.skills_state(%Runner{skills: %{}}, served) == :current
      assert Drift.skills_state(%Runner{skills: %{"slipdock" => @old}}, served) == :current

      # One the server doesn't serve isn't drift.
      assert Drift.skills_state(%Runner{skills: %{"slipdock-mine" => @old}}, served) == :current

      assert Drift.skills_state(
               %Runner{skills: %{"slipdock" => @old, "slipdock-loop" => @old}},
               served
             ) == {:drifted, ["slipdock-loop"]}
    end

    test "skills: any of the sums the server reads as current for a skill is current (#3006)" do
      md = String.duplicate("c", 64)
      served = %{"slipdock" => [@old, md], "slipdock-loop" => [String.duplicate("b", 64), md]}

      # Every file's sum, or (a daemon from before #3006) the SKILL.md's.
      assert Drift.skills_state(%Runner{skills: %{"slipdock" => @old}}, served) == :current
      assert Drift.skills_state(%Runner{skills: %{"slipdock" => md}}, served) == :current

      assert Drift.skills_state(
               %Runner{skills: %{"slipdock" => md, "slipdock-loop" => @old}},
               served
             ) == {:drifted, ["slipdock-loop"]}

      assert Drift.skills_state(
               %Runner{skills: %{"slipdock" => String.duplicate("d", 64)}},
               served,
               false
             ) == {:unsigned, ["slipdock"]}
    end

    test "cli: current, old, none, or unknown" do
      assert Drift.cli_state(%Runner{cli_sha: nil}, @old) == :unknown
      assert Drift.cli_state(%Runner{cli_sha: @old}, nil) == :unknown
      assert Drift.cli_state(%Runner{cli_sha: "none"}, @old) == :none
      assert Drift.cli_state(%Runner{cli_sha: @old}, @old) == :current
      assert Drift.cli_state(%Runner{cli_sha: String.duplicate("c", 64)}, @old) == :old
    end

    test "cli: unsigned when it differs from one served with no signature (#2825)" do
      other = String.duplicate("c", 64)
      assert Drift.cli_state(%Runner{cli_sha: other}, @old, false) == :unsigned
      assert Drift.cli_state(%Runner{cli_sha: other}, @old, true) == :old
      # The same CLI is current either way; nothing to compare is unknown.
      assert Drift.cli_state(%Runner{cli_sha: @old}, @old, false) == :current
      assert Drift.cli_state(%Runner{cli_sha: "none"}, @old, false) == :none
      assert Drift.cli_state(%Runner{cli_sha: other}, nil, false) == :unknown
      refute Drift.drifted?(%{skills: :current, cli: :unsigned})
      assert Drift.drifted?(%{skills: :current, cli: :old})
    end

    test "skills: unsigned with the names when they differ from an unsigned archive (#2916)" do
      served = %{"slipdock" => @old, "slipdock-loop" => String.duplicate("b", 64)}
      differs = %Runner{skills: %{"slipdock" => @old, "slipdock-loop" => @old}}

      assert Drift.skills_state(differs, served, false) == {:unsigned, ["slipdock-loop"]}
      assert Drift.skills_state(differs, served, true) == {:drifted, ["slipdock-loop"]}
      # The same skills are current either way; nothing said is unknown.
      assert Drift.skills_state(%Runner{skills: %{"slipdock" => @old}}, served, false) == :current
      assert Drift.skills_state(%Runner{skills: nil}, served, false) == :unknown
      refute Drift.drifted?(%{skills: {:unsigned, ["slipdock-loop"]}, cli: :current})
      assert Drift.drifted?(%{skills: {:drifted, ["slipdock-loop"]}, cli: :current})
    end

    test "describe" do
      assert Drift.describe({:drifted, ["slipdock-loop", "slipdock"]}) ==
               "drifted (slipdock-loop, slipdock)"

      assert Drift.describe(:current) == "current"
      assert Drift.describe(:old) == "old"
      assert Drift.describe(:unsigned) == "unsigned on server"

      assert Drift.describe({:unsigned, ["slipdock-loop", "slipdock"]}) ==
               "unsigned on server (slipdock-loop, slipdock)"
    end
  end

  describe "a claim" do
    test "stores what it says and the JSON shows current", ctx do
      conn =
        claim(ctx, [
          {"x-runner-skills", "slipdock-loop=#{served("slipdock-loop")}"},
          {"x-runner-cli", Drift.served_cli()}
        ])

      assert conn.status == 204
      runner = Repo.get!(Runner, ctx.runner.id)
      assert runner.skills == %{"slipdock-loop" => served("slipdock-loop")}
      assert runner.cli_sha == Drift.served_cli()

      assert SlipdockWeb.API.JSON.runner(runner).drift ==
               %{skills: "current", drifted_skills: [], cli: "current"}

      assert alerts(ctx.board) == []
    end

    test "a runner that says nothing reads as unknown, and raises nothing", ctx do
      assert claim(ctx, []).status == 204

      assert SlipdockWeb.API.JSON.runner(Repo.get!(Runner, ctx.runner.id)).drift ==
               %{skills: "unknown", drifted_skills: [], cli: "unknown"}

      assert alerts(ctx.board) == []
    end

    test "a reference file changed, missing or extra is drift, its SKILL.md current (#3006)",
         ctx do
      files = served_files("slipdock-wiki")
      {reference, text} = Enum.find(files, fn {path, _} -> path =~ ~r{\Areferences/} end)

      for {what, installed} <- [
            {"changed", List.keyreplace(files, reference, 0, {reference, text <> "older\n"})},
            {"missing", List.keydelete(files, reference, 0)},
            {"extra", files ++ [{"references/left-behind.md", "from an older release\n"}]}
          ] do
        # What the daemon says of that copy: the SKILL.md in it is the server's.
        assert List.keyfind(installed, "SKILL.md", 0) == List.keyfind(files, "SKILL.md", 0)
        sum = Drift.skill_sum(installed)

        assert claim(ctx, [{"x-runner-skills", "slipdock-wiki=#{sum}"}]).status == 204
        runner = Repo.get!(Runner, ctx.runner.id)

        assert SlipdockWeb.API.JSON.runner(runner).drift ==
                 %{skills: "drifted", drifted_skills: ["slipdock-wiki"], cli: "unknown"},
               "a reference #{what} should read as drifted"

        assert [alert] = alerts(ctx.board)
        assert alert.title =~ "skills drifted (slipdock-wiki)"

        # Every file as the server's again: current, and the alert goes.
        whole = "slipdock-wiki=#{Drift.skill_sum(files)}"
        assert claim(ctx, [{"x-runner-skills", whole}]).status == 204
        runner = Repo.get!(Runner, ctx.runner.id)
        assert SlipdockWeb.API.JSON.runner(runner).drift.skills == "current"
        assert alerts(ctx.board) == []
      end
    end

    test "a daemon from before #3006 (its sum is the SKILL.md's alone) isn't drifted by that",
         ctx do
      # Every skill it has, as that daemon sends them: none is a false alarm.
      header =
        Enum.map_join(Drift.served_skills(), ",", fn {name, _} -> "#{name}=#{served_md(name)}" end)

      assert served_md("slipdock-wiki") ==
               sha(List.keyfind(served_files("slipdock-wiki"), "SKILL.md", 0) |> elem(1))

      assert claim(ctx, [{"x-runner-skills", header}]).status == 204
      runner = Repo.get!(Runner, ctx.runner.id)

      assert SlipdockWeb.API.JSON.runner(runner).drift ==
               %{skills: "current", drifted_skills: [], cli: "unknown"}

      assert alerts(ctx.board) == []
      assert runner.drift_alert_id == nil

      # Its SKILL.md another than the server's is still drift, as it was.
      old =
        String.replace(
          header,
          "slipdock-wiki=#{served_md("slipdock-wiki")}",
          "slipdock-wiki=#{@old}"
        )

      assert claim(ctx, [{"x-runner-skills", old}]).status == 204

      assert SlipdockWeb.API.JSON.runner(Repo.get!(Runner, ctx.runner.id)).drift ==
               %{skills: "drifted", drifted_skills: ["slipdock-wiki"], cli: "unknown"}

      assert [_alert] = alerts(ctx.board)
    end

    test "drift raises one alert, kept while it lasts, cleared when current again", ctx do
      drifted = [{"x-runner-skills", "slipdock-loop=#{@old}"}, {"x-runner-cli", @old}]

      assert claim(ctx, drifted).status == 204
      runner = Repo.get!(Runner, ctx.runner.id)

      assert SlipdockWeb.API.JSON.runner(runner).drift ==
               %{skills: "drifted", drifted_skills: ["slipdock-loop"], cli: "old"}

      assert [alert] = alerts(ctx.board)
      assert runner.drift_alert_id == alert.id
      assert alert.severity == "warning"

      assert alert.title ==
               "Runner box has drifted from this server: skills drifted (slipdock-loop), CLI old"

      # not a doc: the alert's body, as the server sends it
      assert alert.body =~ "Run the install one-liner on its machine again"
      # The scripts that installed the skills themselves were retired (#2582).
      refute alert.body =~ "keeps itself current"

      # Claiming again, still drifted: the same one alert.
      assert claim(ctx, drifted).status == 204
      assert [%{id: id}] = alerts(ctx.board)
      assert id == alert.id

      # Current again: the alert goes.
      current = [
        {"x-runner-skills", "slipdock-loop=#{served("slipdock-loop")}"},
        {"x-runner-cli", Drift.served_cli()}
      ]

      assert claim(ctx, current).status == 204
      assert alerts(ctx.board) == []
      assert Repo.get!(Runner, ctx.runner.id).drift_alert_id == nil

      # And a new drift is a new alert.
      assert claim(ctx, [{"x-runner-cli", @old}]).status == 204
      assert [%{title: "Runner box has drifted from this server: CLI old"}] = alerts(ctx.board)
    end

    test "the server's own CLI changing makes a runner old, and the alert follows", ctx do
      current = [{"x-runner-cli", Drift.served_cli()}]
      assert claim(ctx, current).status == 204
      assert alerts(ctx.board) == []

      File.write!(ctx.escript, "#!/usr/bin/env escript\nthe next release's CLI\n")
      assert claim(ctx, current).status == 204
      assert [_] = alerts(ctx.board)
    end
  end

  describe "a server that serves its CLI unsigned (#2825)" do
    setup ctx do
      File.rm!(ctx.escript <> ".sig")
      :ok
    end

    test "says so: signed? follows the file beside the escript", ctx do
      refute Drift.served_cli_signed?()
      File.write!(ctx.escript <> ".sig", "sig")
      assert Drift.served_cli_signed?()
    end

    test "a runner whose CLI differs is unsigned, not old, and raises no alert", ctx do
      assert claim(ctx, [{"x-runner-cli", @old}]).status == 204
      runner = Repo.get!(Runner, ctx.runner.id)

      assert SlipdockWeb.API.JSON.runner(runner).drift ==
               %{skills: "unknown", drifted_skills: [], cli: "unsigned"}

      assert alerts(ctx.board) == []
      assert runner.drift_alert_id == nil
    end

    test "a deploy from main clears an old-CLI alert; the next signed release raises it", ctx do
      # A signed release is served, and the runner's CLI is old: the alert.
      File.write!(ctx.escript <> ".sig", "sig")
      assert claim(ctx, [{"x-runner-cli", @old}]).status == 204
      assert [%{title: "Runner box has drifted from this server: CLI old"}] = alerts(ctx.board)

      # A deploy from main: a new escript, no signature. Not the machine's.
      File.rm!(ctx.escript <> ".sig")
      File.write!(ctx.escript, "#!/usr/bin/env escript\nmain's CLI\n")
      assert claim(ctx, [{"x-runner-cli", @old}]).status == 204
      assert alerts(ctx.board) == []

      # Skills that drift still raise one, and its title leaves the CLI out.
      assert claim(ctx, [{"x-runner-skills", "slipdock-loop=#{@old}"}]).status == 204

      assert [%{title: "Runner box has drifted from this server: skills drifted (slipdock-loop)"}] =
               alerts(ctx.board)
    end

    test "the runners list badges it as the server's, not an old CLI", ctx do
      Drift.report(ctx.runner, nil, @old)
      conn = log_in_user(build_conn(), ctx.user)
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/automations")

      assert has_element?(view, "#runner-#{ctx.runner.id}-cli", "CLI unsigned on server")
      refute has_element?(view, "#runner-#{ctx.runner.id}-cli", "old CLI")

      view |> element("#show-runner-#{ctx.runner.id}") |> render_click()
      assert has_element?(view, "#runner-#{ctx.runner.id}-cli-state", "unsigned on server")
    end
  end

  describe "a server that serves its skills unsigned (#2916)" do
    setup ctx do
      File.rm!(ctx.skills_sig)
      :ok
    end

    test "says so: signed? needs the archive and the signature beside it", ctx do
      refute Drift.served_skills_signed?()
      File.write!(ctx.skills_sig, "sig")
      assert Drift.served_skills_signed?()

      File.rm!(Slipdock.Skills.signed_path())
      refute Drift.served_skills_signed?()
    end

    test "a runner whose skills differ is unsigned, not drifted, and raises no alert", ctx do
      assert claim(ctx, [{"x-runner-skills", "slipdock-loop=#{@old}"}]).status == 204
      runner = Repo.get!(Runner, ctx.runner.id)

      assert SlipdockWeb.API.JSON.runner(runner).drift ==
               %{skills: "unsigned", drifted_skills: ["slipdock-loop"], cli: "unknown"}

      assert alerts(ctx.board) == []
      assert runner.drift_alert_id == nil
    end

    test "a deploy from main clears a skills alert; the next signed release raises it", ctx do
      # A signed release is served, and the runner's skills differ: the alert.
      File.write!(ctx.skills_sig, "sig")
      drifted = [{"x-runner-skills", "slipdock-loop=#{@old}"}]
      assert claim(ctx, drifted).status == 204

      assert [%{title: "Runner box has drifted from this server: skills drifted (slipdock-loop)"}] =
               alerts(ctx.board)

      # A deploy from main: no signature. Not the machine's.
      File.rm!(ctx.skills_sig)
      assert claim(ctx, drifted).status == 204
      assert alerts(ctx.board) == []

      # An old CLI against a signed one still raises one, leaving the skills out.
      assert claim(ctx, [{"x-runner-cli", @old}]).status == 204
      assert [%{title: "Runner box has drifted from this server: CLI old"}] = alerts(ctx.board)
    end

    test "the probe's prompt says it, for the daemon to pass", ctx do
      runner = Drift.report(ctx.runner, "slipdock-loop=#{@old}", nil)

      prompt =
        Slipdock.Runners.Probe.prompt(%Slipdock.Runners.Job{runner_id: runner.id})

      assert prompt =~ "\nskills: unsigned on server (slipdock-loop)\n"
    end

    test "the runners list badges it as the server's, not drifted skills", ctx do
      Drift.report(ctx.runner, "slipdock-loop=#{@old}", nil)
      conn = log_in_user(build_conn(), ctx.user)
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/automations")

      assert has_element?(view, "#runner-#{ctx.runner.id}-skills", "skills unsigned on server")
      refute has_element?(view, "#runner-#{ctx.runner.id}-skills", "skills drifted")

      view |> element("#show-runner-#{ctx.runner.id}") |> render_click()

      assert has_element?(
               view,
               "#runner-#{ctx.runner.id}-skills-state",
               "unsigned on server (slipdock-loop)"
             )
    end

    test "GET /api/boards/:board/runners/:id carries it as drift.skills", ctx do
      Drift.report(ctx.runner, "slipdock=#{@old}", nil)
      {token, _} = Slipdock.Accounts.create_api_token(ctx.user, "owner")

      json =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/boards/#{ctx.board.id}/runners/#{ctx.runner.id}")
        |> json_response(200)

      assert json["runner"]["drift"] == %{
               "skills" => "unsigned",
               "drifted_skills" => ["slipdock"],
               "cli" => "unknown"
             }
    end
  end

  describe "the runners list" do
    test "shows skills drifted and old CLI, and the details say which", ctx do
      Drift.report(ctx.runner, "slipdock-loop=#{@old}", @old)
      conn = log_in_user(build_conn(), ctx.user)
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/automations")

      assert has_element?(view, "#runner-#{ctx.runner.id}-skills", "skills drifted")
      assert has_element?(view, "#runner-#{ctx.runner.id}-cli", "old CLI")

      view |> element("#show-runner-#{ctx.runner.id}") |> render_click()

      assert has_element?(
               view,
               "#runner-#{ctx.runner.id}-skills-state",
               "drifted (slipdock-loop)"
             )

      assert has_element?(view, "#runner-#{ctx.runner.id}-cli-state", "old")
    end

    test "a current runner has no drift badges; unknown says unknown", ctx do
      conn = log_in_user(build_conn(), ctx.user)
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/automations")
      refute has_element?(view, "#runner-#{ctx.runner.id}-skills")
      refute has_element?(view, "#runner-#{ctx.runner.id}-cli")

      view |> element("#show-runner-#{ctx.runner.id}") |> render_click()
      assert has_element?(view, "#runner-#{ctx.runner.id}-skills-state", "unknown")

      Drift.report(ctx.runner, "slipdock-loop=#{served("slipdock-loop")}", Drift.served_cli())
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/automations")
      refute has_element?(view, "#runner-#{ctx.runner.id}-skills")
      refute has_element?(view, "#runner-#{ctx.runner.id}-cli")
    end

    test "GET /api/boards/:board/runners/:id carries the drift", ctx do
      Drift.report(ctx.runner, "slipdock=#{@old}", "none")
      {token, _} = Slipdock.Accounts.create_api_token(ctx.user, "owner")

      json =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/boards/#{ctx.board.id}/runners/#{ctx.runner.id}")
        |> json_response(200)

      assert json["runner"]["drift"] == %{
               "skills" => "drifted",
               "drifted_skills" => ["slipdock"],
               "cli" => "none"
             }
    end
  end

  describe "the docs" do
    test "the guide, the manual and agents.md say so" do
      assert SlipdockWeb.APIGuide.markdown() =~ "`X-Runner-Skills`"
      assert Slipdock.DocsText.read!("docs/manual.md") =~ "**Skill and CLI drift.**"
      assert Slipdock.DocsText.read!("docs/agents.md") =~ "Runners also report **drift**"
    end

    test "each says a deploy from main shows the CLI unsigned on server, not old (#2825)" do
      agents = Slipdock.DocsText.read!("docs/agents.md")
      assert agents =~ "*cli unsigned on server*"
      refute agents =~ "(and show *cli old*)"
      assert Slipdock.DocsText.read!("docs/manual/runners.md") =~ "*CLI unsigned on server*"

      Slipdock.DocsFacts.assert_states(
        SlipdockWeb.APIGuide.markdown(),
        "`cli` current, old, unsigned, none or unknown"
      )
    end

    test "each says a deploy from main shows the skills unsigned on server, not drifted (#2916)" do
      Slipdock.DocsFacts.assert_states(
        Slipdock.DocsText.read!("docs/agents.md"),
        "after a deploy from `main` runners show \"skills unsigned on server\" (`unsigned` in `drift.skills`), not \"skills drifted\": no drift alert, and the probe passes (#2916)"
      )

      Slipdock.DocsFacts.assert_states(
        Slipdock.DocsText.read!("docs/manual/runners.md"),
        "after a deploy from `main` a runner shows \"skills unsigned on server\" rather than \"skills drifted\" (#2916), raises no drift alert, and its probe passes"
      )

      Slipdock.DocsFacts.assert_states(
        SlipdockWeb.APIGuide.markdown(),
        "`skills` current, drifted, unsigned (`drifted_skills` names them) as after a deploy from `main`"
      )
    end
  end
end
