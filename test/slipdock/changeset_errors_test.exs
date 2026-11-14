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
end
