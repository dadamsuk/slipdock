defmodule Slipdock.ChangesetErrorsTest do
  use ExUnit.Case, async: true

  alias Slipdock.ChangesetErrors

  defp changeset(params) do
    {%{}, %{name: :string, pool: :string}}
    |> Ecto.Changeset.cast(params, [:name, :pool])
  end

  describe "message/2 (#3124)" do
    test "fills each placeholder from the error's opts" do
      message =
        %{name: String.duplicate("n", 9)}
        |> changeset()
        |> Ecto.Changeset.validate_length(:name, max: 5)
        |> ChangesetErrors.message()

      assert message == "name should be at most 5 character(s)"
      refute message =~ "%{"
    end

    test "leaves an opt with no placeholder alone, so a list of atoms doesn't raise" do
      # `validate_inclusion` keeps its enum of atoms in the opts; turning
      # that to text eagerly (as `Tools` did) raises ArgumentError.
      message =
        %{name: String.duplicate("n", 9)}
        |> changeset()
        |> Ecto.Changeset.validate_length(:name, max: 5)
        |> Ecto.Changeset.validate_inclusion(:name, [:a, :b])
        |> ChangesetErrors.message()

      assert message == "name is invalid, should be at most 5 character(s)"
    end

    test "joins the fields with \"; \", each with its messages" do
      parts =
        %{name: "", pool: "toolong"}
        |> changeset()
        |> Ecto.Changeset.validate_required([:name])
        |> Ecto.Changeset.validate_length(:pool, max: 3)
        |> ChangesetErrors.message()
        |> String.split("; ")
        |> Enum.sort()

      assert parts == ["name can't be blank", "pool should be at most 3 character(s)"]
    end

    test "puts the separator between a field and its messages" do
      message =
        %{name: String.duplicate("n", 130)}
        |> changeset()
        |> Ecto.Changeset.validate_length(:name, max: 120)
        |> ChangesetErrors.message(separator: ": ")

      assert message == "name: should be at most 120 character(s)"
    end

    test "fills every placeholder in a message, not just the first" do
      message =
        %{name: "toolong"}
        |> changeset()
        |> Ecto.Changeset.add_error(:name, "between %{min} and %{max}", min: 1, max: 5)
        |> ChangesetErrors.message()

      assert message == "name between 1 and 5"
    end

    test "is empty for a changeset with no errors" do
      assert %{name: "ok"} |> changeset() |> ChangesetErrors.message() == ""
    end
  end

  describe "message/2's options (#3164)" do
    defp two_errors do
      %{name: "", pool: "toolong"}
      |> changeset()
      |> Ecto.Changeset.validate_required([:name])
      |> Ecto.Changeset.validate_length(:pool, max: 3)
    end

    test ":join goes between the fields" do
      assert two_errors() |> ChangesetErrors.message(join: " | ", sort: true) ==
               "name can't be blank | pool should be at most 3 character(s)"
    end

    test ":field names each field" do
      assert two_errors()
             |> ChangesetErrors.message(field: &String.upcase/1, sort: true)
             |> String.starts_with?("NAME can't be blank; POOL ")
    end

    test "a nested changeset's fields read as parent.field, valid children left out" do
      child = fn params ->
        {%{}, %{title: :string}}
        |> Ecto.Changeset.cast(params, [:title])
        |> Ecto.Changeset.validate_required([:title])
      end

      cs =
        %{name: "ok"}
        |> changeset()
        |> Map.update!(:changes, &Map.put(&1, :items, [child.(%{title: "a"}), child.(%{})]))
        |> Map.put(:types, %{
          name: :string,
          pool: :string,
          items: {:embed, %Ecto.Embedded{cardinality: :many, field: :items, related: nil}}
        })
        |> Ecto.Changeset.add_error(:name, "is taken")

      # The map's own order is the atoms' (`name` before `items` here), not
      # the alphabet's; `sort: true` gives the alphabet's.
      assert ChangesetErrors.message(cs) |> String.split("; ") |> Enum.sort() ==
               ["items.title can't be blank", "name is taken"]

      assert ChangesetErrors.message(cs, sort: true) ==
               "items.title can't be blank; name is taken"
    end
  end

  describe "lines/2" do
    test "one line a field, for a page that lists them" do
      lines =
        %{name: "", pool: "toolong"}
        |> changeset()
        |> Ecto.Changeset.validate_required([:name])
        |> Ecto.Changeset.validate_length(:pool, max: 3)
        |> ChangesetErrors.lines(field: &Phoenix.Naming.humanize/1, sort: true)

      assert lines == ["Name can't be blank", "Pool should be at most 3 character(s)"]
    end
  end

  describe "by_field/1" do
    test "each field's messages, filled" do
      errors =
        %{name: String.duplicate("n", 9)}
        |> changeset()
        |> Ecto.Changeset.validate_length(:name, max: 5)
        |> ChangesetErrors.by_field()

      assert errors == %{name: ["should be at most 5 character(s)"]}
    end
  end

  describe "text/1" do
    test "fills the placeholders the message names" do
      assert ChangesetErrors.text({"at most %{count}", count: 10}) == "at most 10"
      assert ChangesetErrors.text({"is %{kind}", kind: :string}) == "is string"
    end

    test "leaves a placeholder with no opt, or a list, as written" do
      assert ChangesetErrors.text({"at most %{count}", []}) == "at most %{count}"
      assert ChangesetErrors.text({"one of %{enum}", enum: [:a, :b]}) == "one of %{enum}"
    end

    test "a message with no placeholder is itself" do
      assert ChangesetErrors.text({"can't be blank", validation: :required}) == "can't be blank"
    end
  end
end
