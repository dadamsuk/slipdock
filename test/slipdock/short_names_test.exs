defmodule Slipdock.ShortNamesTest do
  @moduledoc "Card short names (W-2201 §Names): made at once, improved by a model, never needed."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{AIStub, Boards, Repo, TestConfig}
  alias Slipdock.Boards.{Card, ShortNames}

  @long "Agent supervision 5/9: Parked jobs must be released on timeout"

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Names"}, owner: user)
    column = hd(board.columns)
    %{board: board, column: column, user: user}
  end

  defp card!(column, title, attrs \\ %{}) do
    {:ok, card} = Boards.create_card(column, Map.merge(%{"title" => title}, attrs))
    Repo.get!(Card, card.id)
  end

  describe "systematic/1" do
    test "cuts at a word, within 30 characters, and marks the cut" do
      name = ShortNames.systematic(@long)

      assert name == "Agent supervision 5-9- Parked…"
      assert String.length(name) <= 30
    end

    test "is nil for a title that isn't long" do
      assert ShortNames.systematic("Fine as it is") == nil
      assert ShortNames.systematic(String.duplicate("x", 40)) == nil
    end

    test "cuts hard when no word boundary keeps half" do
      name = ShortNames.systematic("Hi " <> String.duplicate("x", 60))

      assert String.length(name) == 30
      assert String.ends_with?(name, "…")
    end

    test "cleans punctuation and keeps emoji" do
      name = ShortNames.systematic("🚀 launch: #ship [the] big one before the end of the month")

      assert String.starts_with?(name, "🚀 launch- ship the big")
      refute name =~ ~r/[#\[\]:]/
    end

    test "ignores surrounding space when deciding a title is long" do
      assert ShortNames.systematic("  " <> String.duplicate("x", 40) <> "  ") == nil
    end
  end

  describe "on a card" do
    test "a long title has one as soon as the card is saved", %{column: column} do
      card = card!(column, @long)

      assert card.short_name == ShortNames.systematic(@long)
      refute card.short_name_edited
    end

    test "a title of 40 characters or fewer has none", %{column: column} do
      assert card!(column, String.duplicate("x", 40)).short_name == nil
    end

    test "a new long title makes a new one; a short title takes it away", %{column: column} do
      card = card!(column, @long)

      {:ok, card} = Boards.update_card(card, %{"title" => "Another long title " <> @long})
      assert card.short_name == "Another long title Agent…"

      {:ok, card} = Boards.update_card(card, %{"title" => "Short now"})
      assert card.short_name == nil
    end

    test "a typed one is kept when the title changes", %{column: column} do
      card = card!(column, @long)

      {:ok, card} = Boards.update_card(card, %{"short_name" => "Parked jobs"})
      assert card.short_name_edited

      {:ok, card} = Boards.update_card(card, %{"title" => "Quite different " <> @long})
      assert card.short_name == "Parked jobs"
    end

    test "clearing a typed one hands it back", %{column: column} do
      card = card!(column, @long, %{"short_name" => "Mine"})
      assert card.short_name_edited

      {:ok, card} = Boards.update_card(card, %{"short_name" => ""})

      refute card.short_name_edited
      assert card.short_name == ShortNames.systematic(@long)
    end

    test "a typed one can sit on a short title", %{column: column} do
      card = card!(column, "Brief", %{"short_name" => "B"})
      assert card.short_name == "B"
      assert card.short_name_edited
    end

    test "one over the limit is refused", %{column: column} do
      card = card!(column, "Brief")

      assert {:error, changeset} =
               Boards.update_card(card, %{"short_name" => String.duplicate("x", 41)})

      assert %{short_name: [_]} = errors_on(changeset)
    end

    test "a form sending back the systematic name doesn't mark it typed", %{column: column} do
      card = card!(column, @long)
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [short_name: "By the model"])
      card = Repo.get!(Card, card.id)

      {:ok, card} =
        Boards.update_card(card, %{"short_name" => ShortNames.systematic(@long)})

      refute card.short_name_edited
    end
  end

  describe "refine/1" do
    test "saves the model's answer, asking the quick model", %{column: column} do
      AIStub.reply_with("Agent supervision 5: Parked jobs")
      card = card!(column, @long)

      assert ShortNames.refine(card) == {:ok, "Agent supervision 5: Parked jobs"}

      assert_received {:ai_request, body}
      assert inspect(body["messages"]) =~ "tells this card from its siblings"
      assert Repo.get!(Card, card.id).short_name == "Agent supervision 5: Parked jobs"
    end

    test "tidies quotes and trailing punctuation", %{column: column} do
      AIStub.reply_with(~s("Parked jobs."))
      card = card!(column, @long)

      assert ShortNames.refine(card) == {:ok, "Parked jobs"}
    end

    for {label, reply} <- [
          {"an empty reply", "   "},
          {"one too long", String.duplicate("word ", 12)},
          {"nothing but punctuation", "..."}
        ] do
      test "#{label} leaves the systematic name", %{column: column} do
        AIStub.reply_with(unquote(reply))
        card = card!(column, @long)

        assert ShortNames.refine(card) == :kept
        assert Repo.get!(Card, card.id).short_name == ShortNames.systematic(@long)
      end
    end

    test "a failed call leaves the systematic name", %{column: column} do
      Req.Test.stub(Slipdock.AI, &Plug.Conn.send_resp(&1, 500, "boom"))
      card = card!(column, @long)

      assert ShortNames.refine(card) == :kept
      assert Repo.get!(Card, card.id).short_name == ShortNames.systematic(@long)
    end

    test "with no stub at all it doesn't raise", %{column: column} do
      card = card!(column, @long)

      assert ShortNames.refine(card) == :kept
    end

    test "with no key it asks nobody, and the card is saved all the same", %{column: column} do
      TestConfig.merge(:ai, api_key: nil)
      card = card!(column, @long)

      assert ShortNames.refine(card) == :kept
      assert card.short_name == ShortNames.systematic(@long)
      refute_received {:ai_request, _}
    end

    test "never touches a typed name, nor one for a title since changed", %{column: column} do
      AIStub.reply_with("From the model")
      typed = card!(column, @long, %{"short_name" => "Mine"})
      stale = card!(column, @long)
      {:ok, _} = Boards.update_card(stale, %{"title" => "Now something else, also quite long"})

      assert ShortNames.refine(typed) == :kept
      assert ShortNames.refine(stale) == :kept
      assert Repo.get!(Card, typed.id).short_name == "Mine"
      assert Repo.get!(Card, stale.id).short_name == nil
    end
  end

  describe "on saving" do
    test "the model is asked on create and on a title change, not otherwise", %{column: column} do
      TestConfig.merge(:short_names, refine: :inline)
      AIStub.reply_with("Named by model")

      card = card!(column, @long)
      assert card.short_name == "Named by model"
      assert_received {:ai_request, _}

      {:ok, _} = Boards.update_card(card, %{"description" => "more"})
      refute_received {:ai_request, _}

      card = Repo.get!(Card, card.id)

      {:ok, _} =
        Boards.update_card(card, %{"title" => "A different title that is well over the limit"})

      assert_received {:ai_request, _}
    end

    test "not for a typed name, and again when one is cleared", %{column: column} do
      TestConfig.merge(:short_names, refine: :inline)
      AIStub.reply_with("Named by model")

      card = card!(column, @long, %{"short_name" => "Mine"})
      refute_received {:ai_request, _}

      {:ok, _} = Boards.update_card(card, %{"short_name" => ""})
      assert_received {:ai_request, _}
      assert Repo.get!(Card, card.id).short_name == "Named by model"
    end
  end

  describe "backfill/1" do
    setup %{column: column} do
      long = card!(column, @long)
      Repo.update_all(from(c in Card, where: c.id == ^long.id), set: [short_name: nil])
      %{long: long}
    end

    test "with no key, the systematic name", %{long: long, column: column} do
      TestConfig.merge(:ai, api_key: nil)
      typed = card!(column, @long, %{"short_name" => "Mine"})

      assert %{named: named, by_model: 0} = ShortNames.backfill(ids: [long.id, typed.id])

      assert named == 1
      assert Repo.get!(Card, long.id).short_name == ShortNames.systematic(@long)
      assert Repo.get!(Card, typed.id).short_name == "Mine"
    end

    test "with a key, the model's, and a second run does nothing", %{long: long} do
      AIStub.reply_with("Backfilled")

      assert ShortNames.backfill(ids: [long.id]) == %{named: 1, by_model: 1}
      assert Repo.get!(Card, long.id).short_name == "Backfilled"
      assert ShortNames.backfill(ids: [long.id]) == %{named: 0, by_model: 0}
    end
  end
end
