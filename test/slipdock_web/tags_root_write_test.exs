defmodule SlipdockWeb.TagsRootWriteTest do
  @moduledoc """
  A board tree's tags are its root's, so changing the list (making, renaming,
  recolouring or deleting a tag) asks write on the root at every door
  (#2990): the card panel's New tag, the Tags panel, `POST` and `DELETE
  /api/boards/:board/tags`, the MCP `create_tag` and the assistant's tag
  steps. Write on a sub-board alone, from a grant on the card it hangs from
  or on the sub-board itself, applies the tags the tree has and changes none.
  A writer of the root still makes them from any board of the tree.

  The doors that carry tags in rather than make them by name ask the same:
  a copy (`POST /api/cards/:id/copy`), a move across trees (`POST
  /api/cards/:id/move`, the MCP `move_card` and bulk edit; the Move panel
  offers only top boards its user writes, so it never meets the case)
  and a sub-board from a template (`POST /api/cards/:id/subboard`, the MCP
  `create_card`'s `parent`, the card panel). A sub-board writer's copy or
  move takes the tags the tree has and leaves off the rest, saying which;
  a template's tags stay out.
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

    test "a writer of the root, and the owner, make one on the root itself", ctx do
      for {user, name} <- [{ctx.root_writer, "top"}, {ctx.owner, "own"}] do
        assert %{"tag" => %{"name" => ^name}} =
                 conn_as(user)
                 |> put_req_header("accept", "application/json")
                 |> post(~p"/api/boards/#{ctx.root.id}/tags", %{name: name})
                 |> json_response(201)
      end

      assert names(ctx) == ["ops", "own", "top"]
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

    test "a writer of the root, and the owner, make one on the root itself", ctx do
      for {user, name} <- [{ctx.root_writer, "top"}, {ctx.owner, "own"}] do
        made = mcp(user, %{board: ctx.root.id, name: name})
        assert made["isError"] == false
        assert made["structuredContent"]["created"] == true
      end

      assert names(ctx) == ["ops", "own", "top"]
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
        render_hook(panel, "delete_tag", %{"id" => "#{ctx.ops.id}"})

        assert has_element?(view, "#tags-error", "Tags belong to the top board")
        # Said once: the error takes the info callout's place.
        refute has_element?(view, "#tags-root-only")
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

  ## The doors that carry tags in ---------------------------------------------

  # A card on `user`'s own board wearing `sneaky` (which the tree lacks) and
  # `ops` (which it has, by name).
  defp own_card(user) do
    mine = board_fixture(%{"name" => "Mine"}, owner: user)
    card = card_fixture(hd(mine.columns), %{"title" => "Carried"})
    {:ok, sneaky} = Boards.Tags.create_tag(mine, %{"name" => "sneaky", "color" => "lime"})
    {:ok, ops} = Boards.Tags.create_tag(mine, %{"name" => "ops", "color" => "sky"})
    {:ok, card} = Boards.Cards.set_card_tags(card, [sneaky, ops])
    Boards.Cards.get_card!(card.id)
  end

  defp tag_names(card_id),
    do:
      card_id
      |> Boards.Cards.get_card!()
      |> Map.fetch!(:tags)
      |> Enum.map(& &1.name)
      |> Enum.sort()

  defp api(user), do: conn_as(user) |> put_req_header("accept", "application/json")

  defp mcp_tool(user, tool, args) do
    conn_as(user)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: tool, arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  describe "copying a card into the sub-board" do
    for who <- @sub_writers do
      test "a #{who} takes the tags the tree has and is told which it left off", ctx do
        card = own_card(ctx[unquote(who)])

        body =
          ctx[unquote(who)]
          |> api()
          |> post(~p"/api/cards/#{card.id}/copy", %{board: ctx.sub.id})
          |> json_response(201)

        assert body["tags_dropped"] == ["sneaky"]
        assert body["tags_dropped_reason"] =~ "only someone who can edit the top board"
        assert tag_names(body["card"]["id"]) == ["ops"]
        assert names(ctx) == ["ops"]
      end

      test "a #{who}'s copy with subcards leaves their new tags off too", ctx do
        user = ctx[unquote(who)]
        card = own_card(user)
        {:ok, t} = Boards.Templates.find_template(nil, "Simple")
        {:ok, below} = sub_board(card, t)
        below = Boards.get_board!(below.id)
        child = card_fixture(hd(below.columns), %{"title" => "Child"})
        {:ok, deep} = Boards.Tags.create_tag(below, %{"name" => "deeper"})
        {:ok, _} = Boards.Cards.set_card_tags(child, [deep])

        column = hd(ctx.sub.columns)

        assert {:ok, _copy, ["deeper", "sneaky"]} =
                 Boards.Cards.copy_card_reporting(card, column, by: user)

        assert names(ctx) == ["ops"]
      end
    end

    test "a writer of the root makes the ones the tree lacks", ctx do
      card = own_card(ctx.root_writer)

      body =
        ctx.root_writer
        |> api()
        |> post(~p"/api/cards/#{card.id}/copy", %{board: ctx.sub.id})
        |> json_response(201)

      assert body["tags_dropped"] == []
      refute Map.has_key?(body, "tags_dropped_reason")
      assert tag_names(body["card"]["id"]) == ["ops", "sneaky"]
      assert names(ctx) == ["ops", "sneaky"]
    end

    test "the owner's token scoped to the sub-board alone makes none", ctx do
      card = own_card(ctx.owner)

      {token, _} =
        Slipdock.Accounts.create_api_token(ctx.owner, "narrow",
          scope_boards: [ctx.sub.id, card.board_id]
        )

      body =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)
        |> post(~p"/api/cards/#{card.id}/copy", %{board: ctx.sub.id})
        |> json_response(201)

      assert body["tags_dropped"] == ["sneaky"]
      # The token stopped it, so the reason is the token's (ARCH-8).
      assert body["tags_dropped_reason"] =~ "token's scope"
      refute body["tags_dropped_reason"] =~ "top board"
      assert names(ctx) == ["ops"]
    end

    test "with nobody named, as a recurring card's next one, they are made", ctx do
      card = own_card(ctx.owner)
      assert {:ok, _, []} = Boards.Cards.copy_card_reporting(card, hd(ctx.sub.columns))
      assert names(ctx) == ["ops", "sneaky"]
    end
  end

  describe "moving a card into the sub-board" do
    for who <- @sub_writers do
      test "a #{who} over REST takes the tags the tree has and is told the rest", ctx do
        card = own_card(ctx[unquote(who)])

        body =
          ctx[unquote(who)]
          |> api()
          |> post(~p"/api/cards/#{card.id}/move", %{board: ctx.sub.id})
          |> json_response(200)

        assert body["moved"]["tags_dropped"] == ["sneaky"]
        assert body["moved"]["tags_created"] == 0
        assert body["moved"]["tags_dropped_reason"] =~ "only someone who can edit the top board"
        assert tag_names(card.id) == ["ops"]
        assert names(ctx) == ["ops"]
      end

      test "a #{who} over MCP move_card is told the same", ctx do
        card = own_card(ctx[unquote(who)])

        result = mcp_tool(ctx[unquote(who)], "move_card", %{card: card.id, board: ctx.sub.id})
        assert result["isError"] == false
        assert result["structuredContent"]["tags_dropped"] == ["sneaky"]
        assert result["structuredContent"]["tags_dropped_reason"] =~ "top board"
        assert names(ctx) == ["ops"]
      end

      test "a #{who} in the web (bulk edit) makes none", ctx do
        user = ctx[unquote(who)]
        card = own_card(user)

        assert {:ok, %{tags_dropped: ["sneaky"], tags_created: 0}} =
                 Boards.Moves.move_card_to_board(card, hd(ctx.sub.columns),
                   actor: Slipdock.Actor.web(user)
                 )

        assert tag_names(card.id) == ["ops"]
        assert names(ctx) == ["ops"]
      end
    end

    test "the owner's token scoped to the sub-board alone makes none, REST or MCP", ctx do
      rest_card = own_card(ctx.owner)
      mcp_card = own_card(ctx.owner)

      {token, _} =
        Slipdock.Accounts.create_api_token(ctx.owner, "narrow",
          scope_boards: [ctx.sub.id, rest_card.board_id, mcp_card.board_id]
        )

      bearer = fn ->
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)
      end

      body =
        bearer.()
        |> post(~p"/api/cards/#{rest_card.id}/move", %{board: ctx.sub.id})
        |> json_response(200)

      assert body["moved"]["tags_dropped"] == ["sneaky"]
      assert body["moved"]["tags_dropped_reason"] =~ "token's scope"

      result =
        bearer.()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/mcp",
          Jason.encode!(%{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "move_card", arguments: %{card: mcp_card.id, board: ctx.sub.id}}
          })
        )
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["structuredContent"]["tags_dropped"] == ["sneaky"]
      assert result["structuredContent"]["tags_dropped_reason"] =~ "token's scope"
      assert names(ctx) == ["ops"]
    end

    test "a writer of the root makes the ones the tree lacks", ctx do
      card = own_card(ctx.root_writer)

      body =
        ctx.root_writer
        |> api()
        |> post(~p"/api/cards/#{card.id}/move", %{board: ctx.sub.id})
        |> json_response(200)

      assert body["moved"]["tags_dropped"] == []
      assert body["moved"]["tags_created"] == 1
      refute Map.has_key?(body["moved"], "tags_dropped_reason")
      assert tag_names(card.id) == ["ops", "sneaky"]

      mcp_card = own_card(ctx.root_writer)
      result = mcp_tool(ctx.root_writer, "move_card", %{card: mcp_card.id, board: ctx.sub.id})
      refute Map.has_key?(result["structuredContent"], "tags_dropped")
      assert names(ctx) == ["ops", "sneaky"]
    end
  end

  describe "a sub-board from a template that carries tags" do
    defp tagged_template(user) do
      user
      |> api()
      |> post("/api/templates", %{
        "name" => "Tagged #{System.unique_integer([:positive])}",
        "columns" => ["To Do", "Done"],
        "tags" => ["sneaky", "ops"]
      })
      |> json_response(201)
      |> get_in(["template", "id"])
    end

    for who <- @sub_writers do
      test "a #{who} over REST gets the lists, and the tree's tags stay", ctx do
        user = ctx[unquote(who)]
        template = tagged_template(user)

        user
        |> api()
        |> post(~p"/api/cards/#{ctx.task.id}/subboard", %{template: template})
        |> json_response(201)

        assert names(ctx) == ["ops"]
      end

      test "a #{who} over MCP create_card's parent gets the same", ctx do
        user = ctx[unquote(who)]
        template = tagged_template(user)

        result =
          mcp_tool(user, "create_card", %{
            parent: ctx.task.id,
            title: "Below",
            subcard_template: "#{template}"
          })

        assert result["isError"] == false
        assert names(ctx) == ["ops"]
      end

      test "a #{who} in the card panel gets the same", ctx do
        user = ctx[unquote(who)]
        template = tagged_template(user)
        {:ok, view, _} = live(conn_as(user), ~p"/boards/#{ctx.sub}/cards/#{ctx.task.id}")

        view |> element("button[phx-click=pick_template]") |> render_click()

        view
        |> element("button[phx-click=create_sub_board][phx-value-template='#{template}']")
        |> render_click()

        assert Boards.Cards.get_card!(ctx.task.id).sub_board
        assert names(ctx) == ["ops"]
      end
    end

    test "a writer of the root gets the template's tags on the root", ctx do
      template = tagged_template(ctx.root_writer)

      ctx.root_writer
      |> api()
      |> post(~p"/api/cards/#{ctx.task.id}/subboard", %{template: template})
      |> json_response(201)

      assert names(ctx) == ["ops", "sneaky"]
    end
  end
end
