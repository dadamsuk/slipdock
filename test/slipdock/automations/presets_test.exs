defmodule Slipdock.Automations.PresetsTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Automations, Boards}
  alias Slipdock.Automations.{Presets, Rule}

  setup do
    owner = user_fixture()
    board = Boards.get_board!(board_fixture(%{"name" => "Launch"}).id)
    [backlog, doing, _review, done] = board.columns
    %{owner: owner, board: board, backlog: backlog, doing: doing, done: done}
  end

  defp add(board, owner, key, params) do
    Automations.create_rule_from_preset(board, key, params, created_by: owner)
  end

  defp titles(owner), do: owner |> Automations.list_alerts() |> Enum.map(& &1.title)

  describe "the catalogue" do
    test "every preset builds a rule the runner accepts from its own defaults", %{board: board} do
      filled = %{
        "column" => "Doing",
        "card" => "12",
        "tag" => "urgent",
        "url" => "https://example.com/hook"
      }

      for preset <- Presets.all() do
        params = Map.merge(Presets.defaults(preset, board), filled)

        assert {:ok, %{"name" => name, "spec" => spec}} =
                 Presets.build(preset.key, params, user: user_fixture()),
               "#{preset.key} did not build"

        assert name != ""
        assert Rule.summary(%Rule{spec: spec}) =~ "When "
      end
    end

    test "a done-list field starts out as the board's done list", %{board: board, done: done} do
      preset = Presets.get("complete_in_done")
      assert Presets.defaults(preset, board)["column"] == done.name
    end

    test "says which field is missing, and refuses what it cannot use" do
      assert {:error, msg} = Presets.build("follow_list", %{"notify" => "alert"})
      assert msg =~ "List"

      assert {:error, msg} = Presets.build("follow_card", %{"card" => "the big one"})
      assert msg =~ "number"

      assert {:error, msg} =
               Presets.build("follow_board", %{"notify" => "email", "email" => "not an address"})

      assert msg =~ "isn't an email address"

      assert {:error, msg} = Presets.build("nope", %{})
      assert msg =~ "unknown preset"
    end

    test "email goes to the person adding the rule unless told otherwise", %{owner: owner} do
      assert {:ok, %{"spec" => %{"actions" => [%{"type" => "email", "to" => to}]}}} =
               Presets.build("follow_board", %{"notify" => "email"}, user: owner)

      assert to == owner.email
    end
  end

  describe "following" do
    test "follow a board hears about every new card", %{owner: owner, board: board} = ctx do
      {:ok, _} = add(board, owner, "follow_board", %{"notify" => "alert"})

      card_fixture(ctx.backlog, %{"title" => "One"})
      card_fixture(ctx.done, %{"title" => "Two"})

      assert Enum.sort(titles(owner)) == ["New card: One", "New card: Two"]
    end

    test "follow a list hears about cards added to it and moved into it", ctx do
      {:ok, _} = add(ctx.board, ctx.owner, "follow_list", %{"column" => ctx.doing.name})

      card_fixture(ctx.doing, %{"title" => "Added"})
      moved = card_fixture(ctx.backlog, %{"title" => "Moved"})
      card_fixture(ctx.backlog, %{"title" => "Elsewhere"})
      :ok = Boards.move_card(moved.id, ctx.doing.id)

      assert Enum.sort(titles(ctx.owner)) == [
               "In #{ctx.doing.name}: Added",
               "In #{ctx.doing.name}: Moved"
             ]
    end

    test "follow a card hears about that card only, once per change", ctx do
      card = card_fixture(ctx.backlog, %{"title" => "Watched"})
      other = card_fixture(ctx.backlog, %{"title" => "Ignored"})

      {:ok, _} =
        add(ctx.board, ctx.owner, "follow_card", %{"card" => "##{card.id}", "notify" => "email"})

      {:ok, _} = Boards.toggle_completed(other)
      refute_email_sent()

      # Completing is a card_updated and a card_completed; following hears one.
      {:ok, _} = Boards.toggle_completed(card)
      assert_email_sent(subject: "Watched: card_updated")
      refute_email_sent()

      {:ok, _} = Boards.add_comment(Boards.get_card!(card.id), "Nice")
      assert_email_sent(subject: "Watched: comment_added")
    end

    test "comments can be narrowed to one person's cards", ctx do
      sam = user_fixture("sam@example.com")
      mine = card_fixture(ctx.backlog, %{"title" => "Sam's"})
      {:ok, _} = Boards.update_card(mine, %{"assignee_ids" => [sam.id]})
      theirs = card_fixture(ctx.backlog, %{"title" => "Nobody's"})

      {:ok, _} = add(ctx.board, ctx.owner, "watch_comments", %{"assignee" => "sam@example.com"})

      {:ok, _} = Boards.add_comment(Boards.get_card!(theirs.id), "hello")
      {:ok, _} = Boards.add_comment(Boards.get_card!(mine.id), "hello")

      assert titles(ctx.owner) == ["New comment on Sam's"]
    end

    test "a field change can be followed by itself", ctx do
      card = card_fixture(ctx.backlog, %{"title" => "Dated"})
      {:ok, _} = add(ctx.board, ctx.owner, "watch_field", %{"field" => "due_date"})

      {:ok, card} = Boards.update_card(card, %{"title" => "Dated still"})
      assert titles(ctx.owner) == []

      {:ok, _} = Boards.update_card(card, %{"due_date" => "2030-01-01"})
      assert titles(ctx.owner) == ["Due date changed: Dated still"]
    end
  end

  describe "tidying" do
    test "cards that land in Done are ticked off", ctx do
      {:ok, _} = add(ctx.board, ctx.owner, "complete_in_done", %{"column" => ctx.done.name})

      card = card_fixture(ctx.backlog)
      :ok = Boards.move_card(card.id, ctx.done.id)

      assert Boards.get_card!(card.id).completed
    end

    test "a tag raises the priority", ctx do
      tag = tag_fixture(ctx.board, "urgent")
      {:ok, _} = add(ctx.board, ctx.owner, "tag_priority", %{"tag" => "urgent"})

      card = card_fixture(ctx.backlog)
      {:ok, _} = Boards.toggle_card_tag(card, tag)

      assert Boards.get_card!(card.id).priority == "critical"
    end
  end
end
