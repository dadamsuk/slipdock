defmodule SlipdockWeb.BoardRefsTest do
  @moduledoc """
  What a board's id, code or name means depends on who is asking.

  Looked up across the whole server, a name two accounts share resolves to
  whichever board came first, so the second person cannot reach their own by
  name; and a 403 for a board the caller cannot read tells them it exists. So
  a ref only ever looks among the boards the caller can read.

  And an export takes a board's whole tree, so it is the root's owner who may
  ask for one — a sub-board can have an owner of its own.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo}
  alias Slipdock.Boards.Board

  setup do
    alice = user_fixture("alice@example.com")
    bob = user_fixture("bob@example.com")
    alices = board_fixture(%{"name" => "Personal"}, owner: alice)
    bobs = board_fixture(%{"name" => "Personal"}, owner: bob)

    %{alice: alice, bob: bob, alices: alices, bobs: bobs}
  end

  describe "resolving a ref" do
    test "two people with same-named boards each get their own", ctx do
      assert ctx.alices.code != ctx.bobs.code

      for ref <- ["Personal", "personal"] do
        assert {:ok, %{id: id}} = Access.find_board(ctx.alice, ref)
        assert id == ctx.alices.id
        assert {:ok, %{id: id}} = Access.find_board(ctx.bob, ref)
        assert id == ctx.bobs.id
      end

      body = conn_as(ctx.bob) |> get(~p"/api/boards/Personal") |> json_response(200)
      assert body["board"]["id"] == ctx.bobs.id

      # Alice's code, asked for by Bob: not hers to him, so his own name match wins.
      body = conn_as(ctx.bob) |> get(~p"/api/boards/#{ctx.alices.code}") |> json_response(200)
      assert body["board"]["id"] == ctx.bobs.id
    end

    test "a board the caller cannot read is a 404, by id or by code", ctx do
      other = board_fixture(%{"name" => "Hidden Plans", "code" => "hidden"}, owner: ctx.alice)

      for ref <- [other.id, "hidden", "Hidden Plans"] do
        assert %{"error" => "board not found"} =
                 conn_as(ctx.bob) |> get(~p"/api/boards/#{ref}") |> json_response(404)

        assert %{"error" => "board not found"} =
                 conn_as(ctx.bob) |> get(~p"/api/boards/#{ref}/cards") |> json_response(404)
      end

      assert Access.find_board(ctx.bob, to_string(other.id)) == {:error, :not_found}
    end

    test "a board shared with the caller resolves, and keeps its permission check", ctx do
      shared = board_fixture(%{"name" => "Shared", "code" => "shared"}, owner: ctx.alice)
      {:ok, _} = Access.grant(shared, ctx.bob, "read", ctx.alice)

      assert conn_as(ctx.bob) |> get(~p"/api/boards/shared") |> json_response(200)

      # Readable but not theirs to write: that much they may be told.
      assert %{"error" => "forbidden" <> _} =
               conn_as(ctx.bob)
               |> post(~p"/api/boards/shared/cards", %{"title" => "Nope"})
               |> json_response(403)
    end

    test "a sub-board resolves through its root's grant", ctx do
      {:ok, t} = Boards.find_template("Simple")
      epic = card_fixture(hd(ctx.alices.columns), %{"title" => "Epic"})
      {:ok, sub} = Boards.create_sub_board(epic, t)

      assert Access.find_board(ctx.bob, to_string(sub.id)) == {:error, :not_found}
      {:ok, _} = Access.grant(ctx.alices, ctx.bob, "read", ctx.alice)
      assert {:ok, %{id: id}} = Access.find_board(ctx.bob, to_string(sub.id))
      assert id == sub.id
    end
  end

  describe "exporting a sub-board whose root has another owner" do
    setup ctx do
      {:ok, t} = Boards.find_template("Simple")
      epic = card_fixture(hd(ctx.alices.columns), %{"title" => "Epic"})
      {:ok, sub} = Boards.create_sub_board(epic, t)
      # What `Accounts.hand_over_shared_boards` can leave behind: a sub-board
      # with an owner of its own, under somebody else's root.
      Repo.update_all(from(b in Board, where: b.id == ^sub.id), set: [owner_id: ctx.bob.id])

      %{sub: sub}
    end

    test "is refused over the API", ctx do
      assert %{"error" => "forbidden" <> _} =
               conn_as(ctx.bob) |> get(~p"/api/export?boards=#{ctx.sub.id}") |> json_response(403)
    end

    test "is left out of the download", ctx do
      body =
        conn_as(ctx.bob)
        |> get(~p"/account/boards.json?boards=#{ctx.sub.id}")
        |> response(200)
        |> Jason.decode!()

      assert body["boards"] == []
    end

    test "the root's owner gets the whole tree", ctx do
      body =
        conn_as(ctx.alice) |> get(~p"/api/export?boards=#{ctx.sub.id}") |> json_response(200)

      assert [%{"root" => %{"name" => "Personal"}}] = body["export"]["boards"]
    end
  end
end
