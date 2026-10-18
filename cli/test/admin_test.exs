defmodule SlipdockCLI.AdminTest do
  @moduledoc """
  `slipdock admin unlimited`: what it sends, and that the people list says
  who is unlimited.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Admin, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-admin-#{System.unique_integer([:positive])}")
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

  @users ~s({"users":[{"id":7,"email":"sam@example.com"}]})

  defp user(unlimited),
    do:
      ~s({"user":{"id":7,"email":"sam@example.com","unlimited":#{unlimited},) <>
        ~s("cards":{"used":3,"limited?":false}}})

  test "on sends unlimited: true for that person, and the answer says so" do
    serve([{200, @users}, {200, user(true)}])

    output = capture_io(fn -> Admin.run("admin", ["unlimited", "Sam@example.com", "on"], []) end)

    assert_received {:request, "GET", "/api/admin/users", _}
    assert_received {:request, "PATCH", "/api/admin/users/7", body}
    assert body == ~s({"unlimited":true})
    assert output =~ "sam@example.com"
    assert output =~ "[unlimited]"
  end

  test "off sends unlimited: false, and the flag is gone from the answer" do
    serve([{200, @users}, {200, user(false)}])

    output = capture_io(fn -> Admin.run("admin", ["unlimited", "sam@example.com", "off"], []) end)

    assert_received {:request, "PATCH", "/api/admin/users/7", body}
    assert body == ~s({"unlimited":false})
    refute output =~ "unlimited"
  end

  describe "adding, readdressing and closing accounts" do
    test "add posts the address and says how they were told" do
      serve([{201, ~s({"user":{"id":8,"email":"kim@example.com"},"delivery":"emailed"})}])

      output = capture_io(fn -> Admin.run("admin", ["add", "kim@example.com"], []) end)

      assert_received {:request, "POST", "/api/admin/users", body}
      assert body == ~s({"email":"kim@example.com"})
      assert output =~ "added kim@example.com (invitation emailed)"
    end

    test "email patches that person's address" do
      serve([
        {200, @users},
        {200, ~s({"user":{"id":7,"email":"sam.new@example.com","cards":{"used":0}}})}
      ])

      output =
        capture_io(fn ->
          Admin.run("admin", ["email", "sam@example.com", "sam.new@example.com"], [])
        end)

      assert_received {:request, "PATCH", "/api/admin/users/7", body}
      assert body == ~s({"email":"sam.new@example.com"})
      assert output =~ "sam.new@example.com"
    end

    test "close --force deletes, confirming with their address" do
      serve([{200, @users}, {200, ~s({"deleted":"sam@example.com","handed_over":1})}])

      output = capture_io(fn -> Admin.run("admin", ["close", "sam@example.com"], force: true) end)

      assert_received {:request, "DELETE", path, _}
      assert path == "/api/admin/users/7?confirm=sam%40example.com"
      assert output =~ "closed sam@example.com (1 shared board(s) handed on)"
    end
  end

  # analytics is the JSON object's text, so null stays null.
  defp settings(analytics),
    do:
      ~s({"build":null,"settings":{"signup_mode":"closed",) <>
        ~s("limits":{"trial":{},"boards":{},"items":{},"storage":{}},) <>
        ~s("smtp":{"configured":false},"login_fallback":{"enabled":false},) <>
        ~s("analytics":#{analytics}}})

  test "set transcription_server_url and _token send strings; the answer says whether a token is set" do
    with_server =
      String.replace(
        settings("null"),
        ~s("analytics":null),
        ~s("analytics":null,"transcription_server":{"url":"https://transcribe.example","token_set":true})
      )

    serve([{200, with_server}, {200, settings("null")}])

    output =
      capture_io(fn ->
        Admin.run(
          "admin",
          [
            "set",
            "transcription_server_url=https://transcribe.example",
            "transcription_server_token=k3y"
          ],
          []
        )
      end)

    assert_received {:request, "PATCH", "/api/admin/settings", body}

    assert :json.decode(body) == %{
             "transcription_server_url" => "https://transcribe.example",
             "transcription_server_token" => "k3y"
           }

    assert output =~ "Transcription:    https://transcribe.example (with a token)"
    refute output =~ "k3y"

    output = capture_io(fn -> Admin.run("admin", ["set", "transcription_server_url="], []) end)
    assert output =~ "Transcription:    not set up"
  end

  test "set posthog_key sends it as a string, and settings show analytics on" do
    serve([
      {200, settings(~s({"posthog_key":"phc_abc","posthog_host":"https://eu.i.posthog.com"}))}
    ])

    output =
      capture_io(fn ->
        Admin.run(
          "admin",
          ["set", "posthog_key=phc_abc", "posthog_host=https://eu.i.posthog.com"],
          []
        )
      end)

    assert_received {:request, "PATCH", "/api/admin/settings", body}

    assert :json.decode(body) == %{
             "posthog_key" => "phc_abc",
             "posthog_host" => "https://eu.i.posthog.com"
           }

    assert output =~ "Analytics:        PostHog phc_abc → https://eu.i.posthog.com"
  end

  test "posthog_key= sends an empty key, which the server reads as off" do
    serve([{200, settings(~s({"posthog_key":null,"posthog_host":null}))}])

    output = capture_io(fn -> Admin.run("admin", ["set", "posthog_key="], []) end)

    assert_received {:request, "PATCH", "/api/admin/settings", body}
    assert :json.decode(body) == %{"posthog_key" => ""}
    assert output =~ "Analytics:        off"
  end

  test "a key with no host is shown going to the US cloud" do
    serve([{200, settings(~s({"posthog_key":"phc_abc","posthog_host":null}))}])

    output = capture_io(fn -> Admin.run("admin", ["settings"], []) end)

    assert output =~ "PostHog phc_abc → https://us.i.posthog.com"
  end

  defp ai_settings(ai) do
    JSON.encode!(%{
      "build" => nil,
      "settings" => %{
        "signup_mode" => "open",
        "limits" => %{},
        "smtp" => %{"configured" => false},
        "login_fallback" => %{"enabled" => false},
        "analytics" => %{},
        "ai" => ai
      }
    })
  end

  test "set ai_system_user sends the email, and the answer says who search runs on" do
    serve([
      {200,
       ai_settings(%{
         "system_user" => "sam@example.com",
         "source" => "chosen",
         "using" => "sam@example.com"
       })}
    ])

    output =
      capture_io(fn -> Admin.run("admin", ["set", "ai_system_user=sam@example.com"], []) end)

    assert_received {:request, "PATCH", "/api/admin/settings", body}
    assert JSON.decode!(body) == %{"ai_system_user" => "sam@example.com"}
    assert output =~ "Search & rules AI: sam@example.com (chosen here)"
  end

  test "an empty ai_system_user clears it, and off is shown as off" do
    serve([{200, ai_settings(%{"system_user" => nil, "source" => "none", "using" => nil})}])

    output = capture_io(fn -> Admin.run("admin", ["set", "ai_system_user="], []) end)

    assert_received {:request, "PATCH", "/api/admin/settings", body}
    assert JSON.decode!(body) == %{"ai_system_user" => ""}
    assert output =~ "Search & rules AI: off"
    refute output =~ "is chosen but"
  end

  test "a choice that is saved but not in effect is called out" do
    serve([
      {200,
       ai_settings(%{"system_user" => "sam@example.com", "source" => "none", "using" => nil})}
    ])

    output = capture_io(fn -> Admin.run("admin", ["settings"], []) end)

    assert output =~ "sam@example.com is chosen but has no AI settings or is no longer an admin"
  end

  test "the other sources are named" do
    for {ai, expected} <- [
          {%{"source" => "server_key"}, "the shared OPENROUTER_API_KEY"},
          {%{"source" => "environment", "using" => "a@example.com"},
           "a@example.com (SLIPDOCK_AI_SYSTEM_USER)"},
          {%{"source" => "sole_admin", "using" => "a@example.com"},
           "a@example.com (the only admin with a key)"}
        ] do
      serve([{200, ai_settings(ai)}])
      output = capture_io(fn -> Admin.run("admin", ["settings"], []) end)
      assert output =~ expected
    end
  end

  describe "admin overview" do
    @overview ~s({"totals":{"users":2,"admins":1,"disabled":0,"never_seen":1,) <>
                ~s("active_7d":1,"active_30d":1,"joined_7d":2,"joined_30d":2,) <>
                ~s("boards":3,"lists":12,"cards":40,"pages":5,"files":2,"storage":3145728},) <>
                ~s("people":[{"email":"sam@example.com","admin":true,"disabled":false,) <>
                ~s("signed_up_at":"2026-10-01T09:00:00Z","last_active_at":"2026-10-15T10:00:00Z",) <>
                ~s("boards":3,"lists":12,"cards":40,"pages":5,"files":2,"storage":3145728},) <>
                ~s({"email":"kim@example.com","admin":false,"disabled":false,) <>
                ~s("signed_up_at":"2026-10-14T09:00:00Z","last_active_at":null,) <>
                ~s("boards":0,"lists":0,"cards":0,"pages":0,"files":0,"storage":0}]})

    test "shows the totals, then a line per person" do
      serve([{200, @overview}])

      output = capture_io(fn -> Admin.run("admin", ["overview"], []) end)

      assert_received {:request, "GET", "/api/admin/overview", _}
      assert output =~ "Accounts  2 (1 admin, 0 disabled, 1 never seen)"
      assert output =~ "Made      3 boards, 12 lists, 40 cards, 5 pages, 2 files"
      assert output =~ "Storage   3.0 MB"

      assert output =~
               "sam@example.com  joined 2026-10-01  active 2026-10-15  3 boards · 12 lists · " <>
                 "40 cards · 5 pages · 2 files · 3.0 MB  [admin]"

      assert output =~ "kim@example.com  joined 2026-10-14  active never  0 boards"
      assert output =~ "0 files · 0 B\n"
    end

    test "--sort is passed through" do
      serve([{200, @overview}])

      capture_io(fn -> Admin.run("admin", ["overview"], sort: "last_active") end)

      assert_received {:request, "GET", "/api/admin/overview?sort=last_active", _}
    end

    test "--json prints what the server said" do
      serve([{200, @overview}])

      output = capture_io(fn -> Admin.run("admin", ["overview"], json: true) end)

      assert output =~ ~s("never_seen")
      refute output =~ "Accounts  "
    end
  end
end
