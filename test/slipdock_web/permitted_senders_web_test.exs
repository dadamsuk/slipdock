defmodule SlipdockWeb.PermittedSendersWebTest do
  @moduledoc """
  A board's permitted senders (#1289) in the web app and over the API: set
  in Board settings and with `PATCH /api/boards/:board`, listed with the
  board's addresses and in its *Email to this board* dialog.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, TestConfig}

  setup %{conn: conn, user: owner} do
    TestConfig.put(:inbound, domain: "in.example.com", secrets: ["s"])
    board = board_fixture(%{}, owner: owner)
    %{board: board, owner: owner, json: put_req_header(conn, "accept", "application/json")}
  end

  defp json_as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  describe "Board settings" do
    test "sets the list one per line, and refuses what isn't an address", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
      assert has_element?(view, "#board-form-inbound-senders")

      view
      |> form("#board-form", board: %{"inbound_senders" => "ann@example.com\nnope"})
      |> render_submit()

      assert render(view) =~ "aren&#39;t email addresses: nope"
      assert Boards.get_board!(ctx.board.id).inbound_senders == []

      view
      |> form("#board-form", board: %{"inbound_senders" => "Ann@example.com\nbob@example.com"})
      |> render_submit()

      assert Boards.get_board!(ctx.board.id).inbound_senders ==
               ["ann@example.com", "bob@example.com"]

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")

      assert view |> element("#board-form-inbound-senders") |> render() =~
               "ann@example.com\nbob@example.com"
    end

    test "isn't offered while the server takes no mail", ctx do
      TestConfig.put(:inbound, domain: nil, secrets: [])
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
      refute has_element?(view, "#board-form-inbound-senders")
    end
  end

  describe "Email to this board" do
    test "names the permitted senders when there are any", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board.id}")
      view |> element("#board-share-inbound") |> render_click()
      refute has_element?(view, "#board-inbound-senders")

      {:ok, _} = Boards.update_board(ctx.board, %{"inbound_senders" => "ann@example.com"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board.id}")
      view |> element("#board-share-inbound") |> render_click()
      assert view |> element("#board-inbound-senders") |> render() =~ "ann@example.com"
    end
  end

  describe "the API" do
    test "PATCH sets and clears the list; the owner reads it back", ctx do
      body =
        ctx.json
        |> patch(~p"/api/boards/#{ctx.board.code}", %{
          "inbound_senders" => ["Ann@example.com", "bob@example.com"]
        })
        |> json_response(200)

      assert body["board"]["inbound_senders"] == ["ann@example.com", "bob@example.com"]

      body =
        ctx.json
        |> patch(~p"/api/boards/#{ctx.board.code}", %{"inbound_senders" => ""})
        |> json_response(200)

      assert body["board"]["inbound_senders"] == []

      assert ctx.json
             |> patch(~p"/api/boards/#{ctx.board.code}", %{"inbound_senders" => "nope"})
             |> json_response(422)
    end

    test "only the owner may change it", ctx do
      writer = user_fixture("writer@example.com")
      share_fixture(ctx.board, writer, "write")

      assert json_as(writer)
             |> patch(~p"/api/boards/#{ctx.board.code}", %{"inbound_senders" => "x@example.com"})
             |> json_response(403)

      assert Boards.get_board!(ctx.board.id).inbound_senders == []
    end

    test "the board's addresses list them, for anybody who can write to it", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"inbound_senders" => "ann@example.com"})
      writer = user_fixture("writer@example.com")
      share_fixture(ctx.board, writer, "write")

      body = json_as(writer) |> get("/api/boards/#{ctx.board.id}/inbound") |> json_response(200)
      assert body["senders"] == ["ann@example.com"]
    end
  end
end
