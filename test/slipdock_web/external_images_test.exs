defmodule SlipdockWeb.ExternalImagesTest do
  @moduledoc """
  The admin setting that keeps pages and cards to this server's own pictures
  (#3559): the Content-Security-Policy in both states, what the renderers draw
  in place of a picture from elsewhere, and who may turn it on.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}
  alias SlipdockWeb.{ExternalImages, RichText}
  alias SlipdockWeb.Wiki.Renderer

  setup do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    %{admin: admin, ordinary: user_fixture("ordinary@example.com")}
  end

  defp block(on), do: {:ok, _} = Settings.update(%{"block_external_images" => on})

  defp directives(conn) do
    [policy] = conn |> get(~p"/login") |> get_resp_header("content-security-policy")
    policy |> String.split("; ") |> Map.new(&List.to_tuple(String.split(&1, " ", parts: 2)))
  end

  defp token_conn(user, scope) do
    {token, _} = Accounts.create_api_token(user, "test", scope: scope)
    build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end

  defp markdown(text), do: text |> RichText.markdown() |> Phoenix.HTML.safe_to_string()
  defp plain(text), do: text |> RichText.render() |> Phoenix.HTML.safe_to_string()

  describe "the Content-Security-Policy" do
    test "allows pictures from anywhere over https while the setting is off", %{conn: conn} do
      refute Settings.block_external_images?()
      csp = directives(conn)
      assert csp["img-src"] == "'self' data: blob: https:"
      assert csp["media-src"] == "'self' data: blob: https:"
    end

    test "allows pictures and media from this server only once it is on", %{conn: conn} do
      block(true)
      csp = directives(conn)
      assert csp["img-src"] == "'self' data: blob:"
      assert csp["media-src"] == "'self' data: blob:"
      # The rest of the policy is untouched.
      assert csp["script-src"] == "'self'"
      assert csp["default-src"] == "'self'"
    end

    test "still names PostHog's hosts when analytics is on too", %{conn: conn} do
      block(true)

      {:ok, _} =
        Settings.update(%{
          "posthog_key" => "phc_abc123",
          "posthog_host" => "https://eu.i.posthog.com"
        })

      csp = directives(conn)
      assert csp["img-src"] == "'self' data: blob:"
      assert csp["script-src"] =~ "eu-assets.i.posthog.com"
    end

    test "a configured policy still replaces the whole header", %{conn: conn} do
      block(true)
      Slipdock.TestConfig.put(:csp, "default-src 'none'")

      assert conn |> get(~p"/login") |> get_resp_header("content-security-policy") ==
               ["default-src 'none'"]
    end
  end

  describe "card descriptions and comments" do
    test "show a picture from elsewhere as an image while the setting is off" do
      html = markdown("![chart](https://images.example.com/c.png)")
      assert html =~ ~s|<img src="https://images.example.com/c.png"|
    end

    test "show it as a link named by its alt text once it is on" do
      block(true)
      html = markdown("See ![the chart](https://images.example.com/c.png) here")

      refute html =~ "<img"
      assert html =~ ~s|href="https://images.example.com/c.png"|
      assert html =~ "the chart</a>"
    end

    test "a picture with no alt text is named by its address" do
      block(true)
      html = plain("![](https://images.example.com/c.png)")

      refute html =~ "<img"
      assert html =~ ~s|>https://images.example.com/c.png</a>|
    end

    test "leave this server's own pictures alone" do
      block(true)
      assert markdown("![shot](/uploads/a.png)") =~ ~s|<img src="/uploads/a.png"|
    end
  end

  describe "wiki pages" do
    test "show a Markdown picture from elsewhere as a link once it is on" do
      assert Renderer.to_html("![logo](https://images.example.com/l.png)") =~ "<img"

      block(true)
      html = Renderer.to_html("![logo](https://images.example.com/l.png)")

      refute html =~ "<img"
      assert html =~ ~s|<a href="https://images.example.com/l.png"|
      assert html =~ "logo</a>"
    end

    test "do the same for a picture written as raw HTML" do
      block(true)
      html = Renderer.to_html(~s|<img src="//images.example.com/l.png" alt="logo">|)

      refute html =~ "<img"
      assert html =~ "logo</a>"
    end

    test "a raw HTML picture with no alt attribute is named by its address" do
      block(true)
      html = Renderer.to_html(~s|<img src="https://images.example.com/l.png">|)

      refute html =~ "<img"
      assert html =~ ~s|>https://images.example.com/l.png</a>|
    end

    test "a picture inside a link becomes that link's text" do
      block(true)
      html = Renderer.to_html("[![logo](https://images.example.com/l.png)](https://example.com/)")

      refute html =~ "<img"
      assert html =~ ~s|<a href="https://example.com/"|
      assert html =~ "logo"
      refute html =~ ~s|href="https://images.example.com/l.png"|
    end
  end

  describe "ExternalImages.external?/1" do
    test "is true only for an absolute or scheme-relative address on another host" do
      assert ExternalImages.external?("https://images.example.com/a.png")
      assert ExternalImages.external?("http://images.example.com/a.png")
      assert ExternalImages.external?("//images.example.com/a.png")

      refute ExternalImages.external?("/uploads/a.png")
      refute ExternalImages.external?("uploads/a.png")
      refute ExternalImages.external?("data:image/png;base64,AAAA")
      refute ExternalImages.external?("blob:https://images.example.com/x")
      refute ExternalImages.external?("https://#{SlipdockWeb.Endpoint.host()}/uploads/a.png")
    end

    test "reads an address with an escaped ampersand by its host" do
      assert ExternalImages.external?("https://images.example.com/a.png?w=1&amp;h=2")
      assert ExternalImages.external?("//images.example.com/a.png?w=1&amp;h=2")

      refute ExternalImages.external?(
               "https://#{SlipdockWeb.Endpoint.host()}/uploads/a.png?w=1&amp;h=2"
             )
    end
  end

  describe "who may turn it on" do
    test "an admin, over the API and on the configuration page", %{admin: admin, conn: conn} do
      shown =
        token_conn(admin, "admin")
        |> patch(~p"/api/admin/settings", %{block_external_images: true})
        |> json_response(200)

      assert shown["settings"]["block_external_images"] == true
      assert Settings.block_external_images?()

      {:ok, view, _} = live(log_in_user(conn, admin), ~p"/config")

      view
      |> form("#external-images-form", settings: %{block_external_images: "false"})
      |> render_submit()

      refute Settings.block_external_images?()
    end

    test "not someone who isn't an admin", %{ordinary: ordinary} do
      assert token_conn(ordinary, "admin")
             |> patch(~p"/api/admin/settings", %{block_external_images: true})
             |> json_response(403)

      refute Settings.block_external_images?()
    end
  end
end
