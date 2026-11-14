defmodule Slipdock.ChangesetErrors do
  @moduledoc """
  The one way a changeset's errors become words (#3124, #3164).

  Every module that turns a changeset's errors into text for a person (a
  sentence, an API's error map, a test's `errors_on/1`) goes through here, so
  each placeholder (`%{count}`) is filled the same way everywhere. Copies
  written by hand drifted: nine of them printed a literal `%{count}`
  (#2873, #3052, #3124, #3140). The repo check
  `test/slipdock/changeset_errors_rule_test.exs` fails on a new one.
  """

  @doc """
  One error in words, its placeholders filled from its opts:
  `{"should be at most %{count} character(s)", count: 5}` reads
  `should be at most 5 character(s)`.

  A placeholder is filled only when the message names it: an opt with no
  placeholder of its own, such as `validate_inclusion`'s list of atoms, is
  never turned to text, which would raise. A placeholder with no opt, or
  whose opt is not a string, number or atom, is left as written.
  """
  @spec text({String.t(), keyword()}) :: String.t()
  def text({msg, opts}) when is_binary(msg),
    do: Regex.replace(~r/%{(\w+)}/u, msg, &fill(&1, &2, opts))

  # The placeholder `whole`, named `key`, filled from `opts`; left as it is
  # when there is no such opt or it isn't a string, number or atom.
  defp fill(whole, key, opts) do
    case Enum.find(opts, fn {k, _} -> Atom.to_string(k) == key end) do
      {_, value} when is_binary(value) or is_number(value) or is_atom(value) -> to_string(value)
      _ -> whole
    end
  end

  @doc """
  The errors by field, each message filled (`text/1`), nested changesets
  nested as `Ecto.Changeset.traverse_errors/2` gives them:
  `%{name: ["can't be blank"], items: [%{}, %{title: ["can't be blank"]}]}`.
  """
  @spec by_field(Ecto.Changeset.t()) :: map()
  def by_field(%Ecto.Changeset{} = changeset),
    do: Ecto.Changeset.traverse_errors(changeset, &text/1)

  @doc """
  The errors as one line for a person, for a function that answers
  `{:error, String.t()}` rather than the changeset itself: each field's
  messages, joined as `field msg, msg; field msg`. A nested changeset's
  field reads as `parent.field`.

  Options:

    * `:separator` - what goes between a field and its messages, `" "` by
      default (`name should be at most 5 character(s)`); `": "` gives
      `name: should be …`.
    * `:join` - what goes between fields, `"; "` by default.
    * `:field` - a function of the field's name (a string) giving what is
      shown for it, such as `&Phoenix.Naming.humanize/1`.
    * `:sort` - `true` to list the fields in name order. Without it they
      come in the order of `traverse_errors/2`'s map, which is not
      alphabetical: give it where the line is compared or shown in a list.
  """
  @spec message(Ecto.Changeset.t(), keyword()) :: String.t()
  def message(%Ecto.Changeset{} = changeset, opts \\ []),
    do: changeset |> lines(opts) |> Enum.join(Keyword.get(opts, :join, "; "))

  @doc """
  The lines `message/2` joins, one a field (`name can't be blank`), for a
  page that lists them. Takes `message/2`'s options but `:join`.
  """
  @spec lines(Ecto.Changeset.t(), keyword()) :: [String.t()]
  def lines(%Ecto.Changeset{} = changeset, opts \\ []) do
    separator = Keyword.get(opts, :separator, " ")
    name = Keyword.get(opts, :field, & &1)
    fields = changeset |> by_field() |> flatten(nil)
    fields = if opts[:sort], do: Enum.sort_by(fields, &elem(&1, 0)), else: fields

    Enum.map(fields, fn {field, msgs} -> "#{name.(field)}#{separator}#{Enum.join(msgs, ", ")}" end)
  end

  # `{field, [message]}` pairs, a nested changeset's fields under their
  # parent's name; a field holding only nested errors gives its children.
  defp flatten(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {field, value} ->
      field = if prefix, do: "#{prefix}.#{field}", else: to_string(field)
      entries(value, field)
    end)
  end

  defp entries(%{} = nested, field), do: flatten(nested, field)

  defp entries(list, field) when is_list(list) do
    {texts, nested} = Enum.split_with(list, &is_binary/1)
    own = if texts == [], do: [], else: [{field, texts}]
    own ++ Enum.flat_map(nested, &entries(&1, field))
  end
end
