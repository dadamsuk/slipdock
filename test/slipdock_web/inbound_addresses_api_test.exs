defmodule SlipdockWeb.InboundAddressesAPITest do
  @moduledoc """
  Your inbound addresses over HTTP (#1246): `GET /api/boards/:board/inbound`,
  `GET /api/me/inbound`, and rotating each.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, TestConfig}
  alias Slipdock.Inbound.Tokens

  @domain "in.example.com"

  setup %{user: owner} do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    board = board_fixture(%{}, owner: owner)
    %{owner: owner, board: board}
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  defp with_token(user, opts) do
    {token, _} = Accounts.create_api_token(user, "limited", opts)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  describe "GET /api/boards/:board/inbound" do
    test "your card address for the board, by id or code", ctx do
      body = as(ctx.owner) |> get("/api/boards/#{ctx.board.id}/inbound") |> json_response(200)
      {:ok, card} = Tokens.address(ctx.owner, ctx.board, :card)

      assert body["domain"] == @domain

      assert body["board"] == %{
               "id" => ctx.board.id,
               "code" => ctx.board.code,
               "name" => ctx.board.name
             }

      # The page address waits for mail to pages (#1251).
      assert body["addresses"] == %{"card" => card}

      assert as(ctx.owner)
             |> get("/api/boards/#{ctx.board.code}/inbound")
             |> json_response(200)
             |> get_in(["addresses", "card"]) == card
    end

    test "a reader is refused, and a stranger sees no board", ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")
      stranger = user_fixture("stranger@example.com")

      assert as(reader) |> get("/api/boards/#{ctx.board.id}/inbound") |> json_response(403)
      assert as(stranger) |> get("/api/boards/#{ctx.board.id}/inbound") |> json_response(404)
    end

    test "404 while inbound mail is off", ctx do
      TestConfig.put(:inbound, [])

      assert %{"error" => "inbound email is off on this server"} =
               as(ctx.owner) |> get("/api/boards/#{ctx.board.id}/inbound") |> json_response(404)
    end
  end

  describe "POST /api/boards/:board/inbound/rotate" do
    test "a new address; the old one no longer resolves", ctx do
      {:ok, old} = Tokens.address(ctx.owner, ctx.board, :card)

      %{"addresses" => %{"card" => new}} =
        as(ctx.owner) |> post("/api/boards/#{ctx.board.id}/inbound/rotate") |> json_response(200)

      assert new != old
      assert Tokens.resolve(old) == {:error, :revoked}
      assert {:ok, {:card, _, _}} = Tokens.resolve(new)
    end

    test "not with a read-only token, nor by a reader", ctx do
      {:ok, old} = Tokens.address(ctx.owner, ctx.board, :card)
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")

      with_token(ctx.owner, scope: "read")
      |> post("/api/boards/#{ctx.board.id}/inbound/rotate")
      |> json_response(403)

      as(reader) |> post("/api/boards/#{ctx.board.id}/inbound/rotate") |> json_response(403)

      assert {:ok, ^old} = Tokens.address(ctx.owner, ctx.board, :card)
    end
  end

  describe "/api/me/inbound" do
    test "your personal Quick Add address, and rotating it", ctx do
      body = as(ctx.owner) |> get("/api/me/inbound") |> json_response(200)
      assert %{"board" => nil, "addresses" => %{"add" => "add-" <> _ = old}} = body
      assert map_size(body["addresses"]) == 1

      %{"addresses" => %{"add" => new}} =
        as(ctx.owner) |> post("/api/me/inbound/rotate") |> json_response(200)

      assert new != old
      assert Tokens.resolve(old) == {:error, :revoked}
    end

    test "a read-only token can read it but not rotate it", ctx do
      assert with_token(ctx.owner, scope: "read") |> get("/api/me/inbound") |> json_response(200)
      with_token(ctx.owner, scope: "read") |> post("/api/me/inbound/rotate") |> json_response(403)
    end

    test "404 while inbound mail is off", ctx do
      TestConfig.put(:inbound, [])
      assert as(ctx.owner) |> get("/api/me/inbound") |> json_response(404)
      assert as(ctx.owner) |> post("/api/me/inbound/rotate") |> json_response(404)
    end
  end
end
