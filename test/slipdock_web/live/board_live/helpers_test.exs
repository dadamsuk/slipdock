defmodule SlipdockWeb.BoardLive.HelpersTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Slipdock.Boards.Wait
  alias SlipdockWeb.BoardLive.Helpers

  # A schemaless changeset with whichever errors a test needs.
  defp changeset(errors) do
    base = change({%{}, %{name: :string, key: :string}})
    Enum.reduce(errors, base, fn {field, msg, opts}, cs -> add_error(cs, field, msg, opts) end)
  end

  describe "tag_by_id/2 (#2889)" do
    @board %{tags: [%{id: 7, name: "bug"}, %{id: 12, name: "chore"}]}

    test "finds a tag by the integer id a filter holds" do
      assert Helpers.tag_by_id(@board, 12).name == "chore"
    end

    test "finds a tag by the string id an event carries" do
      assert Helpers.tag_by_id(@board, "7").name == "bug"
      assert Helpers.tag_by_id(@board, " 12 ").name == "chore"
    end

    test "an id no tag of the board has finds nothing" do
      assert Helpers.tag_by_id(@board, 8) == nil
      assert Helpers.tag_by_id(@board, "8") == nil
      assert Helpers.tag_by_id(%{tags: []}, "7") == nil
    end

    test "a value that isn't an id finds nothing, and doesn't raise" do
      for value <- ["", "7abc", "bug", "0", "-7", 0, nil, 7.0, %{"id" => 7}] do
        assert Helpers.tag_by_id(@board, value) == nil
      end
    end
  end

  describe "changeset_message/1 (#2873)" do
    test "fills a %{count} placeholder from the error's opts" do
      cs = changeset([{:name, "at most %{count}", count: 3}])

      assert Helpers.changeset_message(cs) == "Name at most 3"
    end

    test "a wait with too many questions reads as a number, not %{count}" do
      questions = Enum.map(1..(Wait.max_questions() + 1), &"Question #{&1}?")
      cs = Wait.changeset(%Wait{}, %{"needs" => "answers", "questions" => questions})

      message = Helpers.changeset_message(cs)

      assert message =~ "Questions at most #{Wait.max_questions()}"
      refute message =~ "%{"
    end

    test "fills a placeholder other than count, and leaves plain messages alone" do
      cs =
        changeset([
          {:name, "should be %{kind}", kind: "short"},
          {:key, "can't be blank", validation: :required}
        ])

      parts = cs |> Helpers.changeset_message() |> String.split("; ") |> Enum.sort()
      assert parts == ["Key can't be blank", "Name should be short"]
    end

    test "joins several errors on one field" do
      cs = changeset([{:name, "is taken", []}, {:name, "at most %{count}", count: 2}])

      assert Helpers.changeset_message(cs) == "Name at most 2, is taken"
    end

    test "a valid changeset says nothing" do
      assert Helpers.changeset_message(changeset([])) == ""
    end
  end

  describe "field_errors/1 (#2873)" do
    test "names the field as it is and fills the placeholder" do
      cs = changeset([{:key, "should be at most %{count} character(s)", count: 40}])

      assert Helpers.field_errors(cs) == "key should be at most 40 character(s)"
    end
  end

  describe "error_text/1 and url_error/1 (#2873)" do
    test "error_text fills placeholders from the opts" do
      assert Helpers.error_text({"at most %{count}", count: 5}) == "at most 5"
      assert Helpers.error_text({"is invalid", []}) == "is invalid"
    end

    test "url_error interpolates the first error, and has a fallback" do
      assert Helpers.url_error(changeset([{:url, "at most %{count}", count: 2048}])) ==
               "at most 2048"

      assert Helpers.url_error(changeset([])) == "could not be added"
    end
  end

  describe "upload_failed/1 and incident_error/1 (#2873)" do
    test "upload_failed names each error with its placeholder filled" do
      cs = changeset([{:name, "should be at most %{count} character(s)", count: 255}])

      assert Helpers.upload_failed(cs) ==
               "Upload failed: name should be at most 255 character(s)."
    end

    test "upload_failed says the file wasn't stored when no error is named" do
      assert Helpers.upload_failed(changeset([])) == "Upload failed: file could not be stored."
    end

    test "incident_error keeps Missed by for that field and fills placeholders in each" do
      cs =
        changeset([])
        |> add_error(:missed_by, "must be one of %{n} checks", n: 4)
        |> add_error(:caused_by_id, "at most %{count} links", count: 1)

      assert Helpers.incident_error(cs) == "at most 1 links Missed by must be one of 4 checks."
    end
  end
end
