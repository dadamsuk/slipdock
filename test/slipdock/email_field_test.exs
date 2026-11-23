defmodule Slipdock.EmailFieldTest do
  @moduledoc """
  Email fields and the settings each type takes (#3647). An email field
  holds one address, refused otherwise at every door (a form, the API, an
  import); a text field may have a most characters; a number's range must
  run forwards; a rating has 2 to 10 stars; a choice names each option once.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields}
  alias Slipdock.Boards.FieldDefinition

  setup do
    board = board_fixture(%{"name" => "Contacts"})
    [col | _] = board.columns
    {:ok, email} = Fields.create_field(board, %{"name" => "Email", "kind" => "email"})
    card = card_fixture(col, %{"title" => "Ada"})
    %{board: board, email: email, card: card}
  end

  describe "an email field" do
    test "takes an address, trimmed, and an empty value clears it", %{email: email, card: card} do
      {:ok, card} = Fields.set_value(card, email, "  ada@example.com ")
      assert Fields.value(card, email) == "ada@example.com"
      assert Fields.format(email, "ada@example.com") == "ada@example.com"

      {:ok, card} = Fields.set_value(card, email, "")
      assert Fields.value(card, email) == nil
    end

    test "refuses anything that isn't an address, and keeps the value it had",
         %{email: email, card: card} do
      {:ok, _} = Fields.set_value(card, email, "kept@example.com")

      for bad <- [
            "ada",
            "ada@",
            "@example.com",
            "ada@example",
            "ada @example.com",
            "ada@@example.com",
            "mailto:ada@example.com, b@example.com",
            "ada@example."
          ] do
        assert {:error, "Email needs an email address, like name@example.com."} =
                 Fields.set_value(Boards.Cards.get_card!(card.id), email, bad),
               bad
      end

      assert Fields.value(Boards.Cards.get_card!(card.id), email) == "kept@example.com"
    end

    test "email? is one @, something before it, and a dotted domain after" do
      assert Fields.email?("a.b+c@sub.example.com")
      refute Fields.email?("a@b")
      refute Fields.email?(nil)
      refute Fields.email?("a b@example.com")
    end

    test "is text to filter on, and not a swimlane axis", %{email: email} do
      assert FieldDefinition.text_kind?("email")
      refute FieldDefinition.axis?(email)
    end

    test "an import holds its value to an address too" do
      importer = user_fixture("importer@example.com")

      document =
        Jason.encode!(%{
          slipdock_portable: 1,
          boards: [
            %{
              root: %{
                ref: "r",
                name: "Imported",
                code: "imp",
                lists: [%{ref: "l1", name: "To Do"}]
              },
              boards: [],
              fields: [%{ref: "f1", name: "Email", key: "email", kind: "email"}],
              cards: [
                %{
                  ref: "k1",
                  board: "r",
                  list: "l1",
                  title: "Bad",
                  fields: [%{field: "f1", text: "not an address"}]
                },
                %{
                  ref: "k2",
                  board: "r",
                  list: "l1",
                  title: "Good",
                  fields: [%{field: "f1", text: "ada@example.com"}]
                }
              ]
            }
          ]
        })

      {:ok, report} = Slipdock.Portable.import(importer, document)
      board = Boards.get_board!(hd(report.boards).id)
      [email] = Fields.list_fields(board.id)
      cards = Boards.Cards.list_cards(board, %{}) |> Map.new(&{&1.title, &1})

      assert Fields.value(cards["Good"], email) == "ada@example.com"
      assert Fields.value(cards["Bad"], email) == nil

      assert Enum.any?(
               report.skipped,
               &(&1 =~ "A field value on “Bad” was left out: Email needs an email address")
             )
    end
  end

  describe "a text field's most characters" do
    test "is optional: a text field needs nothing but a name", %{board: board} do
      assert {:ok, %{kind: "text", config: %{}}} =
               Fields.create_field(board, %{"name" => "Notes", "kind" => "text"})
    end

    test "is a whole number of at least 1, and holds values to it", %{board: board, card: card} do
      {:ok, code} =
        Fields.create_field(board, %{
          "name" => "Code",
          "kind" => "text",
          "config" => %{"max_length" => "3"}
        })

      assert code.config == %{"max_length" => 3}
      assert {:ok, _} = Fields.set_value(card, code, "ABC")
      assert {:error, "Code takes at most 3 characters."} = Fields.set_value(card, code, "ABCD")

      for bad <- ["0", "-2", "2.5", "lots"] do
        assert {:error, cs} =
                 Fields.create_field(board, %{
                   "name" => "Other #{bad}",
                   "kind" => "text",
                   "config" => %{"max_length" => bad}
                 }),
               bad

        assert errors_on(cs)[:config] == ["most characters must be a whole number of at least 1"]
      end
    end
  end

  describe "a field's settings" do
    test "a number's least must not be more than its most, and a step is more than 0",
         %{board: board} do
      assert {:ok, _} =
               Fields.create_field(board, %{
                 "name" => "Fine",
                 "kind" => "number",
                 "config" => %{"min" => "1", "max" => "1"}
               })

      assert {:error, cs} =
               Fields.create_field(board, %{
                 "name" => "Backwards",
                 "kind" => "number",
                 "config" => %{"min" => "10", "max" => "1"}
               })

      assert errors_on(cs)[:config] == ["least must not be more than most"]

      assert {:error, cs} =
               Fields.create_field(board, %{
                 "name" => "Stuck",
                 "kind" => "number",
                 "config" => %{"step" => "0"}
               })

      assert errors_on(cs)[:config] == ["step must be more than 0"]
    end

    test "a rating has 2 to 10 stars", %{board: board} do
      assert {:ok, _} =
               Fields.create_field(board, %{
                 "name" => "Ten",
                 "kind" => "rating",
                 "config" => %{"max" => "10"}
               })

      for bad <- ["1", "11", "3.5"] do
        assert {:error, cs} =
                 Fields.create_field(board, %{
                   "name" => "Stars #{bad}",
                   "kind" => "rating",
                   "config" => %{"max" => bad}
                 }),
               bad

        assert errors_on(cs)[:config] == ["stars must be a whole number from 2 to 10"]
      end
    end

    test "a choice names each option once", %{board: board} do
      assert {:error, cs} =
               Fields.create_field(board, %{
                 "name" => "Stage",
                 "kind" => "select",
                 "options" => ["Lead", "lead"]
               })

      assert errors_on(cs)[:options] == ["each choice needs a different name"]
    end
  end
end
