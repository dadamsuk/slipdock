defmodule SlipdockWeb.ConfirmDialogTest do
  @moduledoc """
  The app's own confirmation box (#340): one `<dialog>` in the root layout,
  on every page, that `assets/js/confirm.js` opens for anything carrying
  `data-confirm`. What the script does with it is tested under
  `node --test assets/js/**/*.test.js`; this is the markup it relies on.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  defp dialogs(html),
    do: html |> LazyHTML.from_document() |> LazyHTML.query("dialog#confirm-dialog")

  test "renders the hooks confirm.js looks for, and asks nothing on its own" do
    html = rendered_to_string(SlipdockWeb.Layouts.confirm_dialog(%{}))
    doc = LazyHTML.from_fragment(html)
    dialog = LazyHTML.query(doc, "dialog#confirm-dialog")

    assert Enum.count(dialog) == 1
    # Closed until the script calls showModal: a page never loads with it open.
    assert LazyHTML.attribute(dialog, "open") == []
    assert LazyHTML.attribute(dialog, "aria-labelledby") == ["confirm-dialog-message"]

    # The message is empty — it is filled with textContent, never markup.
    assert LazyHTML.query(doc, "#confirm-dialog-message") |> LazyHTML.text() == ""

    # Both answers close the dialog through method="dialog", and only the
    # confirm button's value counts as yes.
    assert LazyHTML.query(doc, "form[method=dialog] button[data-confirm-ok][value=confirm]")
           |> Enum.count() == 1

    assert LazyHTML.query(doc, "form[method=dialog] button[data-confirm-cancel][value=cancel]")
           |> Enum.count() == 1

    # Clicking the backdrop is a no, not a yes.
    assert LazyHTML.query(doc, "form.modal-backdrop[method=dialog] button")
           |> LazyHTML.attribute("value") == ["cancel"]
  end

  test "a signed-in page carries exactly one, outside the LiveView", %{conn: conn, user: user} do
    board = board_fixture(%{}, owner: user)
    html = conn |> get(~p"/boards/#{board}") |> html_response(200)

    assert Enum.count(dialogs(html)) == 1

    # Inside [data-phx-main] it would be patched — and closed — by any update
    # to the board while somebody was halfway through answering it.
    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query("[data-phx-main] #confirm-dialog")
           |> Enum.count() == 0

    # And the board page has something for it to ask about.
    assert html =~ "data-confirm="
  end

  @tag :anonymous
  test "the sign-in page has it too: it is the root layout's, not the app shell's", %{conn: conn} do
    html = conn |> get(~p"/login") |> html_response(200)
    assert Enum.count(dialogs(html)) == 1
  end
end
