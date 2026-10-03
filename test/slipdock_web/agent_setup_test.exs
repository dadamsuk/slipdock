defmodule SlipdockWeb.AgentSetupTest do
  @moduledoc """
  Setting an agent up — the one path a person who has never used an API has to
  get through on their own. What is asserted here is the two things that make
  it work on a machine other than this one: the address handed out is the one
  that answers (https behind a proxy, not the last hop's plain http), and
  everything needed to install can be had with `curl` and `tar`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  @canonical SlipdockWeb.Endpoint.config(:url)[:host]

  describe "the address handed out" do
    @tag :anonymous
    test "is https when a proxy says the request arrived over TLS", %{conn: conn} do
      body =
        conn
        |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
        |> Map.put(:host, "boards.example.test")
        |> get(~p"/api/guide")
        |> response(200)

      assert body =~ "https://boards.example.test"
      refute body =~ "http://boards.example.test"
    end

    @tag :anonymous
    test "keeps the host the caller used, port and all", %{conn: conn} do
      # A self-hosted install is usually reached by a name this app has never
      # been told about, on a port that matters. Both have to survive.
      body =
        conn
        |> Map.merge(%{host: "boards.tailnet.test", port: 4000})
        |> get(~p"/api/guide")
        |> response(200)

      assert body =~ "http://boards.tailnet.test:4000"
    end

    @tag :anonymous
    test "uses the configured scheme for the name this server knows itself by", %{conn: conn} do
      # The proxy header is the usual signal, but a request can arrive without
      # one; what the app was *told* it is called still beats the last hop.
      body = conn |> Map.put(:host, @canonical) |> get(~p"/api/guide") |> response(200)

      assert body =~ SlipdockWeb.Endpoint.url()
    end
  end

  describe "/install.sh" do
    @tag :anonymous
    test "is readable plain text naming this server, and needs no token", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
        |> Map.put(:host, "boards.example.test")
        |> get("/install.sh")

      script = response(conn, 200)

      assert response_content_type(conn, :txt) =~ "text/plain"
      assert script =~ "#!/bin/sh"
      assert script =~ ~s(BASE="https://boards.example.test")
      assert script =~ "/api/skills.tar.gz"
      assert script =~ ".config/slipdock/url"
      # Only curl and tar: the whole point is a machine with no Elixir on it.
      assert script =~ "for tool in curl tar; do"
      refute script =~ "mix "
    end
  end

  describe "the skills archive" do
    @tag :anonymous
    test "unpacks into an agent directory, without a token", %{conn: conn} do
      bytes = conn |> get(~p"/api/skills.tar.gz") |> response(200)

      {:ok, files} = :erl_tar.extract({:binary, bytes}, [:compressed, :memory])
      names = Enum.map(files, fn {name, _} -> to_string(name) end)

      assert "slipdock/SKILL.md" in names
      assert "slipdock-work/SKILL.md" in names
      assert "slipdock-wiki/references/markup.md" in names

      {_, body} = Enum.find(files, fn {name, _} -> to_string(name) == "slipdock/SKILL.md" end)
      assert body =~ "name: slipdock"
    end
  end

  describe "the Set up an agent page" do
    # Reached by the name this server knows itself by, so the page should quote
    # the configured address back — which is what a hosted install looks like.
    setup %{conn: conn} do
      conn = %{conn | host: @canonical}
      %{conn: log_in_user(conn, user_fixture("owner@example.com"))}
    end

    test "hands over a prompt carrying this server's own address", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/account/agent")

      base = SlipdockWeb.Endpoint.url()
      assert html =~ "Work from my Slipdock board at #{base}"
      assert html =~ "#{base}/api/guide"
      assert html =~ "curl -fsSL #{base}/install.sh | sh"
    end

    test "does not pretend reading a board is free, and approves in the browser", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/account/agent")

      assert html =~ "Claude, ChatGPT or anything else"
      # The guide is the only open thing. Saying otherwise sends people off to
      # test a read that cannot work.
      assert html =~ "Not optional, and not only about writing"
      refute html =~ "Reading is free"
      assert has_element?(view, ~s{a[href="/activate"]})
      assert has_element?(view, ~s{a[href="/account/tokens"]})
    end

    test "is reachable from the account menu on every page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, ~s{a[href="/account/agent"]}, "Set up an agent")
    end
  end
end
