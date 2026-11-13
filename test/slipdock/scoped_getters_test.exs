defmodule Slipdock.ScopedGettersTest do
  @moduledoc """
  The getters for an id a client sent (#2874): the row if it is on the card or
  the tree asked about, nil for anything else, and never a raise.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias Slipdock.Boards.{Attachments, Milestones}
  alias Slipdock.Fields

  setup do
    mine = board_fixture(%{"name" => "Mine"})
    theirs = board_fixture(%{"name" => "Theirs"}, owner: user_fixture("other@example.com"))
    %{mine: mine, theirs: theirs}
  end

  describe "Boards.Attachments.get_card_attachment/2" do
    setup ctx do
      Slipdock.TestConfig.own_uploads_dir()
      card = card_fixture(hd(ctx.mine.columns), %{"title" => "Mine"})
      other = card_fixture(hd(ctx.mine.columns), %{"title" => "Beside it"})
      path = Path.join(System.tmp_dir!(), "scoped-#{System.unique_integer([:positive])}")
      File.write!(path, "PK")
      on_exit(fn -> File.rm(path) end)

      {:ok, a} =
        Attachments.add_attachment(
          card,
          %{filename: "a.zip", content_type: "application/zip"},
          path
        )

      %{card: card, other: other, attachment: a}
    end

    test "gives the card's own attachment, by integer or string id, with its card", ctx do
      assert %{id: id, card: %Boards.Card{id: card_id}, page: nil} =
               Attachments.get_card_attachment(ctx.card.id, ctx.attachment.id)

      assert id == ctx.attachment.id
      assert card_id == ctx.card.id
      assert Attachments.get_card_attachment(ctx.card.id, "#{ctx.attachment.id}").id == id
    end

    test "is nil for another card's, even one on the same board", ctx do
      assert Attachments.get_card_attachment(ctx.other.id, ctx.attachment.id) == nil
    end

    test "is nil for an id that is gone, malformed or missing", ctx do
      {:ok, _} = Attachments.delete_attachment(ctx.attachment)

      assert Attachments.get_card_attachment(ctx.card.id, ctx.attachment.id) == nil
      assert Attachments.get_card_attachment(ctx.card.id, "12abc") == nil
      assert Attachments.get_card_attachment(ctx.card.id, "") == nil
      assert Attachments.get_card_attachment(ctx.card.id, nil) == nil
    end
  end

  describe "Fields.get_board_field/2" do
    setup ctx do
      {:ok, field} = Fields.create_field(ctx.mine, %{"name" => "Points", "kind" => "number"})
      %{field: field}
    end

    test "gives the tree's own field, by integer or string id", ctx do
      assert Fields.get_board_field(ctx.mine.id, ctx.field.id).id == ctx.field.id
      assert Fields.get_board_field(ctx.mine.id, "#{ctx.field.id}").name == "Points"
    end

    test "is nil for another tree's", ctx do
      assert Fields.get_board_field(ctx.theirs.id, ctx.field.id) == nil
    end

    test "is nil for an id that is gone, malformed or missing", ctx do
      {:ok, _} = Fields.delete_field(ctx.field)

      assert Fields.get_board_field(ctx.mine.id, ctx.field.id) == nil
      assert Fields.get_board_field(ctx.mine.id, "12abc") == nil
      assert Fields.get_board_field(ctx.mine.id, nil) == nil
    end
  end

  describe "Boards.Milestones.get_board_milestone/2" do
    setup ctx do
      {:ok, milestone} =
        Milestones.create_milestone(ctx.mine, %{"name" => "Beta", "date" => "2030-01-01"})

      %{milestone: milestone}
    end

    test "gives the tree's own milestone, by integer or string id", ctx do
      assert Milestones.get_board_milestone(ctx.mine.id, ctx.milestone.id).id == ctx.milestone.id
      assert Milestones.get_board_milestone(ctx.mine.id, "#{ctx.milestone.id}").name == "Beta"
    end

    test "is nil for another tree's", ctx do
      assert Milestones.get_board_milestone(ctx.theirs.id, ctx.milestone.id) == nil
    end

    test "is nil for an id that is gone, malformed or missing", ctx do
      {:ok, _} = Milestones.delete_milestone(ctx.milestone)

      assert Milestones.get_board_milestone(ctx.mine.id, ctx.milestone.id) == nil
      assert Milestones.get_board_milestone(ctx.mine.id, "12abc") == nil
      assert Milestones.get_board_milestone(ctx.mine.id, nil) == nil
    end
  end
end
