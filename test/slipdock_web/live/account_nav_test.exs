defmodule SlipdockWeb.AccountNavTest do
  @moduledoc """
  The account area is four pages, not one scroll. What matters is that each
  tab carries its own sections and *only* its own — the old page's failing
  was everything being on screen at once.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  setup %{conn: conn}, do: %{conn: log_in_user(conn, user_fixture("owner@example.com"))}

  @pages [
    {"/account", ["Profile", "Session", "About"], ["API tokens", "Quick add", "Bring boards in"]},
    {"/account/settings", ["Quick add", "AI model"], ["Profile", "Bring boards in"]},
    {"/account/tokens", ["API tokens"], ["Profile", "AI model", "Bring boards in"]},
    {"/account/data", ["Your data", "Bring boards in"], ["Profile", "AI model"]}
  ]

  test "each tab shows its own sections and no others", %{conn: conn} do
    for {path, present, absent} <- @pages do
      {:ok, _view, html} = live(conn, path)

      for heading <- present, do: assert(html =~ heading, "#{path} is missing #{heading}")

      for heading <- absent,
          do: refute(html =~ ~s{>#{heading}</h2>}, "#{path} still has #{heading}")
    end
  end

  test "every tab links to the other three", %{conn: conn} do
    for {path, _, _} <- @pages do
      {:ok, view, _} = live(conn, path)

      for {other, _, _} <- @pages, other != path do
        assert has_element?(view, ~s{#account-tabs a[href="#{other}"]})
      end
    end
  end
end
