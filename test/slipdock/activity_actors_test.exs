defmodule Slipdock.ActivityActorsTest do
  @moduledoc """
  Who the activity log says made a change that came in from outside (#1735):
  a script's token, the CLI, an agent over MCP and an email, each set as the
  request's actor by the door it came through.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Inbound, Repo, TestConfig}
  alias Slipdock.Inbound.Tokens

  setup do
    user = user_fixture("actors.req@example.com")
    user = Repo.update!(Ecto.Changeset.change(user, name: "Robin Request"))
    board = board_fixture(%{"name" => "Doors"}, owner: user)
    %{user: user, board: board}
  end

  defp bearer(user, label, headers \\ []) do
    {secret, _} = Accounts.create_api_token(user, label)

    Enum.reduce(
      headers,
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> secret),
      fn {k, v}, conn -> put_req_header(conn, k, v) end
    )
  end

  defp latest(board), do: board.id |> Boards.list_activities(1) |> hd()

  test "a script's token is an agent, under the token's label", ctx do
    ctx.user
    |> bearer("nightly-script")
    |> post("/api/boards/#{ctx.board.id}/cards", %{title: "From a script"})
    |> json_response(201)

    entry = latest(ctx.board)

    assert {entry.actor_kind, entry.actor_name, entry.user_id} ==
             {"agent", "nightly-script", ctx.user.id}
  end

  test "the CLI used by a person is that person", ctx do
    ctx.user
    |> bearer("laptop", [{"x-slipdock-client", "cli"}])
    |> post("/api/boards/#{ctx.board.id}/cards", %{title: "From the CLI"})
    |> json_response(201)

    entry = latest(ctx.board)

    assert {entry.actor_kind, entry.actor_name, entry.user_id} ==
             {"person", "Robin Request", ctx.user.id}
  end

  test "an agent over MCP is named by its token", ctx do
    ctx.user
    |> bearer("claude")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "create_card", arguments: %{board: ctx.board.id, title: "From MCP"}}
      })
    )
    |> json_response(200)

    entry = latest(ctx.board)
    assert entry.message =~ "From MCP"
    assert {entry.actor_kind, entry.actor_name} == {"agent", "claude"}
  end

  test "a request with no token leaves no actor behind", ctx do
    Actor.put(Actor.web(ctx.user), "Left over")
    build_conn() |> get("/api/guide")
    assert Actor.current() == Actor.unknown()
  end

  test "mail from a trusted sender is email, by its sender", ctx do
    TestConfig.put(:inbound, domain: "in.example.com", secrets: ["s"])
    {:ok, address} = Tokens.address(ctx.user, ctx.board, :card)

    raw =
      "ARC-Authentication-Results: i=1; mx.cloudflare.net; dkim=pass header.d=example.com;\r\n" <>
        " dmarc=pass header.from=example.com\r\n" <>
        "From: Robin <#{ctx.user.email}>\r\nTo: #{address}\r\nSubject: Mailed in\r\n" <>
        "Message-ID: <#{System.unique_integer([:positive])}@example.com>\r\n" <>
        "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nBody\r\n"

    assert {:accepted, _} =
             Inbound.receive_message(%{raw: raw, envelope_to: address, envelope_from: nil})

    entry = latest(ctx.board)
    assert entry.message =~ "Mailed in"

    assert {entry.actor_kind, entry.actor_name, entry.user_id} ==
             {"email", "Robin Request", ctx.user.id}
  end

  test "mail from an untrusted sender sets no actor", ctx do
    TestConfig.put(:inbound, domain: "in.example.com", secrets: ["s"])
    {:ok, address} = Tokens.address(ctx.user, ctx.board, :card)

    raw =
      "From: Stranger <stranger@example.com>\r\nTo: #{address}\r\nSubject: Spoofed\r\n" <>
        "Message-ID: <#{System.unique_integer([:positive])}@example.com>\r\n" <>
        "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nBody\r\n"

    assert {:rejected, _, _} =
             Inbound.receive_message(%{raw: raw, envelope_to: address, envelope_from: nil})

    assert Actor.current() == Actor.unknown()
  end
end
