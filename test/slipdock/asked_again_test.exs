defmodule Slipdock.AskedAgainTest do
  @moduledoc """
  The context functions an open page calls with a struct it has kept ask the
  database again (#2999): the level a caller had when the struct was read,
  or when a proposal was prepared, is not the level they have now.

  The doors are in `SlipdockWeb.RemainingGrantLoweredLiveTest`.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo, SkillRegistry, TestConfig, Wiki}
  alias Slipdock.Access.Grant
  alias Slipdock.AI.Actions
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Inbound.{Token, Tokens}

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Kept"}, owner: owner)
    writer = user_fixture("writer@example.com")
    successor = user_fixture("successor@example.com")
    {:ok, _} = Access.grant(board, writer, "write", owner)
    %{board: Boards.get_board!(board.id), owner: owner, writer: writer, successor: successor}
  end

  # The row names somebody else; `ctx.board` is the struct read before.
  defp hand_over(ctx) do
    {1, _} =
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [owner_id: ctx.successor.id]
      )
  end

  defp lower(ctx) do
    {1, _} =
      Repo.update_all(from(g in Grant, where: g.user_id == ^ctx.writer.id), set: [level: "read"])
  end

  describe "Access.board_permission_now/2" do
    test "reads who owns the board from its row, not the struct", ctx do
      assert Access.board_permission_now(ctx.owner, ctx.board) == :owner
      hand_over(ctx)

      assert Access.board_permission(ctx.owner, ctx.board) == :owner
      assert Access.board_permission_now(ctx.owner, ctx.board) == :none
      assert Access.board_permission_now(ctx.successor, ctx.board) == :owner
    end

    test "is none for a board deleted since", ctx do
      Repo.delete_all(from(b in Board, where: b.id == ^ctx.board.id))
      assert Access.board_permission_now(ctx.owner, ctx.board) == :none
    end
  end

  describe "Inbound.Tokens.rotate/2" do
    setup do
      TestConfig.put(:inbound, domain: "in.example.com", secrets: ["s"])
      :ok
    end

    test "refuses an ex-owner holding the board's old struct", ctx do
      {:ok, _} = Tokens.addresses(ctx.owner, ctx.board)
      before = Repo.all(from(t in Token, order_by: t.id))
      hand_over(ctx)

      assert Tokens.rotate(ctx.owner, ctx.board) == {:error, :forbidden}
      assert Repo.all(from(t in Token, order_by: t.id)) == before
    end

    test "still rotates for the owner the row names", ctx do
      {:ok, %{card: old}} = Tokens.addresses(ctx.owner, ctx.board)
      assert {:ok, %{card: new}} = Tokens.rotate(ctx.owner, ctx.board)
      assert new != old
    end
  end

  describe "SkillRegistry.enable/4" do
    setup ctx do
      Slipdock.SkillRegistryStub.start(%{})

      Slipdock.SkillRegistryStub.put("octo/skills", %{
        files: %{
          "grilling/SKILL.md" => "---\nname: grilling\ndescription: Asks.\n---\n\nAsk one.\n"
        }
      })

      {:ok, %{entries: [entry]}} =
        SkillRegistry.add_source(ctx.owner, "https://github.com/octo/skills")

      %{entry: entry}
    end

    test "refuses an ex-owner holding the board's old struct", ctx do
      hand_over(ctx)

      assert {:error, "Only somebody who can write to Kept changes its skills."} =
               SkillRegistry.enable(ctx.owner, ctx.board, ctx.entry.id, ctx.entry.content_hash)

      assert SkillRegistry.enabled(ctx.board) == []
    end

    test "refuses a board deleted since", ctx do
      Repo.delete_all(from(b in Board, where: b.id == ^ctx.board.id))

      assert {:error, "That board has gone."} =
               SkillRegistry.enable(ctx.owner, ctx.board, ctx.entry.id, ctx.entry.content_hash)
    end

    test "still enables for the owner the row names", ctx do
      assert {:ok, _} =
               SkillRegistry.enable(ctx.owner, ctx.board, ctx.entry.id, ctx.entry.content_hash)
    end
  end

  describe "AI.Actions.apply/1, for a proposal prepared before the level dropped" do
    defp scope(ctx, user, pages \\ []),
      do: %{board: ctx.board, cards: [], pages: pages, user: user, users: []}

    defp cards(ctx), do: Repo.all(from(c in Card, where: c.board_id == ^ctx.board.id))

    test "a create makes no card for a writer lowered to read", ctx do
      [step] =
        Actions.prepare([%{"type" => "create", "title" => "Sneaked"}], scope(ctx, ctx.writer))

      assert step.error == nil
      lower(ctx)

      assert [%{result: {:error, "you have read-only access to this board"}}] =
               Actions.apply([step])

      assert cards(ctx) == []
    end

    test "a create makes no card for an ex-owner, whose scope kept the old struct", ctx do
      [step] =
        Actions.prepare([%{"type" => "create", "title" => "Sneaked"}], scope(ctx, ctx.owner))

      assert step.error == nil
      hand_over(ctx)

      assert [%{result: {:error, "you have read-only access to this board"}}] =
               Actions.apply([step])

      assert cards(ctx) == []
    end

    test "a create is refused when prepared by an ex-owner too", ctx do
      hand_over(ctx)

      assert [%{error: "you have read-only access to this board", run: nil}] =
               Actions.prepare(
                 [%{"type" => "create", "title" => "Sneaked"}],
                 scope(ctx, ctx.owner)
               )
    end

    test "a create still makes the card for a writer", ctx do
      [step] =
        Actions.prepare([%{"type" => "create", "title" => "Wanted"}], scope(ctx, ctx.writer))

      assert [%{result: :ok}] = Actions.apply([step])
      assert [%Card{title: "Wanted"}] = cards(ctx)
    end

    test "an archive_page archives nothing for a writer lowered to read", ctx do
      {:ok, page} = Wiki.create_page(ctx.board, %{"title" => "Launch", "body" => "Words."})

      [step] =
        Actions.prepare(
          [%{"type" => "archive_page", "page" => page.code}],
          scope(ctx, ctx.writer, [page])
        )

      assert step.error == nil
      lower(ctx)

      assert [%{result: {:error, "you have read-only access to “Launch”"}}] =
               Actions.apply([step])

      assert Wiki.get_page!(page.id).archived_at == nil
    end

    test "an archive_page still archives for a writer", ctx do
      {:ok, page} = Wiki.create_page(ctx.board, %{"title" => "Launch", "body" => "Words."})

      [step] =
        Actions.prepare(
          [%{"type" => "archive_page", "page" => page.code}],
          scope(ctx, ctx.writer, [page])
        )

      assert [%{result: :ok}] = Actions.apply([step])
      assert Wiki.get_page!(page.id).archived_at != nil
    end
  end
end
