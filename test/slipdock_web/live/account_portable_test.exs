defmodule SlipdockWeb.AccountPortableTest do
  @moduledoc """
  Taking boards out and bringing them in from the account page.

  The decisions worth a test: the picker only ever offers boards this person
  **owns**, the download link carries exactly what was picked, and an import
  that will not fit says so and builds nothing.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Portable, Settings}

  setup %{conn: conn} do
    user = user_fixture()
    board = board_fixture(%{"name" => "Delivery", "code" => "del"}, owner: user)
    [_backlog, todo | _] = board.columns
    _card = card_fixture(todo, %{"title" => "Ship it"})

    %{conn: log_in_user(conn, user), user: user, board: board}
  end

  describe "taking boards out" do
    test "the section offers the boards you own", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/account/data")

      assert html =~ "Move boards between servers"
      assert html =~ "Delivery"
      assert html =~ "Download every board you own"
    end

    test "a board shared with you is not offered — it is not yours to hand on", %{
      conn: conn,
      user: user
    } do
      theirs =
        board_fixture(%{"name" => "Somebody Else's"}, owner: user_fixture("them@example.com"))

      {:ok, _} = Access.grant(theirs, user, "write", theirs.owner)

      {:ok, view, _html} = live(conn, ~p"/account/data")

      # Their name turns up elsewhere on the page — the quick-add board picker
      # offers every board you can write to — so the test is about the picker
      # here, not about the whole document.
      assert has_element?(
               view,
               "button[phx-click='pick_board'][phx-value-id='#{board_id(user)}']"
             )

      refute has_element?(view, "button[phx-click='pick_board'][phx-value-id='#{theirs.id}']")
    end

    defp board_id(user), do: user |> owned() |> hd() |> Map.fetch!(:id)

    test "picking one narrows the download link to it", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/account/data")

      html =
        view
        |> element("button[phx-click='pick_board'][phx-value-id='#{board.id}']")
        |> render_click()

      assert html =~ "boards=#{board.id}"
      assert html =~ "Download 1 board(s)"
    end

    test "picking it again goes back to all of them", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/account/data")
      button = "button[phx-click='pick_board'][phx-value-id='#{board.id}']"

      view |> element(button) |> render_click()
      html = view |> element(button) |> render_click()

      assert html =~ "Download every board you own"
      refute html =~ "boards=#{board.id}"
    end

    test "the archived switch shows up in the link", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account/data")

      html = view |> element("input[phx-click='toggle_archived']") |> render_click()
      assert html =~ "archived=all"
    end

    test "the link really downloads a document", %{conn: conn} do
      conn = get(conn, ~p"/account/boards.json")

      assert response_content_type(conn, :json)
      assert ["attachment; filename=" <> _] = get_resp_header(conn, "content-disposition")

      document = conn |> response(200) |> Jason.decode!()
      assert document["slipdock_portable"] == Portable.format_version()
      assert [%{"root" => %{"name" => "Delivery"}}] = document["boards"]
    end

    test "the download never includes a board you only share", %{conn: conn, user: user} do
      theirs =
        board_fixture(%{"name" => "Theirs", "code" => "thr"},
          owner: user_fixture("them@example.com")
        )

      {:ok, _} = Access.grant(theirs, user, "write", theirs.owner)

      # Asked for by name, and still left out.
      document =
        conn |> get(~p"/account/boards.json?boards=thr") |> response(200) |> Jason.decode!()

      assert document["boards"] == []
    end
  end

  describe "bringing boards in" do
    defp upload(view, document) do
      view
      |> file_input("#import-boards", :board_document, [
        %{
          name: "boards.json",
          content: document,
          type: "application/json"
        }
      ])
    end

    test "a document from this server goes back in as a new board", %{conn: conn, user: user} do
      document = user |> Portable.export() |> Jason.encode!()
      {:ok, view, _} = live(conn, ~p"/account/data")

      upload(view, document) |> render_upload("boards.json")
      html = view |> element("#import-boards") |> render_submit()

      assert html =~ "1 card(s) and 0 page(s) came in"
      # A new board rather than a merge into the one already here.
      assert length(owned(user)) == 2
    end

    test "the new board's code is reissued, and the page says so", %{conn: conn, user: user} do
      document = user |> Portable.export() |> Jason.encode!()
      {:ok, view, _} = live(conn, ~p"/account/data")

      upload(view, document) |> render_upload("boards.json")
      html = view |> element("#import-boards") |> render_submit()

      assert html =~ "was taken"
    end

    test "something that is not an export says what is wrong", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account/data")

      upload(view, ~s({"boards": []})) |> render_upload("boards.json")
      html = view |> element("#import-boards") |> render_submit()

      assert html =~ "not a Slipdock export"
    end

    test "a Trello board's JSON comes in, and says what stayed behind", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _} = live(conn, ~p"/account/data")

      upload(view, File.read!("test/support/fixtures/trello_board.json"))
      |> render_upload("boards.json")

      html = view |> element("#import-boards") |> render_submit()

      assert html =~ "5 card(s) and 0 page(s) came in"
      assert html =~ "archived list on Trello stayed behind"
      assert length(owned(user)) == 2
    end

    test "a file that is not JSON at all" do
      {:ok, view, _} = live(log_in_user(build_conn(), user_fixture()), ~p"/account/data")

      upload(view, "nonsense{") |> render_upload("boards.json")
      html = view |> element("#import-boards") |> render_submit()

      assert html =~ "not JSON"
    end

    test "a document that will not fit builds nothing", %{conn: conn, user: user, board: board} do
      [_backlog, todo | _] = Boards.get_board!(board.id).columns
      _second = card_fixture(todo, %{"title" => "And another"})

      {:ok, _} = Settings.complete_setup(%{"admin_email" => "a@example.com"})
      {:ok, _} = Settings.update(%{"free_card_limit" => 3})

      document = user |> Portable.export() |> Jason.encode!()
      {:ok, view, _} = live(conn, ~p"/account/data")

      upload(view, document) |> render_upload("boards.json")
      html = view |> element("#import-boards") |> render_submit()

      assert html =~ "room for 1"
      assert html =~ "half a board is worse than none"
      assert length(owned(user)) == 1
    end
  end

  defp owned(user) do
    Slipdock.Repo.all(
      from(b in Slipdock.Boards.Board,
        where: b.owner_id == ^user.id and is_nil(b.parent_card_id)
      )
    )
  end
end
