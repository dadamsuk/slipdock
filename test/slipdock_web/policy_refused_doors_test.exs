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

  describe "a board's own writes (#3170), when the context refuses what the door let through" do
    setup %{conn: conn} do
      owner = user_fixture("doors3.owner@example.com")
      board = board_fixture(%{"name" => "Doors three"}, owner: owner)
      %{conn: log_in_user(conn, owner), owner: owner, board: board}
    end

    defp nobody_in_page(view) do
      :sys.replace_state(view.pid, fn state ->
        Actor.put(nil)
        Policy.forbid_nobody()
        state
      end)
    end

    test "the board page says a refused new list in a flash", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}")
      nobody_in_page(view)

      render_hook(view, "add_column", %{"name" => "Later"})

      assert render(view) =~ "Changing the board&#39;s lists was asked with nobody acting"
      refute Enum.any?(Boards.get_board!(board.id).columns, &(&1.name == "Later"))
    end

    test "the board index says a refused archive in a flash", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/")
      nobody_in_page(view)

      render_hook(view, "archive", %{"id" => "#{board.id}"})

      assert render(view) =~ "Archiving a board was asked with nobody acting"
      refute Boards.get_board!(board.id).archived_at
    end

    test "MCP's archive_board answers the refusal as a tool error", %{owner: owner, board: board} do
      Actor.put(nil)
      Policy.forbid_nobody()

      assert {:error, "forbidden: Archiving a board was asked with nobody acting" <> _} =
               SlipdockWeb.MCP.Tools.ArchiveBoard.call(%{"board" => board.id}, %{
                 user: owner,
                 token: nil
               })

      refute Boards.get_board!(board.id).archived_at
    end
  end

  describe "the wiki's own writes (#3171), when the context refuses what the door let through" do
    setup %{conn: conn} do
      owner = user_fixture("doors4.owner@example.com")
      board = board_fixture(%{"name" => "Doors four"}, owner: owner)

      {:ok, folder} =
        Policy.as_system("a test fixture", fn ->
          Slipdock.Wiki.create_folder(board, %{"name" => "Shared"})
        end)

      page =
        page_fixture(
          board,
          %{"title" => "Shared page", "body" => "Before.", "folder_id" => folder.id},
          user: owner
        )

      sharee = user_fixture("doors4.sharee@example.com")

      {:ok, _} =
        Policy.as_system("a test fixture", fn ->
          Slipdock.Access.grant(folder, sharee, "write", owner)
        end)

      %{conn: conn, owner: owner, board: board, folder: folder, page: page, sharee: sharee}
    end

    defp nobody_on_page(view) do
      :sys.replace_state(view.pid, fn state ->
        Actor.put(nil)
        Policy.forbid_nobody()
        state
      end)
    end

    test "Shared with me says a refused save in a flash, and the page keeps its words", c do
      {:ok, view, _} = live(log_in_user(c.conn, c.sharee), ~p"/shared/pages/#{c.page.id}/edit")
      nobody_on_page(view)

      view
      |> form("#shared-edit-form", page: %{title: "Shared page", body: "After."})
      |> render_submit()

      assert render(view) =~ "Changing a page was asked with nobody acting"
      assert Slipdock.Wiki.get_page!(c.page.id).body == "Before."
    end

    test "Shared with me says a refused new page in a flash", c do
      {:ok, view, _} = live(log_in_user(c.conn, c.sharee), ~p"/shared/folders/#{c.folder.id}")
      nobody_on_page(view)

      view |> form("#shared-new-page", %{title: "From nobody"}) |> render_submit()

      assert render(view) =~ "Making a page, file or folder there was asked with nobody acting"
      refute Enum.any?(Slipdock.Wiki.list_pages(c.board), &(&1.title == "From nobody"))
    end

    test "the wiki says a refused archive in a flash", c do
      {:ok, view, _} =
        live(log_in_user(c.conn, c.owner), ~p"/boards/#{c.board.id}/wiki/#{c.page.slug}")

      nobody_on_page(view)
      render_hook(view, "archive", %{})

      assert render(view) =~ "That page couldn&#39;t be archived."
      refute Slipdock.Wiki.get_page!(c.page.id).archived_at
    end

    # The door asks write on the page, which the folder's share gives; the
    # list it goes in is the board's, which it doesn't (`Boards.Columns.reorder/4`).
    test "REST answers 403 when a folder sharee puts the page in a list", c do
      {plain, _} = Slipdock.Accounts.create_api_token(c.sharee, "w", scope: "write")
      column = hd(c.board.columns)

      body =
        c.conn
        |> put_req_header("authorization", "Bearer " <> plain)
        |> post("/api/pages/#{c.page.id}/place", %{column: column.id})
        |> json_response(403)

      assert body["error"] =~ "forbidden: Placing something in a list needs write access"
      refute Slipdock.Wiki.get_page!(c.page.id).column_id
    end

    test "MCP's update_page answers a refused archive as a tool error", c do
      {_plain, token} = Slipdock.Accounts.create_api_token(c.owner, "agent", scope: "write")
      Actor.put(nil)
      Policy.forbid_nobody()

      assert {:error,
              "forbidden: Archiving or restoring a page was asked with nobody acting" <> _} =
               SlipdockWeb.MCP.Tools.call(
                 SlipdockWeb.MCP.Tools.UpdatePage,
                 %{"page" => c.page.code, "archived" => true},
                 %{user: c.owner, token: token}
               )

      refute Slipdock.Wiki.get_page!(c.page.id).archived_at
    end
  end

  # One place answers every MCP tool's refusal (#3171): a tool that hands the
  # context's refusal back as it came, or crashes matching it as a success.
  describe "MCP, for a tool that doesn't answer a refusal itself" do
    defmodule Handed do
      def name, do: "handed"
      def input_schema, do: %{type: "object", properties: %{}}

      def call(_args, _context),
        do:
          {:error,
           %Refused{action: :edit_page, by: :user, message: "Changing a page needs write."}}
    end

    defmodule Crashed do
      def name, do: "crashed"
      def input_schema, do: %{type: "object", properties: %{}}

      # Read at run time, so the compiler can't see the match fail.
      def call(_args, _context) do
        {:ok, _} =
          Process.get(
            {__MODULE__, :answer},
            {:error,
             %Refused{action: :edit_page, by: :user, message: "Changing a page needs write."}}
          )
      end
    end

    defmodule Broken do
      def name, do: "broken"
      def input_schema, do: %{type: "object", properties: %{}}

      def call(_args, _context),
        do: {:ok, _} = Process.get({__MODULE__, :answer}, {:error, :something_else})
    end

    test "is answered as one, whichever way it came back" do
      context = %{user: nil, token: nil}

      assert SlipdockWeb.MCP.Tools.call(Handed, %{}, context) ==
               {:error, "forbidden: Changing a page needs write."}

      assert SlipdockWeb.MCP.Tools.call(Crashed, %{}, context) ==
               {:error, "forbidden: Changing a page needs write."}

      assert {:error, "broken failed on the server" <> _} =
               ExUnit.CaptureLog.with_log(fn ->
                 SlipdockWeb.MCP.Tools.call(Broken, %{}, context)
               end)
               |> elem(0)
    end
  end

  describe "a person's own rows and the server's accounts (#3172), when the context refuses what the door let through" do
    setup %{conn: conn} do
      owner = user_fixture("doors5.owner@example.com")
      board = board_fixture(%{"name" => "Doors five"}, owner: owner)
      %{conn: conn, owner: owner, board: board}
    end

    defp nobody_here(view) do
      :sys.replace_state(view.pid, fn state ->
        Actor.put(nil)
        Policy.forbid_nobody()
        state
      end)
    end

    # The controller called as the door calls it, with nobody acting: the
    # pipeline's own checks are behind it, and only the context refuses.
    defp as_nobody(conn, controller, action, params, user) do
      Actor.put(nil)
      Policy.forbid_nobody()

      conn
      |> Map.put(:params, params)
      |> Map.put(:body_params, params)
      |> Plug.Conn.assign(:current_user, user)
      |> Phoenix.Controller.put_format("json")
      |> controller.call(controller.init(action))
    end

    test "Groups says a refused new group in a flash, and makes none", c do
      {:ok, view, _} = live(log_in_user(c.conn, c.owner), ~p"/groups")
      nobody_here(view)

      view |> form("#new-group-0", %{"name" => "Crew"}) |> render_submit()

      assert render(view) =~ "Your own groups was asked with nobody acting"
      assert Slipdock.Accounts.list_groups(c.owner) == []
    end

    test "the tokens page says a refused new token in a flash, and mints none", c do
      {:ok, view, _} = live(log_in_user(c.conn, c.owner), ~p"/account/tokens")
      nobody_here(view)

      view |> element("form[phx-submit=create_token]") |> render_submit(%{"label" => "CI"})

      assert render(view) =~ "Your own sign-ins and API tokens was asked with nobody acting"
      assert Slipdock.Accounts.list_api_tokens(c.owner) == []
    end

    test "REST: My work's mute answers 403", c do
      conn =
        as_nobody(
          c.conn,
          SlipdockWeb.API.WorkController,
          :mute,
          %{"board" => "#{c.board.id}"},
          c.owner
        )

      assert json_response(conn, 403)["error"] =~ "Your own My work list"
    end

    test "REST: a display setting answers 403, not a bad value", c do
      conn =
        as_nobody(
          c.conn,
          SlipdockWeb.API.MeController,
          :put_display,
          %{"tree_names" => "short"},
          c.owner
        )

      assert json_response(conn, 403)["error"] =~ "Your own settings"
    end

    test "REST: a header link answers 403, not an unprocessable one", c do
      params = %{"board" => "#{c.board.id}", "icon" => hd(Slipdock.Wiki.Icons.names())}
      conn = as_nobody(c.conn, SlipdockWeb.API.HeaderLinkController, :create, params, c.owner)
      assert json_response(conn, 403)["error"] =~ "Your own saved views"
    end

    test "REST: unsaving a search answers 403", c do
      conn = as_nobody(c.conn, SlipdockWeb.API.SearchController, :unsave, %{"id" => "1"}, c.owner)
      assert json_response(conn, 403)["error"] =~ "Your own saved views"
    end

    test "REST: closing an account answers 403", c do
      {:ok, admin} =
        Policy.as_system("a test fixture", fn -> Slipdock.Accounts.promote(c.owner) end)

      gone = user_fixture("doors5.gone@example.com")
      params = %{"id" => "#{gone.id}", "confirm" => gone.email}
      conn = as_nobody(c.conn, SlipdockWeb.API.AdminController, :delete_user, params, admin)
      assert json_response(conn, 403)["error"] =~ "Running this server's accounts"
      assert Slipdock.Accounts.get_user(gone.id)
    end

    test "a passkey refused answers 403", c do
      challenge =
        Wax.new_registration_challenge(origin: "https://example.com", rp_id: "example.com")

      Actor.put(nil)
      Policy.forbid_nobody()

      conn =
        c.conn
        |> Plug.Test.init_test_session(%{passkey_registration_challenge: challenge})
        |> Map.put(:params, %{})
        |> Plug.Conn.assign(:current_user, c.owner)
        |> SlipdockWeb.PasskeyController.call(SlipdockWeb.PasskeyController.init(:create))

      assert json_response(conn, 403)["error"] =~ "Your own sign-ins"
    end
  end
end
