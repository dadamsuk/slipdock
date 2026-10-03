defmodule SlipdockWeb.AIKeyLiveTest do
  @moduledoc """
  Setting up your own model — a key, an endpoint, or both: the Account page
  section, the API the CLI uses, and the AI features hiding themselves from a
  person who has neither.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.AI.Keys

  setup do
    Slipdock.AIStub.share()

    previous = Application.get_env(:slipdock, :ai)
    file = Path.join(System.tmp_dir!(), "ai_keys_live_#{System.unique_integer([:positive])}.json")

    Application.put_env(
      :slipdock,
      :ai,
      previous |> Keyword.put(:key_file, file) |> Keyword.put(:api_key, nil)
    )

    on_exit(fn ->
      Application.put_env(:slipdock, :ai, previous)
      File.rm(file)
    end)

    :ok
  end

  describe "Account → AI model" do
    test "a key can be saved, is shown masked, and can be removed", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/account/settings")
      assert html =~ "AI model"
      assert html =~ "AI features are off for you"

      view
      |> form("form[phx-submit=save_ai_provider]", %{"api_key" => "sk-or-v1-0123456789abcdef"})
      |> render_submit()

      assert Keys.get(user) == "sk-or-v1-0123456789abcdef"

      html = render(view)
      assert html =~ "sk-or-v1…cdef"
      # Never the key itself.
      refute html =~ "0123456789abcdef"

      view |> element("button[phx-click=remove_ai_key]") |> render_click()
      refute Keys.configured?(user)
      assert render(view) =~ "AI features are off for you"
    end

    test "an endpoint of your own turns AI on without any key", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/account/settings")

      view
      |> form("form[phx-submit=save_ai_provider]", %{"base_url" => "http://box.local:1234/v1/"})
      |> render_submit()

      # The trailing slash is dropped, and no key is demanded.
      assert Keys.endpoint(user) == "http://box.local:1234/v1"
      assert Keys.get(user) == nil
      assert Slipdock.AI.configured?(user)

      html = render(view)
      assert html =~ "http://box.local:1234/v1"
      assert html =~ "your endpoint is being asked without one"
    end

    test "saving the endpoint leaves a stored key alone", %{conn: conn, user: user} do
      :ok = Keys.put(user, "sk-or-v1-0123456789abcdef")
      {:ok, view, _html} = live(conn, ~p"/account/settings")

      view
      |> form("form[phx-submit=save_ai_provider]", %{
        "base_url" => "http://box.local:1234/v1",
        "api_key" => ""
      })
      |> render_submit()

      assert Keys.get(user) == "sk-or-v1-0123456789abcdef"
      assert Keys.endpoint(user) == "http://box.local:1234/v1"
    end

    test "nonsense for an endpoint is refused, not stored", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/account/settings")

      html =
        view
        |> form("form[phx-submit=save_ai_provider]", %{"base_url" => "my-llm-box"})
        |> render_submit()

      assert html =~ "doesn&#39;t look like a URL"
      assert Keys.endpoint(user) == nil
    end

    test "the models the endpoint offers can be listed and one picked", %{
      conn: conn,
      user: user
    } do
      Slipdock.AIStub.stub_models(["local/big", "local/small", "local/text-embedding"])
      :ok = Keys.put_settings(user, %{base_url: "http://box.local:1234/v1"})

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      view |> element("button[phx-click=list_ai_models]") |> render_click()
      # The list arrives from an async task.
      html = render_async(view)
      assert html =~ "local/small"
      assert html =~ "3 model(s)"

      view
      |> form("form[phx-submit=save_ai_model]", %{
        "model" => "local/small",
        "embed_model" => "local/text-embedding"
      })
      |> render_submit()

      assert Keys.model(user) == "local/small"
      assert Keys.settings(user).embed_model == "local/text-embedding"
      assert render(view) =~ "local/small"
    end

    test "an endpoint that cannot be reached says so and stores nothing", %{
      conn: conn,
      user: user
    } do
      Slipdock.AIStub.fail_with(500, "connection refused")
      :ok = Keys.put_settings(user, %{base_url: "http://nothing.local:1234/v1"})

      {:ok, view, _html} = live(conn, ~p"/account/settings")
      view |> element("button[phx-click=list_ai_models]") |> render_click()

      assert render_async(view) =~ "connection refused"
      assert Keys.model(user) == nil
    end

    test "a shared server key is said so, rather than looking like your own", %{conn: conn} do
      Application.put_env(
        :slipdock,
        :ai,
        Keyword.put(Application.get_env(:slipdock, :ai), :api_key, "sk-shared")
      )

      {:ok, _view, html} = live(conn, ~p"/account/settings")
      assert html =~ "this server has a shared key"
    end
  end

  describe "the API the CLI uses" do
    test "PUT and DELETE /api/me/ai-key", %{conn: conn, user: user} do
      body =
        conn
        |> put(~p"/api/me/ai-key", %{"api_key" => "sk-or-v1-abcdefghij"})
        |> json_response(200)

      assert body["ai_key"]["configured"] == true
      assert body["ai_key"]["masked"] == "sk-or-v1…ghij"
      refute body["ai_key"]["masked"] == "sk-or-v1-abcdefghij"
      assert Keys.get(user) == "sk-or-v1-abcdefghij"

      shown = conn |> get(~p"/api/me") |> json_response(200)
      assert shown["ai_key"]["configured"] == true

      gone = conn |> delete(~p"/api/me/ai-key") |> json_response(200)
      assert gone["ai_key"]["configured"] == false
      refute Keys.configured?(user)
    end

    test "a request with no key at all is refused with a message", %{conn: conn} do
      assert conn |> put(~p"/api/me/ai-key", %{}) |> json_response(422) |> Map.has_key?("error")
    end

    test "PUT /api/me/ai-provider sets the endpoint and model", %{conn: conn, user: user} do
      body =
        conn
        |> put(~p"/api/me/ai-provider", %{
          "base_url" => "http://box.local:1234/v1",
          "model" => "local/small"
        })
        |> json_response(200)

      assert body["ai"]["base_url"] == "http://box.local:1234/v1"
      assert body["ai"]["own_endpoint"] == "http://box.local:1234/v1"
      assert body["ai"]["model"] == "local/small"
      assert Keys.endpoint(user) == "http://box.local:1234/v1"

      # Clearing the endpoint goes back to the server's default, and says so.
      back = conn |> put(~p"/api/me/ai-provider", %{"base_url" => ""}) |> json_response(200)
      assert back["ai"]["own_endpoint"] == nil
      assert back["ai"]["base_url"] == Slipdock.AI.default_base_url()
      # …without taking the model with it.
      assert Keys.model(user) == "local/small"
    end

    test "a bad endpoint is a 422 with a message", %{conn: conn} do
      body = conn |> put(~p"/api/me/ai-provider", %{"base_url" => "nope"}) |> json_response(422)
      assert body["error"] =~ "URL"
    end

    test "an empty body is refused rather than silently doing nothing", %{conn: conn} do
      assert conn |> put(~p"/api/me/ai-provider", %{}) |> json_response(422)
    end

    test "GET /api/me/ai-models lists what the endpoint can run", %{conn: conn, user: user} do
      Slipdock.AIStub.stub_models(["local/big", "local/text-embedding-small"])
      :ok = Keys.put_settings(user, %{base_url: "http://box.local:1234/v1"})

      body = conn |> get(~p"/api/me/ai-models") |> json_response(200)
      assert Enum.map(body["models"], & &1["id"]) == ["local/big", "local/text-embedding-small"]
      assert Enum.map(body["models"], & &1["embedding?"]) == [false, true]
    end
  end

  describe "features without a key" do
    test "an endpoint of their own is enough, with no key", %{conn: conn, user: user} do
      board = board_fixture(%{"name" => "Launch"}, owner: user)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}")
      refute html =~ "Chat about this page with AI"

      :ok = Keys.put_settings(user, %{base_url: "http://box.local:1234/v1"})
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "Chat about this page with AI"
    end

    test "the board page offers no chat until the viewer has one", %{conn: conn, user: user} do
      board = board_fixture(%{"name" => "Launch"}, owner: user)
      card_fixture(hd(board.columns), %{"title" => "Write the plan"})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}")
      refute html =~ "Chat about this page with AI"

      :ok = Keys.put(user, "sk-mine")
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "Chat about this page with AI"
    end
  end
end
