defmodule SlipdockWeb.SettingsLayoutTest do
  @moduledoc """
  `SettingsLayout.frame/1` (#1736): the one layout for Account and Admin. A
  side nav from md up and a picker on a phone, both listing every section
  with the current one marked, and a content column sized to its content.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias SlipdockWeb.SettingsLayout

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp q(html, selector), do: html |> doc() |> LazyHTML.query(selector)
  defp attr(nodes, name), do: LazyHTML.attribute(nodes, name)
  defp text(nodes), do: nodes |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp render_frame(opts \\ []) do
    assigns = %{
      current: Keyword.get(opts, :current, :tokens),
      width: Keyword.get(opts, :width, "narrow"),
      title: Keyword.get(opts, :title, true),
      extra?: Keyword.get(opts, :extra?, true),
      footer?: Keyword.get(opts, :footer?, false)
    }

    rendered_to_string(~H"""
    <SettingsLayout.frame
      id="area"
      label="Account"
      current={@current}
      content_width={@width}
      title={@title}
    >
      <:section key={:index} to="/account" icon="hero-user-circle" label="Profile" />
      <:section key={:tokens} to="/account/tokens" icon="hero-key" label="API tokens" />
      <:section
        :if={@extra?}
        key={:email_log}
        to="/account/email-log"
        icon="hero-inbox-arrow-down"
        label="Email log"
      />
      <:footer :if={@footer?}>Running build abc123</:footer>
      <p id="the-content">Section body</p>
    </SettingsLayout.frame>
    """)
  end

  describe "the side nav" do
    test "lists every section in order, as links, shown from md up" do
      html = render_frame()
      nav = q(html, "nav#area-nav")

      assert attr(nav, "aria-label") == ["Account"]
      assert hd(attr(nav, "class")) =~ "hidden"
      assert hd(attr(nav, "class")) =~ "md:block"

      links = q(html, "#area-nav a")
      assert attr(links, "href") == ["/account", "/account/tokens", "/account/email-log"]
      assert Enum.map(links, &text/1) == ["Profile", "API tokens", "Email log"]
    end

    test "marks only the current section with aria-current" do
      html = render_frame(current: :tokens)

      assert attr(q(html, ~s(#area-nav a[aria-current="page"])), "href") == ["/account/tokens"]
      assert Enum.count(q(html, "#area-nav a[aria-current]")) == 1
    end

    test "is a column, so no section is ever scrolled out of sight sideways" do
      html = render_frame()
      refute hd(attr(q(html, "#area-nav"), "class")) =~ "overflow-x"
      refute html =~ "overflow-x-auto"
    end

    test "a section left out with :if is in neither the nav nor the picker" do
      html = render_frame(extra?: false)

      assert Enum.count(q(html, "#area-nav a")) == 2
      assert Enum.count(q(html, "#area-picker a")) == 2
      refute html =~ "/account/email-log"
    end
  end

  describe "the phone picker" do
    test "is a disclosure hidden from md up, naming the current section" do
      html = render_frame(current: :email_log)
      picker = q(html, "details#area-picker")

      assert Enum.count(picker) == 1
      assert hd(attr(picker, "class")) =~ "md:hidden"
      assert text(q(html, "#area-picker summary")) == "Account Email log"
    end

    test "reaches every section, with the current one marked" do
      html = render_frame(current: :index)

      assert attr(q(html, "#area-picker a"), "href") ==
               ["/account", "/account/tokens", "/account/email-log"]

      assert attr(q(html, ~s(#area-picker a[aria-current="page"])), "href") == ["/account"]
      assert attr(q(html, "#area-picker nav"), "aria-label") == ["Account sections"]
    end
  end

  describe "the content column" do
    test "opens with the current section's title, the nav's label for it" do
      html = render_frame(current: :tokens)

      assert text(q(html, "#area-content h2[data-role=settings-section-title]")) == "API tokens"
      assert text(q(html, "#area-content #the-content")) == "Section body"
    end

    test "draws the title with the section-title token, not a size of its own" do
      class = hd(attr(q(render_frame(), "[data-role=settings-section-title]"), "class"))
      assert class =~ "section-title"
      refute class =~ ~r/(?<![\w:-])text-(?:lg|xl|2xl)(?![\w-])/
    end

    test "leaves the title out when the section draws its own" do
      html = render_frame(title: false)
      assert Enum.count(q(html, "[data-role=settings-section-title]")) == 0
    end

    test "has no title when the current key matches no section, and nothing marked" do
      html = render_frame(current: :nowhere)

      assert Enum.count(q(html, "[data-role=settings-section-title]")) == 0
      assert Enum.count(q(html, "a[aria-current]")) == 0
      assert text(q(html, "#area-picker summary")) == "Account"
    end

    test "is narrow (42rem) for forms and unbounded when wide" do
      narrow = q(render_frame(width: "narrow"), "#area-content")
      assert attr(narrow, "data-content-width") == ["narrow"]
      assert hd(attr(narrow, "class")) =~ "max-w-2xl"

      wide = q(render_frame(width: "wide"), "#area-content")
      assert attr(wide, "data-content-width") == ["wide"]
      refute hd(attr(wide, "class")) =~ "max-w-"
    end
  end

  describe "the footer" do
    test "is drawn under the nav and in the picker when given" do
      html = render_frame(footer?: true)

      assert text(q(html, "#area-nav [data-role=settings-nav-footer]")) ==
               "Running build abc123"

      assert text(q(html, "#area-picker")) =~ "Running build abc123"
    end

    test "is absent when not given" do
      html = render_frame(footer?: false)
      assert Enum.count(q(html, "[data-role=settings-nav-footer]")) == 0
      refute html =~ "Running build"
    end
  end

  describe "groups" do
    test "draw a heading above the first section of each group, once" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SettingsLayout.frame id="admin" label="Admin" current={:server}>
          <:section key={:people} to="/users" icon="hero-users" label="People" group="People" />
          <:section
            key={:signups}
            to="/users/signups"
            icon="hero-user-plus"
            label="Sign-ups"
            group="People"
          />
          <:section key={:server} to="/config" icon="hero-server" label="Server" group="Server" />
          <:section key={:tools} to="/tools/review" icon="hero-wrench" label="Tools" /> body
        </SettingsLayout.frame>
        """)

      assert Enum.map(q(html, "#admin-nav [data-role=settings-group]"), &text/1) ==
               ["People", "Server"]
    end
  end

  describe "badges (#1738)" do
    test "show a count above 0 beside the label, in the nav and the picker, and nothing at 0 or unset" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SettingsLayout.frame id="admin" label="Admin" current={:people}>
          <:section key={:people} to="/users" icon="hero-users" label="People" />
          <:section key={:signups} to="/users/signups" icon="hero-user-plus" label="Sign-ups" badge={3} />
          <:section key={:tools} to="/admin/tools" icon="hero-wrench" label="Tools" badge={0} />
          <:section key={:ai} to="/config/ai" icon="hero-sparkles" label="AI" badge={nil} /> body
        </SettingsLayout.frame>
        """)

      for list <- ["#admin-nav", "#admin-picker"] do
        assert Enum.count(q(html, "#{list} [data-role=settings-badge]")) == 1
        assert text(q(html, "#{list} a[href='/users/signups'] [data-role=settings-badge]")) == "3"
      end

      # The badge doesn't change the label the heading uses.
      assert text(q(html, "#admin-nav a[href='/users/signups']")) == "Sign-ups 3"
    end
  end
end
