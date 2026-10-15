defmodule SlipdockWeb.TemplateLiveTest do
  @moduledoc "/templates offers edit and delete only on a person's own templates (#856)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.Template
  alias Slipdock.Repo

  setup %{user: user} do
    stranger = user_fixture("templates-page-stranger@example.com")
    n = System.unique_integer([:positive])
    {:ok, simple} = Boards.find_template(nil, "Simple")
    {:ok, mine} = Boards.create_template(user, %{"name" => "Mine #{n}", "columns" => ["A"]})

    {:ok, theirs} =
      Boards.create_template(stranger, %{"name" => "Theirs #{n}", "columns" => ["B"]})

    %{simple: simple, mine: mine, theirs: theirs}
  end

  test "built-ins are marked and have no Edit; one's own has; others' aren't shown", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/templates")

    assert has_element?(view, "#template-#{ctx.simple.id}", "Built-in")
    refute has_element?(view, "#template-#{ctx.simple.id} button", "Edit")
    assert has_element?(view, "#template-#{ctx.mine.id} button", "Edit")
    refute has_element?(view, "#template-#{ctx.mine.id}", "Built-in")
    refute has_element?(view, "#template-#{ctx.theirs.id}")
  end

  test "an edit or delete sent for a built-in is refused, and changes nothing", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/templates")

    html = render_click(view, "edit", %{"id" => ctx.simple.id})
    assert html =~ "Built-in templates can&#39;t be changed."
    refute has_element?(view, "#template-form")

    render_click(view, "delete", %{"id" => ctx.simple.id})
    assert Repo.get(Template, ctx.simple.id)
  end

  test "an edit or delete sent for somebody else's template is refused", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/templates")

    assert render_click(view, "edit", %{"id" => ctx.theirs.id}) =~ "That template has gone."
    refute has_element?(view, "#template-form")

    render_click(view, "delete", %{"id" => ctx.theirs.id})
    assert Repo.get(Template, ctx.theirs.id)
  end

  test "one's own can be edited and deleted", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/templates")

    view |> element("#template-#{ctx.mine.id} button", "Edit") |> render_click()
    view |> form("#template-form", %{"name" => "Renamed"}) |> render_submit()
    assert Repo.get!(Template, ctx.mine.id).name == "Renamed"

    view |> element("#template-#{ctx.mine.id} button", "Edit") |> render_click()
    view |> element("#template-form button", "Delete") |> render_click()
    refute Repo.get(Template, ctx.mine.id)
  end

  test "the new-board picker offers built-ins and one's own only", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_click(view, "start_create", %{})
    html = render(view)

    assert html =~ ctx.simple.name
    assert html =~ ctx.mine.name
    refute html =~ ctx.theirs.name
  end
end
