defmodule SlipdockWeb.CaptureRemovedTest do
  @moduledoc """
  Meeting and chat capture are gone (W-2330, #1818): no page, route, MCP tool
  or prompt, CLI command, admin setting or skill is left for them. Old links
  answer 404. What Vault's meeting notes use (the transcription server
  settings, a card's Transcribe, the wiki's recordings) stays.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}
  alias SlipdockWeb.MCP.{Prompts, Tools}

  @root Path.expand("../..", __DIR__)

  # Every way in that capture had, as {verb, path}.
  @gone [
    {"GET", "/boards/1/meetings"},
    {"GET", "/boards/1/meetings/new"},
    {"GET", "/boards/1/meetings/2"},
    {"GET", "/boards/1/meetings/2/preview"},
    {"GET", "/boards/1/meetings/2/speakers"},
    {"GET", "/boards/1/meetings/2/resolve"},
    {"GET", "/config/meetings"},
    {"GET", "/account/voiceprint"},
    {"GET", "/captures/2/audio"},
    {"GET", "/api/meetings"},
    {"GET", "/api/meetings/findings-schema"},
    {"GET", "/api/boards/1/captures"},
    {"POST", "/api/boards/1/captures"},
    {"GET", "/api/captures/2"},
    {"POST", "/api/captures/2/commit"},
    {"POST", "/api/captures/2/resolve"},
    {"GET", "/api/me/voiceprint"},
    {"POST", "/api/me/voiceprint"},
    {"DELETE", "/api/me/voiceprint"},
    {"GET", "/api/admin/meetings/usage"}
  ]

  @capture_tools ~w(capture_meeting capture_chat get_capture commit_capture resolve_capture_question)

  defp token_conn(user, scope) do
    {token, _} = Accounts.create_api_token(user, "test", scope: scope)
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  # A 404 from the app's own catch-all, or from no route matching at all.
  defp assert_404(request) do
    assert request.().status == 404
  rescue
    e in Phoenix.Router.NoRouteError -> assert Plug.Exception.status(e) == 404
  end

  setup do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    %{admin: admin}
  end

  describe "routes" do
    test "the router has none of capture's routes" do
      for {verb, path} <- @gone do
        assert Phoenix.Router.route_info(SlipdockWeb.Router, verb, path, "localhost") == :error,
               "#{verb} #{path} is still routed"
      end
    end

    test "an old capture link answers 404, signed in or by token", %{conn: conn, admin: admin} do
      conn = log_in_user(conn, admin)
      board = board_fixture(%{"name" => "Pricing"}, owner: admin)

      assert_404(fn -> get(conn, "/boards/#{board.id}/meetings") end)
      assert_404(fn -> get(conn, "/boards/#{board.id}/meetings/7/resolve") end)
      assert_404(fn -> get(token_conn(admin, "write"), "/api/meetings") end)

      assert_404(fn ->
        post(token_conn(admin, "write"), "/api/boards/#{board.id}/captures", %{})
      end)
    end

    test "the agent guide lists no capture endpoint", %{admin: admin} do
      guide = token_conn(admin, "write") |> get(~p"/api/guide") |> response(200)

      refute guide =~ "/captures"
      refute guide =~ "/api/meetings"
      refute guide =~ "voiceprint\n"
      refute guide =~ "## Meeting capture"
      refute guide =~ "## Chat capture"
    end
  end

  describe "MCP" do
    test "no capture tool is listed or found, for anybody", %{admin: admin} do
      names = Enum.map(Tools.every(), & &1.name())
      assert names == Enum.map(Tools.all(admin), & &1.name())

      for tool <- @capture_tools do
        refute tool in names
        assert Tools.find(tool, admin) == nil
      end
    end

    test "no capture prompt" do
      names = Enum.map(Prompts.every(), & &1.name())
      refute "capture-this-chat" in names
      assert "plan-my-day" in names
    end
  end

  describe "the CLI's help" do
    test "names no capture, meetings or voiceprint command, nor their settings" do
      help = Slipdock.DocsText.read!(Path.join(@root, "cli/help.txt"))

      refute help =~ ~r/^\s+(meetings|capture|capture-chat|voiceprint)\b/m
      refute help =~ "admin meetings"
      refute help =~ "meetings_"
      refute help =~ "chat_capture_enabled"
      assert help =~ "admin transcription <email> on|off"
      assert help =~ "transcription_server_url"
    end
  end

  describe "the admin settings" do
    test "carry no meetings or chat capture key, and won't take one", %{admin: admin} do
      conn = token_conn(admin, "admin")
      settings = conn |> get(~p"/api/admin/settings") |> json_response(200) |> Map.get("settings")

      refute Map.has_key?(settings, "meetings")
      refute Map.has_key?(settings, "chat_capture")
      assert Map.has_key?(settings, "transcription_server")

      # Sent anyway, they are ignored: the settings have no such fields.
      conn
      |> patch(~p"/api/admin/settings", %{
        "meetings_enabled" => true,
        "chat_capture_enabled" => false
      })
      |> json_response(200)

      settings = Map.from_struct(Settings.get())
      refute Map.has_key?(settings, :meetings_enabled)
      refute Map.has_key?(settings, :chat_capture_enabled)

      refute Enum.any?(
               Map.keys(settings),
               &(&1 |> Atom.to_string() |> String.starts_with?("meetings_"))
             )
    end

    test "the transcription server settings are still editable", %{admin: admin} do
      settings =
        token_conn(admin, "admin")
        |> patch(~p"/api/admin/settings", %{
          "transcription_server_url" => "https://transcribe.example.com:8765",
          "transcription_voiceprints" => true
        })
        |> json_response(200)
        |> Map.get("settings")

      assert settings["transcription_server"]["url"] == "https://transcribe.example.com:8765"
      assert Settings.get().transcription_voiceprints == true
    end
  end

  describe "nothing left that names it (#1820)" do
    # The terms the sweep looked for (W-2330 §What goes). Wiki revision
    # history's `"meeting"` value and the meeting pages docs (W-1690) don't
    # match any of them, and stay.
    @terms ~r/meeting mode|meeting capture|chat capture|chat_capture|meetings_|capture_chat|capture_meeting|get_capture|commit_capture|resolve_capture|Slipdock\.Meetings|MeetingLive|slipdock-capture|card_provenance/i

    @swept ~w(lib cli/lib priv/skills docs tools assets/js)
    @swept_files ~w(README.md AGENTS.md cli/help.txt)

    defp swept_files do
      dirs =
        for dir <- @swept,
            path <- Path.wildcard(Path.join([@root, dir, "**", "*"])),
            File.regular?(path),
            do: path

      dirs ++ Enum.map(@swept_files, &Path.join(@root, &1))
    end

    test "no file in lib/, cli/, priv/skills, docs/ or tools/ names capture" do
      files = swept_files()
      assert Path.join(@root, "lib/slipdock/wiki/revision.ex") in files
      assert Path.join(@root, "docs/manual.md") in files

      hits =
        for path <- files,
            text = Slipdock.DocsText.read!(path),
            String.valid?(text),
            {line, n} <- text |> String.split("\n") |> Enum.with_index(1),
            line =~ @terms,
            do: "#{Path.relative_to(path, @root)}:#{n}: #{String.trim(line)}"

      assert hits == [], "capture is still named:\n" <> Enum.join(hits, "\n")
    end

    test "the sweep would catch a mention" do
      assert "  alias Slipdock.Meetings.Capture" =~ @terms
      assert "turn on Meeting capture in Config" =~ @terms
      assert ~s("chat_capture_enabled" => true) =~ @terms
      assert "slipdock-capture/SKILL.md" =~ @terms
      refute "@vias ~w(web api meeting sync)" =~ @terms
      refute "### Meeting pages (recordings on Google Drive)" =~ @terms
    end

    test "no module of Slipdock.Meetings or the meeting pages is compiled" do
      {:ok, modules} = :application.get_key(:slipdock, :modules)
      names = Enum.map(modules, &inspect/1)

      assert names != []
      assert "Slipdock.Transcription.Voiceprints" in names
      refute Enum.any?(names, &String.starts_with?(&1, "Slipdock.Meetings"))
      refute Enum.any?(names, &String.starts_with?(&1, "SlipdockWeb.MeetingLive"))
      refute Code.ensure_loaded?(Slipdock.Meetings)
    end
  end

  test "the slipdock-capture skill is gone" do
    refute File.exists?(Path.join(@root, "priv/skills/slipdock-capture"))
    refute Slipdock.DocsText.read!(Path.join(@root, "priv/skills/slipdock/SKILL.md")) =~ "capture"
  end
end
