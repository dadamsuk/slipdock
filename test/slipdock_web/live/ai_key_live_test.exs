defmodule SlipdockWeb.AIKeyLiveTest do
  @moduledoc """
  Setting your own OpenRouter key: the Account page section, the API the CLI
  uses, and the AI features hiding themselves from a person without one.
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

  describe "Account → AI key" do
    test "a key can be saved, is shown masked, and can be removed", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/account")
      assert html =~ "AI key"
      assert html =~ "AI features are off for you"

      view
      |> form("form[phx-submit=save_ai_key]", %{"api_key" => "sk-or-v1-0123456789abcdef"})
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

    test "a shared server key is said so, rather than looking like your own", %{conn: conn} do
      Application.put_env(
        :slipdock,
        :ai,
        Keyword.put(Application.get_env(:slipdock, :ai), :api_key, "sk-shared")
      )

      {:ok, _view, html} = live(conn, ~p"/account")
      assert html =~ "this server has a shared one"
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
  end

  describe "features without a key" do
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
