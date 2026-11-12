defmodule SlipdockWeb.CardPhoneLiveTest do
  @moduledoc """
  The card back on a phone (#1729): the properties come first, as a summary
  under the title that opens onto their rows, and can be changed from there;
  the sidebar then leaves them out. A desktop is unchanged.
  `tools/e2e/card-phone.sh` checks the first screen at 390px in a browser.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Plan the launch"})
    %{board: board, card: card, owner: owner}
  end

  defp open(conn, ctx), do: live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

  defp change(view, params),
    do: view |> form("#card-phone-props-form", card: params) |> render_change()

  describe "on a phone" do
    test "a blank card's summary says so, field by field", ctx do
      {:ok, view, _} = open(phone(ctx.conn), ctx)

      assert has_element?(view, "#card-phone-summary [data-summary=assignee]", "Unassigned")
      assert has_element?(view, "#card-phone-summary [data-summary=due]", "No due date")
      assert has_element?(view, "#card-phone-summary [data-summary=priority]", "No priority")
    end

    test "a property the card view hides leaves the summary and the rows (#2070)", ctx do
      {:ok, _} =
        Slipdock.CardViews.update_level(ctx.owner, {:board, ctx.board}, %{
          "hide" => "side.due,side.priority"
        })

      {:ok, view, _} = open(phone(ctx.conn), ctx)

      refute has_element?(view, "#card-phone-summary [data-summary=due]")
      refute has_element?(view, "#card-phone-summary [data-summary=priority]")
      refute has_element?(view, "#card-phone-props [data-prop=due]")
      refute has_element?(view, "#card-phone-props [data-prop=priority]")
      assert has_element?(view, "#card-phone-summary [data-summary=assignee]")
      assert has_element?(view, "#card-phone-props [data-prop=assignees]")
    end

    test "the summary reads who, when it is due and how urgent", ctx do
      {:ok, _} =
        Boards.Cards.update_card(ctx.card, %{
          "priority" => "high",
          "due_date" => ~D[2030-03-18],
          "assignee_id" => ctx.owner.id
        })

      {:ok, view, _} = open(phone(ctx.conn), ctx)

      name = Slipdock.Accounts.User.display_name(ctx.owner)
      assert has_element?(view, "#card-phone-summary [data-summary=assignee]", name)
      assert has_element?(view, "#card-phone-summary [data-summary=due]", "Due 18 Mar 2030")
      assert has_element?(view, "#card-phone-summary [data-summary=priority]", "High")
    end

    test "it comes before the long sections, and opens onto the rows", ctx do
      {:ok, view, html} = open(phone(ctx.conn), ctx)

      # Straight after the title's block, before Flags and the description.
      {summary_at, _} = :binary.match(html, ~s(id="card-phone-summary"))
      {flags_at, _} = :binary.match(html, ~s(id="card-flags"))
      {desc_at, _} = :binary.match(html, ~s(data-section-key="d"))
      assert summary_at < flags_at and flags_at < desc_at

      assert has_element?(
               view,
               ~s(#card-phone-summary[aria-controls="card-phone-props"][aria-expanded="false"])
             )

      assert has_element?(view, "#card-phone-props[hidden] #card-phone-props-form #card-priority")
      assert view |> element("#card-phone-summary") |> render() =~ "toggle_attr"

      # Drawn once: the sidebar leaves its rows out.
      refute has_element?(view, "aside #card-props")
      assert has_element?(view, "aside #card-meta-form")
    end

    test "each property changes from the phone's rows", ctx do
      ada = user_fixture("phone.ada@example.com")
      {:ok, _} = Access.grant(ctx.board, ada, "write", ctx.owner)
      {:ok, view, _} = open(phone(ctx.conn), ctx)

      change(view, %{priority: "critical"})
      assert Boards.Cards.get_card!(ctx.card.id).priority == "critical"
      assert has_element?(view, "#card-phone-summary [data-summary=priority]", "Critical")

      change(view, %{due_date: "2030-01-20"})
      assert Boards.Cards.get_card!(ctx.card.id).due_date == ~D[2030-01-20]
      assert has_element?(view, "#card-phone-summary [data-summary=due]", "Due 20 Jan 2030")

      change(view, %{add_assignee_id: ada.id})
      assert [%{id: id}] = Boards.Cards.get_card!(ctx.card.id).assignees
      assert id == ada.id
      assert has_element?(view, "#card-phone-summary [data-summary=assignee]", "phone.ada")

      change(view, %{percent_complete: "60"})
      assert Boards.Cards.get_card!(ctx.card.id).percent_complete == 60

      change(view, %{date_precision: "month"})
      assert Boards.Cards.get_card!(ctx.card.id).date_precision == "month"

      html = change(view, %{start_date: "2030-02-01", due_date: "2030-01-01"})
      assert html =~ "Start must be on or before the due date."
    end

    test "a reader's rows are in a disabled fieldset", ctx do
      reader = user_fixture("phone.reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
      {:ok, view, _} = open(phone(log_in_user(build_conn(), reader)), ctx)

      assert has_element?(view, "fieldset[disabled] #card-phone-props-form #card-priority")
    end
  end

  test "a desktop is unchanged: the rows in the sidebar, no summary", ctx do
    {:ok, view, _} = open(ctx.conn, ctx)

    refute has_element?(view, "#card-phone-summary")
    refute has_element?(view, "#card-phone-props-form")
    assert has_element?(view, "aside #card-meta-form #card-props #card-priority")
  end

  test "the layout follows the window when it is resized", ctx do
    {:ok, view, _} = open(ctx.conn, ctx)
    refute has_element?(view, "#card-phone-summary")

    view |> element("#viewport") |> render_hook("viewport", %{"width" => 375})
    assert has_element?(view, "#card-phone-summary")
    refute has_element?(view, "aside #card-props")

    view |> element("#viewport") |> render_hook("viewport", %{"width" => 1280})
    refute has_element?(view, "#card-phone-summary")
    assert has_element?(view, "aside #card-props")
  end
end
