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
end
