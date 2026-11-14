defmodule Slipdock.ChangesetErrors do
  @moduledoc """
  A changeset's errors as one line for a person, for a domain function that
  answers `{:error, String.t()}` rather than the changeset itself.
  """

  @doc """
  Each field's messages, joined as `field msg, msg; field msg`.

  Each placeholder (`%{count}` from `validate_length`) is filled from the
  error's opts, and only when the message names it: an opt with no
  placeholder of its own, such as `validate_inclusion`'s list of atoms, is
  never turned to text, which would raise.

  Options:

    * `:separator` - what goes between a field and its messages, `" "` by
      default (`name should be at most 5 character(s)`); `": "` gives
      `name: should be …`.
  """
  @spec message(Ecto.Changeset.t(), keyword()) :: String.t()
  def message(%Ecto.Changeset{} = changeset, opts \\ []) do
    separator = Keyword.get(opts, :separator, " ")

    changeset
    |> Ecto.Changeset.traverse_errors(&fill/1)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}#{separator}#{Enum.join(msgs, ", ")}" end)
  end

  defp fill({msg, opts}) do
    Enum.reduce(opts, msg, fn {k, v}, acc ->
      String.replace(acc, "%{#{k}}", fn _ -> to_string(v) end)
    end)
  end
end
