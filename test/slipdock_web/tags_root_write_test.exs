defmodule SlipdockWeb.TagsRootWriteTest do
  @moduledoc """
  A board tree's tags are its root's, so changing the list (making, renaming,
  recolouring or deleting a tag) asks write on the root at every door
  (#2990): the card panel's New tag, the Tags panel, `POST` and `DELETE
  /api/boards/:board/tags`, the MCP `create_tag` and the assistant's tag
  steps. Write on a sub-board alone, from a grant on the card it hangs from
  or on the sub-board itself, applies the tags the tree has and changes none.
  A writer of the root still makes them from any board of the tree.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo}
  alias Slipdock.AI.Actions
  alias Slipdock.Boards.Tag

  setup %{user: owner} do
    root = board_fixture(%{"name" => "Root"}, owner: owner)
    epic = card_fixture(hd(root.columns), %{"title" => "Epic"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    {:ok, ops} = Boards.Tags.create_tag(root, %{"name" => "ops", "color" => "rose"})
    # Loaded after the tag, so the sub-board carries its tree's tags.
    sub = Boards.get_board!(sub.id)
    task = card_fixture(hd(sub.columns), %{"title" => "Task"})

    card_writer = user_fixture("tags.root.card-writer@example.com")
    {:ok, _} = Access.grant(epic, card_writer, "write", owner)

    sub_writer = user_fixture("tags.root.sub-writer@example.com")
    {:ok, _} = Access.grant(sub, sub_writer, "write", owner)

    root_writer = user_fixture("tags.root.root-writer@example.com")
    {:ok, _} = Access.grant(root, root_writer, "write", owner)

    %{
      owner: owner,
      root: root,
      sub: sub,
      task: task,
      ops: ops,
      card_writer: card_writer,
      sub_writer: sub_writer,
      root_writer: root_writer
    }
  end

  defp names(ctx), do: ctx.root.id |> Boards.Tags.list_tags() |> Enum.map(& &1.name)

  # The two ways of writing the sub-board without writing the root.
  @sub_writers [:card_writer, :sub_writer]

  describe "Access.can_edit_tags?/2" do
    test "asks write on the root, wherever in the tree it is asked", ctx do
      for who <- @sub_writers do
        user = ctx[who]
        # They do write the sub-board…
        assert Access.can_write?(Access.board_permission(user, ctx.sub)), "#{who}"
        # …but not its tag list, nor the root's.
        refute Access.can_edit_tags?(user, ctx.sub), "#{who}"
        refute Access.can_edit_tags?(user, ctx.root), "#{who}"
      end

      for user <- [ctx.owner, ctx.root_writer] do
        assert Access.can_edit_tags?(user, ctx.sub)
        assert Access.can_edit_tags?(user, ctx.root)
      end

      reader = user_fixture("tags.root.reader@example.com")
      {:ok, _} = Access.grant(ctx.root, reader, "read", ctx.owner)
      refute Access.can_edit_tags?(reader, ctx.sub)
      refute Access.can_edit_tags?(nil, ctx.sub)
    end
  end

  describe "the REST API" do
    for who <- @sub_writers do
      test "a #{who} can't make or delete a tag on the sub-board", ctx do
        conn = conn_as(ctx[unquote(who)]) |> put_req_header("accept", "application/json")

        body =
          conn
          |> post(~p"/api/boards/#{ctx.sub.id}/tags", %{name: "sneaky"})
          |> json_response(403)

        assert inspect(body) =~ "only someone who can edit the top board changes them"

        conn
        |> delete(~p"/api/boards/#{ctx.sub.id}/tags/#{ctx.ops.id}")
        |> json_response(403)

        assert names(ctx) == ["ops"]
      end
    end

    test "a writer of the root makes and deletes one from the sub-board", ctx do
      conn = conn_as(ctx.root_writer) |> put_req_header("accept", "application/json")

      assert %{"tag" => %{"name" => "deep"}} =
               conn
               |> post(~p"/api/boards/#{ctx.sub.id}/tags", %{name: "deep"})
               |> json_response(201)

      conn |> delete(~p"/api/boards/#{ctx.sub.id}/tags/#{ctx.ops.id}") |> json_response(200)
      assert names(ctx) == ["deep"]
    end

    # A token scoped to the sub-board alone reaches it but not the root: the
    # owner's own token is refused there, and the refusal says it is the token.
    test "a token scoped to the sub-board alone is refused, as the token", ctx do
      {token, _} =
        Slipdock.Accounts.create_api_token(ctx.owner, "narrow", scope_boards: [ctx.sub.id])

      body =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)
        |> post(~p"/api/boards/#{ctx.sub.id}/tags", %{name: "x"})
        |> json_response(403)

      assert inspect(body) =~ "token's scope"
      refute inspect(body) =~ "top board"
      assert names(ctx) == ["ops"]
    end
  end

  describe "MCP create_tag" do
    defp mcp(user, args) do
      conn_as(user)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "create_tag", arguments: args}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")
    end

    for who <- @sub_writers do
      test "a #{who} makes no new tag, and is given the one the tree has", ctx do
        refused = mcp(ctx[unquote(who)], %{board: ctx.sub.id, name: "sneaky"})
        assert refused["isError"] == true
        assert inspect(refused["content"]) =~ "only someone who can edit the top board"

        known = mcp(ctx[unquote(who)], %{board: ctx.sub.id, name: "OPS"})
        assert known["isError"] == false
        assert known["structuredContent"]["created"] == false
        assert known["structuredContent"]["tag"]["id"] == ctx.ops.id

        assert names(ctx) == ["ops"]
      end
    end

    test "a writer of the root makes one from the sub-board", ctx do
      made = mcp(ctx.root_writer, %{board: ctx.sub.id, name: "deep"})
      assert made["structuredContent"]["created"] == true
      assert names(ctx) == ["deep", "ops"]
    end
  end

  describe "the assistant" do
    defp add_tags(ctx, user, tags) do
      Actions.prepare(
        [%{"type" => "update", "card_id" => ctx.task.id, "changes" => %{"add_tags" => tags}}],
        %{board: ctx.sub, cards: [ctx.task], user: user, users: [user]}
      )
    end

    for who <- @sub_writers do
      test "a #{who} gets a refused step for a new tag, and adds one the tree has", ctx do
        assert [new, known] = add_tags(ctx, ctx[unquote(who)], ["sneaky", "ops"])

        assert new.error ==
                 "only someone who can edit the top board makes a new tag; pick one it has"

        assert known.error == nil

        Actions.apply([new, known])
        assert names(ctx) == ["ops"]
        assert Enum.map(Boards.Cards.get_card!(ctx.task.id).tags, & &1.name) == ["ops"]
      end
    end

    test "a writer of the root makes it", ctx do
      assert [step] = add_tags(ctx, ctx.root_writer, ["deep"])
      assert step.error == nil
      Actions.apply([step])
      assert names(ctx) == ["deep", "ops"]
    end

    test "asks again when applied: a root grant lowered since refuses the step", ctx do
      assert [step] = add_tags(ctx, ctx.root_writer, ["deep"])
      {:ok, _} = Access.grant(ctx.root, ctx.root_writer, "read", ctx.owner)

      assert [%{result: {:error, _}}] = Actions.apply([step])
      assert names(ctx) == ["ops"]
    end
  end

  describe "the card panel's New tag, on a sub-board's card" do
    defp open_card(user, ctx),
      do: live(conn_as(user), ~p"/boards/#{ctx.sub}/cards/#{ctx.task.id}")

    for who <- @sub_writers do
      test "a #{who} is refused a new name and told why; a known one goes on", ctx do
        {:ok, view, _} = open_card(ctx[unquote(who)], ctx)

        view |> form("#card-tag-search", %{"name" => "Sneaky"}) |> render_submit()
        assert names(ctx) == ["ops"]

        assert view |> element("#card-modal #panel-notice[data-callout=error]") |> render() =~
                 "only someone who can edit the top board makes a new tag"

        view |> form("#card-tag-search", %{"name" => "ops"}) |> render_submit()
        assert Enum.map(Boards.Cards.get_card!(ctx.task.id).tags, & &1.name) == ["ops"]
      end
    end

    test "a writer of the root makes it, on the root", ctx do
      {:ok, view, _} = open_card(ctx.root_writer, ctx)
      view |> form("#card-tag-search", %{"name" => "deep"}) |> render_submit()
      assert names(ctx) == ["deep", "ops"]
    end
  end

  describe "the Tags panel, on a sub-board" do
    defp open_panel(user, ctx) do
      {:ok, view, _} = live(conn_as(user), ~p"/boards/#{ctx.sub}/tags")
      view
    end

    for who <- @sub_writers do
      test "a #{who} sees it read-only, is told why, and changes nothing", ctx do
        view = open_panel(ctx[unquote(who)], ctx)
        panel = with_target(view, "#board-tags")

        assert has_element?(view, "#board-tags fieldset[disabled] #tag-row-#{ctx.ops.id}")
        assert has_element?(view, "#tags-root-only", "only someone who can edit it")

        render_hook(panel, "create_tag", %{"tag" => %{"name" => "sneaky"}})
        render_hook(panel, "set_tag_color", %{"id" => "#{ctx.ops.id}", "color" => "lime"})
        render_hook(panel, "rename_tag", %{"tag_id" => "#{ctx.ops.id}", "name" => "mine"})
        assert_reply(view, %{ok: false})
        render_hook(panel, "delete_tag", %{"id" => "#{ctx.ops.id}"})

        assert has_element?(view, "#tags-error", "Tags belong to the top board")
        assert %Tag{name: "ops", color: "rose"} = Repo.get!(Tag, ctx.ops.id)
        assert names(ctx) == ["ops"]
      end
    end

    test "a writer of the root changes it from the sub-board", ctx do
      view = open_panel(ctx.root_writer, ctx)
      refute has_element?(view, "#tags-root-only")
      refute has_element?(view, "#board-tags fieldset[disabled]")

      render_hook(with_target(view, "#board-tags"), "create_tag", %{"tag" => %{"name" => "deep"}})
      assert names(ctx) == ["deep", "ops"]
    end
  end
end
