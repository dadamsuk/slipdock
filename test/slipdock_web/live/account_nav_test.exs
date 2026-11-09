defmodule SlipdockWeb.AccountNavTest do
  @moduledoc """
  The account area is a page per section in the settings layout (#1737): a
  side nav from md up and a picker on a phone, each listing every section
  with the current one marked, and the section's content under a heading
  that says what the nav says. Each section is still its own mount, and
  carries its own parts and *only* its own — the old page's failing was
  everything being on screen at once.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias SlipdockWeb.AccountLive

  setup %{conn: conn}, do: %{conn: log_in_user(conn, user_fixture("owner@example.com"))}

  # {path, nav label, what it shows, what it must not}. Email log comes and
  # goes with the server's settings, and has its own tests (inbound_log_test).
  @sections [
    {"/account", "Profile", ["Signed in as", "About"], ["Passkeys", "Session", "Quick add"]},
    {"/account/settings", "Preferences", ["Quick add", "AI model"], ["About", "Bring boards in"]},
    {"/account/sign-in", "Sign-in & passkeys", ["Passkeys", "Session", "Sign out"],
     ["About", "AI model", "Bring boards in"]},
    {"/account/tokens", "API tokens", ["slipdock auth"], ["About", "AI model", "Passkeys"]},
    {"/account/agent", "Set up an agent", ["Tell it where the board is"],
     ["About", "AI model", "Bring boards in"]},
    {"/account/machines", "Machines", ["slipdock-runner init", "Enrolment key"],
     ["About", "AI model", "Passkeys"]},
    {"/account/data", "Import & export", ["Your data", "Bring boards in"],
     ["About", "AI model", "Passkeys"]}
  ]

  @paths Enum.map(@sections, &elem(&1, 0))

  test "every old URL still opens its section, under the one Account title", %{conn: conn} do
    for {path, label, _, _} <- @sections do
      assert {:ok, view, _} = live(conn, path), "#{path} doesn't open"
      assert has_element?(view, "h1", "Account")
      assert has_element?(view, "#account-content [data-role=settings-section-title]", label)
    end
  end

  test "each section shows its own parts and no others", %{conn: conn} do
    for {path, _, present, absent} <- @sections do
      {:ok, _view, html} = live(conn, path)

      for text <- present, do: assert(html =~ text, "#{path} is missing #{text}")

      for heading <- absent,
          do: refute(html =~ ~s{>#{heading}</h2>}, "#{path} still has #{heading}")
    end
  end

  test "the side nav and the picker list every section, in order", %{conn: conn} do
    for {path, _, _, _} <- @sections do
      {:ok, view, html} = live(conn, path)
      doc = LazyHTML.from_fragment(html)

      for part <- ["#account-nav", "#account-picker"] do
        links = LazyHTML.query(doc, "#{part} a")
        assert LazyHTML.attribute(links, "href") == @paths, "#{path}: #{part} is out of order"

        assert Enum.map(links, &(&1 |> LazyHTML.text() |> String.trim())) ==
                 Enum.map(@sections, &elem(&1, 1))
      end

      assert has_element?(view, ~s{nav#account-nav[aria-label="Account"]})
    end
  end

  test "marks the current section, and only it, in the nav and the picker", %{conn: conn} do
    for {path, label, _, _} <- @sections do
      {:ok, view, _} = live(conn, path)

      for part <- ["#account-nav", "#account-picker"] do
        assert has_element?(view, ~s{#{part} a[href="#{path}"][aria-current="page"]}, label)

        for other <- @paths,
            other != path,
            do: refute(has_element?(view, ~s{#{part} a[href="#{other}"][aria-current]}))
      end

      assert has_element?(view, "#account-picker summary", label)
    end
  end

  test "the section's heading is the nav's label, said once", %{conn: conn} do
    for {path, label, _, _} <- @sections do
      {:ok, _view, html} = live(conn, path)

      headings =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#account-content h2")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert Enum.count(headings, &(&1 == label)) == 1,
             "#{path} has #{inspect(headings)}, not #{label} once"
    end
  end

  test "each section is its own mount: the nav navigates, never patches", %{conn: conn} do
    for {path, _, _, _} <- @sections, path != "/account" do
      {:ok, view, _} = live(conn, ~p"/account")
      link = element(view, ~s{#account-nav a[href="#{path}"]})
      assert render(link) =~ ~s(data-phx-link="redirect")
      assert {:error, {:live_redirect, %{to: ^path}}} = render_click(link)
    end
  end

  test "the browser title names the section; the landing one is Account", %{conn: conn} do
    for {path, label, _, _} <- @sections do
      {:ok, view, _} = live(conn, path)
      want = if path == "/account", do: "Account", else: label
      assert page_title(view) =~ want
    end
  end

  test "the content sits in a narrow column, in a standard-width page", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/account/tokens")
    assert has_element?(view, ~s{[data-page-width="standard"] #account[data-settings-layout]})
    assert has_element?(view, ~s{#account-content[data-content-width="narrow"]})
  end

  test "Set up an agent stays marked in the avatar menu as the agent page", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/account/agent")
    assert has_element?(view, ~s{#account-nav a[aria-current="page"]}, "Set up an agent")
    assert has_element?(view, ~s{#account-menu a[href="/account/agent"][aria-current="page"]})
    refute has_element?(view, ~s{#account-menu a[href="/account"][aria-current]})

    {:ok, view, _} = live(conn, ~p"/account/sign-in")
    assert has_element?(view, ~s{#account-menu a[href="/account"][aria-current="page"]})
  end

  describe "sections/1" do
    test "lists Email log only while the server takes mail, and never a Voiceprint" do
      keys = fn i -> AccountLive.Index.sections(i) |> Enum.map(&elem(&1, 0)) end

      assert keys.(false) == [:index, :settings, :sign_in, :tokens, :agent, :machines, :data]

      assert keys.(true) == [
               :index,
               :settings,
               :sign_in,
               :tokens,
               :agent,
               :machines,
               :data,
               :email_log
             ]
    end

    test "labels are in sentence case" do
      for {_, _, _, label} <- AccountLive.Index.sections(true) do
        [_first | rest] = String.split(label)
        for word <- rest, word not in ~w(API), do: assert(word == String.downcase(word), label)
      end
    end
  end
end
