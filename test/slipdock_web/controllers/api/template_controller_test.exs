defmodule SlipdockWeb.API.TemplateControllerTest do
  @moduledoc """
  /api/templates: a person sees the built-ins and their own, changes only
  their own, and nobody — an admin included — changes a built-in (#856).
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Repo

  setup %{user: user} do
    stranger = user_fixture("template-stranger@example.com")
    {:ok, simple} = Boards.find_template(nil, "Simple")
    {:ok, mine} = Boards.create_template(user, %{"name" => uniq("Mine"), "columns" => ["A"]})

    {:ok, theirs} =
      Boards.create_template(stranger, %{"name" => uniq("Theirs"), "columns" => ["B"]})

    %{
      stranger: stranger,
      stranger_conn: json_conn(conn_as(stranger)),
      simple: simple,
      mine: mine,
      theirs: theirs
    }
  end

  defp uniq(prefix), do: "#{prefix} #{System.unique_integer([:positive])}"
  defp json_conn(conn), do: put_req_header(conn, "accept", "application/json")

  defp admin_conn do
    admin =
      user_fixture("template-admin@example.com")
      |> Ecto.Changeset.change(admin: true)
      |> Repo.update!()

    json_conn(conn_as(admin))
  end

  describe "index" do
    test "lists the built-ins and the caller's own, never somebody else's", ctx do
      names = ctx.conn |> get(~p"/api/templates") |> json_response(200) |> names()

      assert ctx.simple.name in names
      assert ctx.mine.name in names
      refute ctx.theirs.name in names

      their_names = ctx.stranger_conn |> get(~p"/api/templates") |> json_response(200) |> names()
      assert ctx.theirs.name in their_names
      refute ctx.mine.name in their_names
    end

    test "says which are built in", ctx do
      templates =
        ctx.conn |> get(~p"/api/templates") |> json_response(200) |> Map.get("templates")

      by_name = Map.new(templates, &{&1["name"], &1["system"]})

      assert by_name[ctx.simple.name] == true
      assert by_name[ctx.mine.name] == false
    end
  end

  describe "show" do
    test "a built-in or one's own is 200; somebody else's is 404, by id or name", ctx do
      assert ctx.conn |> get(~p"/api/templates/#{ctx.simple.id}") |> json_response(200)
      assert ctx.conn |> get(~p"/api/templates/#{ctx.mine.id}") |> json_response(200)
      assert ctx.conn |> get(~p"/api/templates/#{ctx.theirs.id}") |> json_response(404)
      assert ctx.conn |> get(~p"/api/templates/#{ctx.theirs.name}") |> json_response(404)
    end
  end

  describe "create" do
    test "stamps the caller as owner, whatever owner_id or system the body says", ctx do
      body =
        ctx.conn
        |> post(~p"/api/templates", %{
          "name" => "Forged",
          "columns" => ["X"],
          "owner_id" => ctx.stranger.id,
          "system" => true
        })
        |> json_response(201)

      assert body["template"]["system"] == false
      template = Repo.get!(Boards.Template, body["template"]["id"])
      assert template.owner_id == ctx.user.id
      refute template.system
    end

    test "a built-in's name is taken, in any case", ctx do
      body =
        ctx.conn
        |> post(~p"/api/templates", %{"name" => "simple", "columns" => ["X"]})
        |> json_response(422)

      assert body["details"]["name"] == ["already exists"]
    end

    test "two people may each have a template of the same name", ctx do
      ctx.stranger_conn
      |> post(~p"/api/templates", %{"name" => ctx.mine.name, "columns" => ["X"]})
      |> json_response(201)
    end
  end

  describe "update and delete" do
    test "the owner may change and delete their own", ctx do
      body =
        ctx.conn
        |> patch(~p"/api/templates/#{ctx.mine.id}", %{"name" => "Renamed mine"})
        |> json_response(200)

      assert body["template"]["name"] == "Renamed mine"
      assert ctx.conn |> delete(~p"/api/templates/#{ctx.mine.id}") |> json_response(200)
      assert {:error, :not_found} = Boards.find_template(ctx.user, ctx.mine.id)
    end

    # The review's proof of concept: PATCH /api/templates/:id with someone
    # else's template id used to answer 200 and persist.
    test "another person's template is a 404 and unchanged", ctx do
      assert ctx.conn
             |> patch(~p"/api/templates/#{ctx.theirs.id}", %{"name" => "PENTEST-EDITED"})
             |> json_response(404)

      assert ctx.conn |> delete(~p"/api/templates/#{ctx.theirs.id}") |> json_response(404)
      assert Repo.get!(Boards.Template, ctx.theirs.id).name == ctx.theirs.name
    end

    test "a built-in is a 403 for anybody, and unchanged", ctx do
      for conn <- [ctx.conn, admin_conn()] do
        body =
          conn
          |> patch(~p"/api/templates/#{ctx.simple.id}", %{"name" => "PENTEST-EDITED"})
          |> json_response(403)

        assert body["error"] =~ "built-in templates can't be changed"
        assert conn |> delete(~p"/api/templates/#{ctx.simple.id}") |> json_response(403)
      end

      assert Repo.get!(Boards.Template, ctx.simple.id).name == "Simple"
    end

    test "a read-only token can't change even one's own", ctx do
      {token, _} = Slipdock.Accounts.create_api_token(ctx.user, "ro", scope: "read")

      conn =
        Phoenix.ConnTest.build_conn()
        |> json_conn()
        |> put_req_header("authorization", "Bearer " <> token)

      assert conn
             |> patch(~p"/api/templates/#{ctx.mine.id}", %{"name" => "X"})
             |> json_response(403)
    end
  end

  describe "other ways in" do
    test "a sub-board can't be made from somebody else's template", ctx do
      board = board_fixture(%{"name" => "Mine"}, owner: ctx.user)
      card = card_fixture(hd(board.columns), %{"title" => "Epic"})

      assert ctx.conn
             |> post(~p"/api/cards/#{card.id}/subboard", %{"template" => ctx.theirs.name})
             |> json_response(404)

      assert ctx.conn
             |> post(~p"/api/cards/#{card.id}/subboard", %{"template" => ctx.mine.name})
             |> json_response(201)
    end

    test "nor a board", ctx do
      assert ctx.conn
             |> post(~p"/api/boards", %{"name" => "Copy", "template" => ctx.theirs.id})
             |> json_response(404)
    end
  end

  defp names(%{"templates" => templates}), do: Enum.map(templates, & &1["name"])
end
