defmodule Slipdock.PolicyShareOnwardTest do
  @moduledoc """
  Who may share a card, page or folder with someone else (#3558): the
  board's owner, and its editors only where the owner of the tree's top
  board has turned on `editors_may_share`. Only the owner changes that.
  Every door asks `Slipdock.Policy`, so the contexts are called here as a
  door calls them, and one REST door shows the refusal reaching a person.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Actor, Boards, Policy, Repo, Wiki}
  alias Slipdock.Policy.Refused

  setup do
    owner = user_fixture("share.onward.owner@example.com")
    root = board_fixture(%{"name" => "Share onward"}, owner: owner)
    card = card_fixture(hd(root.columns), %{"title" => "Card"})
    page = page_fixture(root, %{"title" => "Page"}, user: owner)
    {:ok, folder} = fixture(fn -> Wiki.create_folder(root, %{"name" => "Folder"}) end)
    writer = user_fixture("share.onward.writer@example.com")
    {:ok, _} = fixture(fn -> Access.grant(root, writer, "write", owner) end)
    %{owner: owner, root: root, card: card, page: page, folder: folder, writer: writer}
  end

  defp fixture(fun), do: Policy.as_system("a test fixture", fun)
  defp as(user), do: Actor.put(Actor.web(user), nil, {user, nil})

  defp outsider,
    do: user_fixture("share.onward.#{System.unique_integer([:positive])}@example.com")

  defp allow(board, on?),
    do: Repo.update!(Ecto.Changeset.change(Repo.reload!(board), editors_may_share: on?))

  defp share(:card, ctx, user), do: Access.grant(ctx.card, outsider(), "read", user)
  defp share(:page, ctx, user), do: Access.grant(ctx.page, outsider(), "read", user)
  defp share(:folder, ctx, user), do: Access.grant(ctx.folder, outsider(), "read", user)

  test "a new board doesn't let its editors share", ctx do
    refute Repo.get!(Boards.Board, ctx.root.id).editors_may_share
  end

  for kind <- [:card, :page, :folder] do
    describe "sharing a #{kind}" do
      test "an editor is refused while the board doesn't allow it, saying the owner has to",
           ctx do
        as(ctx.writer)
        action = :"share_#{unquote(kind)}"

        assert {:error, %Refused{action: ^action, need: :owner, by: :user, message: message}} =
                 share(unquote(kind), ctx, ctx.writer)

        assert message =~ "owner"
        assert message =~ "Editors may share"
      end

      test "the owner shares either way", ctx do
        as(ctx.owner)
        assert {:ok, _} = share(unquote(kind), ctx, ctx.owner)
      end

      test "an editor shares once the owner allows it, and not after it is off again", ctx do
        allow(ctx.root, true)
        as(ctx.writer)
        assert {:ok, _} = share(unquote(kind), ctx, ctx.writer)

        allow(ctx.root, false)
        assert {:error, %Refused{by: :user}} = share(unquote(kind), ctx, ctx.writer)
      end

      test "a commenter is refused even where editors may share", ctx do
        allow(ctx.root, true)
        commenter = outsider()
        {:ok, _} = fixture(fn -> Access.grant(ctx.root, commenter, "comment", ctx.owner) end)
        as(commenter)
        assert {:error, %Refused{by: :user}} = share(unquote(kind), ctx, commenter)
      end
    end
  end

  test "taking a share back asks the same", ctx do
    as(ctx.owner)
    {:ok, grant} = share(:card, ctx, ctx.owner)

    as(ctx.writer)
    assert {:error, %Refused{action: :share_card}} = Access.revoke(grant)

    allow(ctx.root, true)
    assert {:ok, _} = Access.revoke(grant)
  end

  test "a card on a sub-board follows the top board's setting, not its own", ctx do
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(ctx.card, t)
    sub = Boards.get_board!(sub.id)
    inner = card_fixture(hd(sub.columns), %{"title" => "Inner"})
    allow(sub, true)

    as(ctx.writer)

    assert {:error, %Refused{action: :share_card}} =
             Access.grant(inner, outsider(), "read", ctx.writer)

    allow(ctx.root, true)
    allow(sub, false)
    assert {:ok, _} = Access.grant(inner, outsider(), "read", ctx.writer)
  end

  test "a wiki share by an editor is refused through Wiki.Sharing too", ctx do
    as(ctx.writer)

    assert {:error, %Refused{action: :share_page}} =
             Wiki.Sharing.share(ctx.writer, ctx.page, %{"email" => "s1@example.com"}, "read")

    allow(ctx.root, true)

    assert {:ok, _} =
             Wiki.Sharing.share(ctx.writer, ctx.page, %{"email" => "s1@example.com"}, "read")
  end

  describe "changing the setting" do
    test "only the owner may turn it on or off", ctx do
      as(ctx.writer)

      assert {:error, %Refused{action: :let_editors_share, by: :user}} =
               Boards.update_board(ctx.root, %{"editors_may_share" => true})

      refute Repo.get!(Boards.Board, ctx.root.id).editors_may_share

      as(ctx.owner)

      assert {:ok, %{editors_may_share: true}} =
               Boards.update_board(ctx.root, %{"editors_may_share" => true})

      as(ctx.writer)
      root = Repo.get!(Boards.Board, ctx.root.id)

      assert {:error, %Refused{action: :let_editors_share}} =
               Boards.update_board(root, %{"editors_may_share" => false})
    end

    test "an editor's other changes pass when they leave it as it is", ctx do
      as(ctx.writer)

      assert {:ok, %{name: "Renamed", editors_may_share: false}} =
               Boards.update_board(ctx.root, %{"name" => "Renamed", "editors_may_share" => false})
    end
  end

  test "the owner turns it on from the Features tab", ctx do
    {:ok, view, _} = live(conn_as(ctx.owner), ~p"/boards/#{ctx.root}/settings?tab=features")
    assert has_element?(view, "#settings-panel-features #board-editors-may-share")

    view
    |> form("#board-form", board: %{editors_may_share: "true"})
    |> render_submit()

    assert Repo.get!(Boards.Board, ctx.root.id).editors_may_share
  end

  describe "over the REST API" do
    test "the owner sets it with PATCH /api/boards/:board, and the board says so", ctx do
      body =
        ctx.owner
        |> conn_as()
        |> put_req_header("accept", "application/json")
        |> patch("/api/boards/#{ctx.root.id}", %{editors_may_share: true})
        |> json_response(200)

      assert inspect(body) =~ "editors_may_share"
      assert Repo.get!(Boards.Board, ctx.root.id).editors_may_share
    end

    test "an editor sharing a page is refused until the owner allows it", ctx do
      conn = ctx.writer |> conn_as() |> put_req_header("accept", "application/json")

      refused =
        conn
        |> post("/api/pages/#{ctx.page.id}/grants", %{email: "s2@example.com", level: "read"})
        |> json_response(403)

      assert inspect(refused) =~ "Editors may share"

      allow(ctx.root, true)

      conn
      |> post("/api/pages/#{ctx.page.id}/grants", %{email: "s2@example.com", level: "read"})
      |> json_response(201)
    end
  end
end
