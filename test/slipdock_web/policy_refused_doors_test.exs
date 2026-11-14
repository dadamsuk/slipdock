defmodule SlipdockWeb.PolicyRefusedDoorsTest do
  @moduledoc """
  A write the context refuses (`Slipdock.Policy`, #3168) comes back through
  each door as that door's own refusal: a 403 on REST, a tool error on MCP,
  and words in the Tags panel and the card panel (#3167). Policy 2 (#3169)
  adds the card's own writes: a board panel says the refusal whatever its
  handler made of it (`PanelGuard`, `SlipdockWeb.Refusals`), the board page
  in a flash; and a request starts with nobody acting.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Policy}
  alias Slipdock.Policy.Refused
  alias SlipdockWeb.API.FallbackController
  alias SlipdockWeb.MCP.Args

  defp refused(by) do
    {:error,
     %Refused{action: :create_tag, need: :write, by: by, message: "Making a tag needs write."}}
  end

  test "REST answers 403 with the refusal", %{conn: conn} do
    conn = FallbackController.call(conn, refused(:token))

    assert json_response(conn, 403) == %{"error" => "forbidden: Making a tag needs write."}
  end

  test "MCP answers a tool error with the refusal" do
    assert Args.refusal(refused(:user)) == {:error, "forbidden: Making a tag needs write."}
  end

  describe "the panels, when the context refuses what the door let through" do
    setup %{conn: conn} do
      owner = user_fixture("doors.owner@example.com")
      board = board_fixture(%{"name" => "Doors"}, owner: owner)
      card = card_fixture(hd(board.columns), %{"title" => "Card"})
      tag = tag_fixture(board, "ops")

      {:ok, _} =
        Policy.as_system("a test fixture", fn -> Boards.Tags.toggle_card_tag(card, tag) end)

      %{conn: log_in_user(conn, owner), owner: owner, board: board, card: card, tag: tag}
    end

    # The LiveView's process is the door: after mount, its actor is made
    # nobody, so the panel's own guard (the owner's level) passes and only
    # the context refuses.
    defp nobody_in(view) do
      :sys.replace_state(view.pid, fn state ->
        Actor.put(nil)
        Policy.forbid_nobody()
        state
      end)
    end

    test "the Tags panel says it, and the tag stays", %{conn: conn, board: board, tag: tag} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}/tags")
      nobody_in(view)

      html = view |> element("#delete-tag-#{tag.id}") |> render_click()
      assert html =~ "nobody acting"
      assert Enum.map(Boards.Tags.list_tags(board.id), & &1.name) == ["ops"]
    end

    test "the card panel says it, and the card keeps its tags",
         %{conn: conn, board: board, card: card, tag: tag} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}/cards/#{card.id}")
      nobody_in(view)

      view
      |> element("#card-tag-pick-#{tag.id}")
      |> render_click()

      assert view |> element("#card-modal #panel-notice[data-callout=error]") |> render() =~
               "Tag not changed"

      assert Enum.map(Slipdock.Repo.preload(card, :tags, force: true).tags, & &1.name) == ["ops"]
    end
  end

  describe "a card's own writes (#3169), when the context refuses what the door let through" do
    setup %{conn: conn} do
      owner = user_fixture("doors2.owner@example.com")
      board = board_fixture(%{"name" => "Doors two"}, owner: owner)
      card = card_fixture(hd(board.columns), %{"title" => "Card"})
      %{conn: log_in_user(conn, owner), owner: owner, board: board, card: card}
    end

    defp nobody_in_view(view) do
      :sys.replace_state(view.pid, fn state ->
        Actor.put(nil)
        Policy.forbid_nobody()
        state
      end)
    end

    defp comments(card), do: Boards.Cards.get_card!(card.id).comments

    test "the card panel says a refused comment, which its handler matched as {:ok, _}",
         %{conn: conn, board: board, card: card} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}/cards/#{card.id}")
      nobody_in_view(view)

      view
      |> element("#card-modal form[id^=add-comment]")
      |> render_submit(%{"body" => "Not from anybody"})

      assert view |> element("#card-modal #panel-notice[data-callout=error]") |> render() =~
               "Commenting was asked with nobody acting"

      assert comments(card) == []
      assert Process.alive?(view.pid)
    end

    test "the card panel says a refused tick box, which its handler ignored",
         %{conn: conn, board: board, card: card} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}/cards/#{card.id}")
      nobody_in_view(view)

      view
      |> element("#card-modal form[id^=add-check]")
      |> render_submit(%{"text" => "Step"})

      assert view |> element("#card-modal #panel-notice[data-callout=error]") |> render() =~
               "Changing a checklist was asked with nobody acting"

      assert Boards.Cards.get_card!(card.id).checklist_items == []
    end

    test "the board page says a refused quick add in a flash, in its own words", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}")
      nobody_in_view(view)

      render_hook(view, "quick_add_card", %{"title" => "From nobody"})

      # Its own words for any card it couldn't add.
      assert render(view) =~ "Couldn&#39;t add that card."

      refute Enum.any?(Boards.get_board!(board.id).columns, fn c ->
               Enum.any?(c.cards, &(&1.title == "From nobody"))
             end)
    end

    test "My work says a refused completion in a flash", %{conn: conn, owner: owner, card: card} do
      {:ok, _} =
        Policy.as_system("a test fixture", fn ->
          Boards.Cards.update_card(card, %{"assignee_ids" => [owner.id]})
        end)

      {:ok, view, _} = live(conn, ~p"/work")
      nobody_in_view(view)

      render_hook(view, "toggle_complete", %{"id" => "#{card.id}"})

      assert render(view) =~ "Changing a card was asked with nobody acting"
      refute Boards.Cards.get_card!(card.id).completed
    end

    test "the wiki says a refused comment on a page in a flash", %{conn: conn, board: board} do
      page = page_fixture(board, %{"title" => "Notes"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}/wiki/#{page.slug}")
      nobody_in_view(view)

      render_hook(view, "add_comment", %{"body" => "Not from anybody"})

      assert render(view) =~ "Commenting was asked with nobody acting"
      assert Slipdock.Repo.preload(page, :comments, force: true).comments == []
    end

    test "MCP's comment tool answers the refusal as a tool error", %{owner: owner, card: card} do
      Actor.put(nil)
      Policy.forbid_nobody()

      assert {:error, "forbidden: Commenting was asked with nobody acting" <> _} =
               SlipdockWeb.MCP.Tools.Comment.call(
                 %{"card" => card.id, "body" => "Not from anybody"},
                 %{user: owner, token: nil}
               )

      assert comments(card) == []
    end
  end

  describe "REST, where the door and the context disagree (#3169)" do
    # A sub-board writer passes the fields door (write on the board named),
    # but fields are the tree's, kept on its root, as tags are: the context
    # asks write on the root, and REST answers its refusal as a 403.
    test "a sub-board writer's new field is refused by the context, as a 403", %{conn: conn} do
      owner = user_fixture("doors2.root@example.com")
      root = board_fixture(%{"name" => "Root two"}, owner: owner)
      epic = card_fixture(hd(root.columns), %{"title" => "Epic"})
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(epic, t)
      writer = user_fixture("doors2.sub-writer@example.com")
      {:ok, _} = Slipdock.Access.grant(epic, writer, "write", owner)
      {plain, _} = Slipdock.Accounts.create_api_token(writer, "w", scope: "write")

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> plain)
        |> post("/api/boards/#{sub.id}/fields", %{name: "Effort", kind: "number"})
        |> json_response(403)

      assert body["error"] =~
               "forbidden: Changing a custom field needs write access to the top board"

      assert Slipdock.Fields.list_fields(root.id) == []
    end
  end

  describe "a request starts with nobody acting (#3169)" do
    # Bandit serves a keep-alive connection's requests in one process: what
    # the last request set must not act for the next.
    test "the endpoint forgets the process's actor before the request runs", %{conn: conn} do
      owner = user_fixture("doors2.leftover@example.com")
      Actor.put(Actor.web(owner), nil, {owner, nil})

      conn |> get("/install.sh") |> response(200)

      assert Actor.current() == Actor.unknown()
      assert Actor.principal() == {nil, nil}
    end
  end
end
