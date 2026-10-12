defmodule SlipdockWeb.ConfigTranscriptionTest do
  @moduledoc """
  The configuration page's Transcription server: its address and token, what
  is kept when the token box is left empty, and Test connection.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  setup %{conn: conn} do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "signup_mode" => :closed})

    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    %{conn: log_in_user(conn, admin)}
  end

  defp submit(view, params, action \\ "save") do
    view
    |> form("#transcription-form", transcription: params)
    |> render_submit(%{"step_action" => action})
  end

  test "saves the address and the token, and never shows the token back", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/config")
    assert html =~ "Transcription server"

    submit(view, %{url: "https://manuel.example:8765", token: "s3cret-token"})

    settings = Settings.get()
    assert settings.transcription_server_url == "https://manuel.example:8765"
    assert settings.transcription_server_token == "s3cret-token"

    html = render(view)
    refute html =~ "s3cret-token"
    assert has_element?(view, "#transcription-form input[type=password][placeholder=unchanged]")
    assert has_element?(view, "#transcription-form input[value='https://manuel.example:8765']")
  end

  test "an empty token box keeps the token; Forget clears it", %{conn: conn} do
    {:ok, _} =
      Settings.update(%{
        transcription_server_url: "https://old.example",
        transcription_server_token: "keep-me"
      })

    {:ok, view, _} = live(conn, ~p"/config")

    submit(view, %{url: "https://new.example", token: ""})
    assert Settings.get().transcription_server_url == "https://new.example"
    assert Settings.get().transcription_server_token == "keep-me"

    submit(view, %{url: "https://new.example", token: "", forget_token: "true"})
    assert Settings.get().transcription_server_token == nil
    refute has_element?(view, "#transcription-form input[name='transcription[forget_token]']")
  end

  test "an address that isn't http(s) is refused and nothing is saved", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/config")

    html = submit(view, %{url: "ftp://manuel.example", token: "t"})
    assert html =~ "must be an http:// or https:// address"
    assert Settings.get().transcription_server_url == nil
    assert Settings.get().transcription_server_token == nil
  end

  test "clearing the address turns transcription off", %{conn: conn} do
    {:ok, _} = Settings.update(%{transcription_server_url: "https://old.example"})
    {:ok, view, _} = live(conn, ~p"/config")

    submit(view, %{url: "", token: ""})
    assert Settings.get().transcription_server_url == nil
    refute Slipdock.Transcription.configured?()
  end

  describe "Test connection" do
    test "asks the typed address, with the typed token, and saves nothing", %{conn: conn} do
      test = self()

      Req.Test.stub(Slipdock.Transcription, fn conn ->
        send(test, {:status, conn.host, Plug.Conn.get_req_header(conn, "authorization")})

        Req.Test.json(conn, %{
          "version" => "2.4.0",
          "api_version" => "1.1.0",
          "capabilities" => ["diarization", "priority"]
        })
      end)

      {:ok, view, _} = live(conn, ~p"/config")
      html = submit(view, %{url: "https://try.example/v1", token: "typed"}, "test")

      assert_received {:status, "try.example", ["Bearer typed"]}
      assert html =~ "Connected: version 2.4.0, API 1.1.0 — offers diarization, priority"
      assert Settings.get().transcription_server_url == nil
      # What was typed stays in the box to be saved.
      assert has_element?(view, "#transcription-form input[value='https://try.example/v1']")
    end

    test "uses the stored token when none is typed", %{conn: conn} do
      {:ok, _} = Settings.update(%{transcription_server_token: "stored"})
      test = self()

      Req.Test.stub(Slipdock.Transcription, fn conn ->
        send(test, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"api_version" => "1.0.0"})
      end)

      {:ok, view, _} = live(conn, ~p"/config")
      submit(view, %{url: "https://try.example", token: ""}, "test")
      assert_received {:auth, ["Bearer stored"]}
    end

    test "says what went wrong", %{conn: conn} do
      Req.Test.stub(Slipdock.Transcription, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"code" => "invalid_api_key", "message" => "no"}})
      end)

      {:ok, view, _} = live(conn, ~p"/config")
      html = submit(view, %{url: "https://try.example", token: "bad"}, "test")
      assert html =~ "refused the token"

      html = submit(view, %{url: "", token: ""}, "test")
      assert html =~ "Give the server&#39;s address first."
    end
  end
end
