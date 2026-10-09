defmodule SlipdockWeb.Meetings.VoiceprintWebTest do
  @moduledoc """
  Voiceprints over the web (#548): `/api/me/voiceprint` and the account's
  Voiceprint tab only exist while an admin has voiceprints on; every path is
  the caller's own, and one that names anybody else is refused; enrolling
  needs the consent wording agreed to; no MCP tool touches voiceprints; the
  admin turns them on in Configuration › Meetings.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Accounts, Repo, Settings}
  alias Slipdock.Meetings.{Voiceprint, Voiceprints}

  setup do
    meetings_on()
    :ok
  end

  defp voiceprints_on do
    {:ok, _} =
      Settings.update(%{
        "meetings_voiceprints" => true,
        "meetings_voiceprint_url" => "http://voice.example/embed"
      })

    Slipdock.TestConfig.merge(:meetings, voiceprint_req_options: [plug: {Req.Test, __MODULE__}])
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"embedding" => [0.6, 0.8]}) end)
  end

  defp audio do
    path = Path.join(System.tmp_dir!(), "vpw-#{System.unique_integer([:positive])}.wav")
    File.write!(path, "MY VOICE")
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: "me.wav", content_type: "audio/wav"}
  end

  defp version, do: Voiceprints.wording_version()

  describe "the API while voiceprints are off" do
    test "every route answers 404 voiceprints_off, and nothing is stored", %{conn: conn} do
      assert %{"code" => "voiceprints_off"} =
               conn |> get(~p"/api/me/voiceprint") |> json_response(404)

      assert %{"code" => "voiceprints_off"} =
               conn
               |> post(~p"/api/me/voiceprint", %{"audio" => audio(), "consent" => version()})
               |> json_response(404)

      assert %{"code" => "voiceprints_off"} =
               conn |> delete(~p"/api/me/voiceprint") |> json_response(404)

      assert Repo.aggregate(Voiceprint, :count) == 0
    end

    test "with meeting mode off, the routes aren't there at all", %{conn: conn} do
      voiceprints_on()
      {:ok, _} = Settings.update(%{"meetings_enabled" => false})

      assert %{"code" => "meetings_off"} =
               conn |> get(~p"/api/me/voiceprint") |> json_response(404)
    end

    test "the mode says whether they are on", %{conn: conn} do
      assert get(conn, ~p"/api/meetings")
             |> json_response(200)
             |> get_in(~w(meetings voiceprints)) ==
               false

      voiceprints_on()

      assert get(conn, ~p"/api/meetings")
             |> json_response(200)
             |> get_in(~w(meetings voiceprints)) ==
               true
    end
  end

  describe "the API" do
    setup do
      voiceprints_on()
      :ok
    end

    test "enrol, show, delete: the caller's own", %{conn: conn, user: user} do
      body = conn |> get(~p"/api/me/voiceprint") |> json_response(200)
      assert body["voiceprint"] == nil
      assert body["consent"] == %{"version" => version(), "wording" => Voiceprints.wording()}

      body =
        conn
        |> post(~p"/api/me/voiceprint", %{"audio" => audio(), "consent" => version()})
        |> json_response(201)

      assert %{"source" => "recording", "dimensions" => 2, "consent_version" => v} =
               body["voiceprint"]

      assert v == version()
      assert Voiceprints.get(user).embedding == [0.6, 0.8]

      assert conn
             |> get(~p"/api/me/voiceprint")
             |> json_response(200)
             |> get_in(~w(voiceprint source)) ==
               "recording"

      assert %{"deleted" => true, "voiceprint" => nil} =
               conn |> delete(~p"/api/me/voiceprint") |> json_response(200)

      assert Voiceprints.get(user) == nil

      assert %{"error" => "you have no voiceprint"} =
               conn |> delete(~p"/api/me/voiceprint") |> json_response(404)
    end

    test "without consent nothing is stored, and the wording comes back", %{conn: conn} do
      for consent <- [nil, "yes", "2020-01-01"] do
        body =
          conn
          |> post(~p"/api/me/voiceprint", %{"audio" => audio(), "consent" => consent})
          |> json_response(422)

        assert body["code"] == "consent_required"
        assert body["consent"]["wording"] == Voiceprints.wording()
      end

      assert Repo.aggregate(Voiceprint, :count) == 0
    end

    test "naming anybody — even yourself — is refused on every route", %{conn: conn, user: user} do
      other = user_fixture("other@example.com")

      for params <- [
            %{"user_id" => other.id},
            %{"email" => other.email},
            %{"user" => other.email},
            %{"user_id" => user.id}
          ] do
        assert %{"error" => "a voiceprint can only be your own"} =
                 conn
                 |> post(
                   ~p"/api/me/voiceprint",
                   Map.merge(%{"audio" => audio(), "consent" => version()}, params)
                 )
                 |> json_response(403)

        assert conn |> get(~p"/api/me/voiceprint", params) |> json_response(403)
        assert conn |> delete(~p"/api/me/voiceprint", params) |> json_response(403)
      end

      assert Repo.aggregate(Voiceprint, :count) == 0
    end

    test "nothing to enrol from, or another person's meeting voice, is a 422", %{conn: conn} do
      assert %{"error" => "send audio" <> _} =
               conn
               |> post(~p"/api/me/voiceprint", %{"consent" => version()})
               |> json_response(422)

      assert %{"error" => "that meeting has no confirmed voice of yours to enrol from"} =
               conn
               |> post(~p"/api/me/voiceprint", %{"capture" => "999999", "consent" => version()})
               |> json_response(422)
    end

    test "a read-only token can look but not enrol", %{user: user} do
      {token, _} = Accounts.create_api_token(user, "ro", scope: "read")
      conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

      assert conn |> get(~p"/api/me/voiceprint") |> json_response(200)

      assert conn
             |> post(~p"/api/me/voiceprint", %{"audio" => audio(), "consent" => version()})
             |> json_response(403)

      assert Repo.aggregate(Voiceprint, :count) == 0
    end
  end

  test "the agent guide speaks of voiceprints only while on, and says they aren't an agent's", %{
    conn: conn
  } do
    refute conn |> get(~p"/api/guide") |> response(200) =~ "Voiceprints are on here"

    voiceprints_on()
    guide = conn |> get(~p"/api/guide") |> response(200)
    assert guide =~ "/api/me/voiceprint"
    assert guide =~ "Voiceprints are on here"
    assert guide =~ "never enrol or delete one on their behalf"
  end

  test "the capture skill tells agents voiceprints aren't theirs to make" do
    {:ok, text} = Slipdock.Skills.read("slipdock-capture")
    assert text =~ "Never enrol, or delete, a voiceprint on the user's behalf."
  end

  test "no MCP tool, on or off, touches voiceprints" do
    voiceprints_on()

    for tool <- SlipdockWeb.MCP.Tools.every() do
      name = tool.name() |> to_string()
      refute name =~ "voice", "#{name} looks like a voiceprint tool"
    end
  end

  describe "the account tab" do
    test "isn't there while voiceprints are off", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/account")
      refute html =~ "/account/voiceprint"
      assert_raise SlipdockWeb.MeetingsOff, fn -> live(conn, ~p"/account/voiceprint") end
    end

    test "enrols from a recording only with the box ticked, then deletes", %{
      conn: conn,
      user: user
    } do
      voiceprints_on()
      {:ok, _view, html} = live(conn, ~p"/account")
      assert html =~ "/account/voiceprint"

      {:ok, view, html} = live(conn, ~p"/account/voiceprint")
      assert html =~ Voiceprints.wording()

      upload = fn ->
        view
        |> file_input("#voiceprint-recording", :recording, [
          %{name: "me.wav", content: "MY VOICE", type: "audio/wav"}
        ])
        |> render_upload("me.wav")
      end

      upload.()
      html = view |> form("#voiceprint-recording") |> render_submit()
      assert html =~ "Tick the box to agree first"
      assert Voiceprints.get(user) == nil

      upload.()
      html = view |> form("#voiceprint-recording", %{"consent" => "true"}) |> render_submit()
      assert html =~ "You have a voiceprint"
      assert Voiceprints.get(user).embedding == [0.6, 0.8]
      assert view |> element("#voiceprint-consents") |> render() =~ "given"

      view |> element("#voiceprint-delete") |> render_click()
      assert Voiceprints.get(user) == nil
      assert view |> element("#voiceprint-consents") |> render() =~ "withdrawn"
    end

    test "offers a meeting where their voice was confirmed, and enrols from it", %{
      conn: conn,
      user: user
    } do
      voiceprints_on()
      board = board_fixture(%{"name" => "Pricing"}, owner: user)
      path = audio().path

      {:ok, c} =
        Slipdock.Meetings.create_capture(
          board,
          user,
          %{title: "Weekly", fingerprint: Slipdock.Meetings.fingerprint(audio: path)},
          audio: %{path: path, filename: "call.wav"},
          utterances: [%{speaker: "Voice A", text: "Hello.", start_ms: 0, end_ms: 3000}]
        )

      {:ok, _} = Slipdock.Meetings.Speakers.diarise(c)
      voice = Repo.get_by!(Slipdock.Meetings.Voice, capture_id: c.id)
      {:ok, _} = Slipdock.Meetings.Speakers.reassign(voice, %{"user_id" => user.id}, user)

      {:ok, view, _} = live(conn, ~p"/account/voiceprint")
      assert view |> element("#voiceprint-offer-#{c.id}") |> render() =~ "“Weekly”"

      view
      |> form("#voiceprint-offer-#{c.id}", %{"consent" => "true"})
      |> render_submit()

      assert %{source: "meeting", source_capture_id: id} = Voiceprints.get(user)
      assert id == c.id
    end
  end

  describe "the admin" do
    setup %{user: user} do
      {:ok, admin} = Accounts.promote(user)
      %{admin: admin}
    end

    test "turns them on with an endpoint in Configuration › Meetings", %{conn: conn, admin: admin} do
      {:ok, view, _} = live(conn, ~p"/config/meetings")

      view
      |> form("#meetings-form",
        settings: %{
          meetings_voiceprints: "true",
          meetings_voiceprint_url: "http://voice.local/embed"
        }
      )
      |> render_submit()

      assert Settings.get().meetings_voiceprints
      assert Voiceprints.enabled?()

      {token, _} = Accounts.create_api_token(admin, "admin", scope: "admin")
      conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)
      voices = conn |> get(~p"/api/admin/settings") |> json_response(200)
      voices = voices["settings"]["meetings"]["voices"]
      assert voices["voiceprints"] == true
      assert voices["voiceprint_url"] == "http://voice.local/embed"
    end

    test "can't turn them on without an endpoint", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config/meetings")

      view
      |> form("#meetings-form", settings: %{meetings_voiceprints: "true"})
      |> render_submit()

      refute Settings.get().meetings_voiceprints
    end
  end
end
