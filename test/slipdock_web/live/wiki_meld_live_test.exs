defmodule SlipdockWeb.WikiMeldLiveTest do
  @moduledoc """
  Encrypting in the page editor (W-103 R6.2, R6.4), from the server's side:
  the secret is typed outside the page form, the browser is given the
  revisions to match against, and a save can purge the ones it names — for
  the owner only. The browser's half is in assets/js/meld_editor.test.js.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Wiki}

  @vector "test/support/fixtures/meld_vectors.json"
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("inline")
          |> hd()

  setup %{user: user} do
    board = board_fixture(%{"name" => "Vault"}, owner: user)
    page = page_fixture(board, %{"title" => "Bank", "body" => "PIN 4921"}, user: user)
    {:ok, page} = Wiki.update_page(page, %{"body" => "PIN 4921, again"}, user: user, via: "api")
    %{board: board, page: page}
  end

  test "the editor has the Meld tools, and the secret's box is outside the page form",
       %{conn: conn, board: board, page: page} do
    html = conn |> get(~p"/boards/#{board}/wiki/#{page.slug}/edit") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert doc
           |> LazyHTML.query("#meld-tools[phx-hook=MeldEditor] [data-meld-action=encrypt]")
           |> Enum.count() == 1

    assert doc |> LazyHTML.query("#meld-tools [data-meld-action=whole]") |> Enum.count() == 1
    assert doc |> LazyHTML.query("#meld-tools [data-meld-action=edit]") |> Enum.count() == 1
    assert doc |> LazyHTML.query("#page-form input[name=purge_revisions]") |> Enum.count() == 1

    # The dialog's form only ever closes the dialog; nothing in it is in the
    # page form, which is what LiveView sends on every change.
    assert doc
           |> LazyHTML.query("#meld-dialog form[method=dialog] [data-meld-text]")
           |> Enum.count() == 1

    assert doc |> LazyHTML.query("#meld-dialog [data-meld-passphrase]") |> Enum.count() == 1

    assert doc
           |> LazyHTML.query("#page-form [data-meld-text], #page-form [data-meld-passphrase]")
           |> Enum.count() == 0

    assert doc |> LazyHTML.query("#meld-dialog [name]") |> Enum.count() == 0
  end

  test "the browser is given every revision to match against, and told it can purge",
       %{conn: conn, board: board, page: page} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
    render_hook(view, "meld_history", %{})

    assert_reply(view, %{
      revisions: [%{body: "PIN 4921"}, %{body: "PIN 4921, again"}],
      owner: true
    })
  end

  test "a writer who isn't the owner gets the revisions but is told they can't purge",
       %{board: board, page: page, user: owner} do
    writer = user_fixture("meld.live.writer@example.com")
    {:ok, _} = Access.grant(board, writer, "write", owner)

    {:ok, view, _html} =
      build_conn() |> log_in_user(writer) |> live(~p"/boards/#{board}/wiki/#{page.slug}/edit")

    render_hook(view, "meld_history", %{})
    assert_reply(view, %{revisions: [_, _], owner: false})
  end

  test "a new page has no history to give", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/new")
    render_hook(view, "meld_history", %{})
    assert_reply(view, %{revisions: [], owner: false})
  end

  test "saving with the encrypted text stores only ciphertext, and purges the revisions named",
       %{conn: conn, board: board, page: page} do
    [first, second] = Wiki.revision_bodies(page)
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
    body = "PIN #{@vector["text"]}"

    view
    |> form("#page-form", page: %{title: "Bank", body: body})
    |> render_submit(%{"purge_revisions" => "#{first.id},#{second.id}"})

    assert Wiki.get_page!(page.id).body == body
    # The save's own revision is the newest, holds only ciphertext, and is
    # kept; the two that held the PIN in plain are gone.
    assert Enum.map(Wiki.revision_bodies(page), & &1.body) == [body]
    assert render(view) =~ "2 earlier revisions that held the text in plain were purged"
  end

  test "a writer who isn't the owner saves, but purges nothing", %{
    board: board,
    page: page,
    user: owner
  } do
    writer = user_fixture("meld.live.writer2@example.com")
    {:ok, _} = Access.grant(board, writer, "write", owner)
    [first, _] = Wiki.revision_bodies(page)

    {:ok, view, _html} =
      build_conn() |> log_in_user(writer) |> live(~p"/boards/#{board}/wiki/#{page.slug}/edit")

    view
    |> form("#page-form", page: %{title: "Bank", body: "PIN #{@vector["text"]}"})
    |> render_submit(%{"purge_revisions" => "#{first.id}"})

    assert render(view) =~ "Only the board&#39;s owner can purge"
    assert Enum.any?(Wiki.revision_bodies(page), &(&1.id == first.id))
  end
end
