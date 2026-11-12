defmodule SlipdockWeb.API.PageBoardTagsTest do
  @moduledoc """
  A page's board tags over the API (#1586): `tags`, `add_tags` and
  `remove_tags` on `PATCH /api/pages/:id`, by name, as on a card. Not the
  note's own `note_tags`, which come from its text.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Vaults, Wiki}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Tagged", "code" => "pgtags"}, owner: user)
    Enum.each(~w(alpha beta gamma), &tag_fixture(board, &1))
    page = page_fixture(board, %{"title" => "Doc", "body" => "words"}, user: user)

    %{conn: put_req_header(conn, "accept", "application/json"), board: board, page: page}
  end

  defp patch_page(conn, page, body), do: patch(conn, "/api/pages/#{page.code}", body)

  defp tags(page), do: page |> Wiki.get_page!() |> tag_names()

  defp tag_names(page), do: page |> Wiki.tags() |> Enum.map(& &1.name) |> Enum.sort()

  defp with_token(user, opts) do
    {token, _} = Accounts.create_api_token(user, "agent", opts)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp seed(board, page, names) do
    wanted = Enum.map(names, &(Slipdock.Boards.find_tag(board, &1) |> elem(1)))
    {:ok, _} = Wiki.set_tags(page, wanted)
  end

  test "add_tags puts tags on by name, keeping the ones there", ctx do
    seed(ctx.board, ctx.page, ["alpha"])

    body = ctx.conn |> patch_page(ctx.page, %{add_tags: ["BETA", "alpha"]}) |> json_response(200)

    assert Enum.sort(body["page"]["tags"]) == ~w(alpha beta)
    assert tags(ctx.page.id) == ~w(alpha beta)
  end

  test "remove_tags takes tags off, and one that isn't on the page is no matter", ctx do
    seed(ctx.board, ctx.page, ~w(alpha beta))

    assert ctx.conn |> patch_page(ctx.page, %{remove_tags: ~w(alpha gamma)}) |> json_response(200)
    assert tags(ctx.page.id) == ~w(beta)
  end

  test "tags replaces the whole set, and [] clears it", ctx do
    seed(ctx.board, ctx.page, ~w(alpha beta))

    assert ctx.conn |> patch_page(ctx.page, %{tags: ~w(gamma)}) |> json_response(200)
    assert tags(ctx.page.id) == ~w(gamma)

    assert ctx.conn |> patch_page(ctx.page, %{tags: []}) |> json_response(200)
    assert tags(ctx.page.id) == []
  end

  test "tags then add and remove, in one request", ctx do
    assert ctx.conn
           |> patch_page(ctx.page, %{
             tags: ~w(alpha beta),
             add_tags: ~w(gamma),
             remove_tags: ~w(alpha)
           })
           |> json_response(200)

    assert tags(ctx.page.id) == ~w(beta gamma)
  end

  test "a PATCH that doesn't name tags leaves them", ctx do
    seed(ctx.board, ctx.page, ~w(alpha))

    assert ctx.conn |> patch_page(ctx.page, %{title: "Renamed"}) |> json_response(200)
    assert tags(ctx.page.id) == ~w(alpha)
  end

  test "an unknown tag is refused by name, and nothing changes", ctx do
    seed(ctx.board, ctx.page, ~w(alpha))

    for key <- ~w(tags add_tags remove_tags) do
      body =
        ctx.conn
        |> patch_page(ctx.page, %{"title" => "Changed", key => ["beta", "nope"]})
        |> json_response(422)

      assert body["error"] =~ ~s(no tag "nope" on board pgtags)
      assert body["error"] =~ "alpha, beta, gamma"
    end

    page = Wiki.get_page!(ctx.page.id)
    assert page.title == "Doc"
    assert tag_names(page) == ~w(alpha)
  end

  test "tags that aren't a list of names are refused, not a crash", ctx do
    for bad <- [%{a: 1}, [%{a: 1}], 7, true] do
      body = ctx.conn |> patch_page(ctx.page, %{add_tags: bad}) |> json_response(422)
      assert body["error"] =~ "list of tag names"
    end
  end

  test "a page on a sub-board takes its root board's tags", ctx do
    card = card_fixture(hd(ctx.board.columns))
    {:ok, sub} = sub_board(card, hd(Slipdock.Boards.Templates.list_templates(nil)))
    page = page_fixture(sub, %{"title" => "Sub doc"}, user: ctx.user)

    assert ctx.conn |> patch_page(page, %{add_tags: ~w(alpha)}) |> json_response(200)
    assert tags(page.id) == ~w(alpha)
  end

  test "a tag from another board isn't this page's", ctx do
    other = board_fixture(%{"name" => "Other", "code" => "pgtagso"}, owner: ctx.user)
    tag_fixture(other, "elsewhere")

    assert ctx.conn |> patch_page(ctx.page, %{add_tags: ~w(elsewhere)}) |> json_response(422)
    assert tags(ctx.page.id) == []
  end

  test "a read-only token is refused", ctx do
    assert ctx.user
           |> with_token(scope: "read")
           |> patch_page(ctx.page, %{add_tags: ~w(alpha)})
           |> json_response(403)

    assert tags(ctx.page.id) == []
  end

  test "a token limited to another board is refused", ctx do
    other = board_fixture(%{"name" => "Other", "code" => "pgtagsl"}, owner: ctx.user)

    conn = with_token(ctx.user, scope_boards: [other.id])
    assert conn |> patch_page(ctx.page, %{add_tags: ~w(alpha)}) |> response(403)
    assert tags(ctx.page.id) == []
  end

  test "note_tags are left alone, and the two never mix", ctx do
    {:ok, _} = ctx.user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Notes"})

    {:ok, note} =
      Wiki.create_page(ctx.board, %{"title" => "N", "body" => "#mine"}, user: ctx.user)

    body = ctx.conn |> patch_page(note, %{add_tags: ~w(alpha)}) |> json_response(200)
    assert body["page"]["tags"] == ~w(alpha)
    assert body["page"]["note_tags"] == ~w(mine)
    assert Wiki.get_page!(note.id).body == "#mine"

    # A note tag isn't a board tag, so it can't be set or taken off this way.
    assert ctx.conn |> patch_page(note, %{remove_tags: ~w(mine)}) |> json_response(422)
    body = ctx.conn |> patch_page(note, %{tags: []}) |> json_response(200)
    assert body["page"]["tags"] == []
    assert body["page"]["note_tags"] == ~w(mine)
  end

  # `page_card_features` drops status, checklist, fields and so on from a
  # page, but the web app keeps Tags and Tag…, so a token keeps them too.
  test "a board with its card features off for pages still tags them", ctx do
    assert ctx.conn
           |> patch("/api/boards/pgtags", %{page_card_features: false})
           |> json_response(200)

    assert ctx.conn |> patch_page(ctx.page, %{add_tags: ~w(alpha)}) |> json_response(200)
    assert tags(ctx.page.id) == ~w(alpha)
  end
end
