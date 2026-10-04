defmodule Slipdock.Importers do
  @moduledoc """
  Boards arriving from somewhere that is not Slipdock.

  Every importer does the same one thing: it reads another tool's export and
  writes a `Slipdock.Portable` document from it. The document then goes through
  `Portable.import/3` like any other, so the rules that matter there — one
  quota check for the whole file, nothing half built, automation rules not
  firing, never merging into a board that is already here — hold for every
  source without each one having to remember them.

  A source is a module implementing the callbacks below and listed in
  `@sources`. That is the whole of adding one: it never touches the database.

  What a source cannot carry is said, not swallowed: `notes` come back as
  sentences and are added to the report's `skipped`, next to the ones
  `Portable` writes itself.
  """

  alias Slipdock.Accounts.User
  alias Slipdock.Portable

  @doc "The short name a person or a request uses to pick this source — `\"trello\"`."
  @callback key() :: String.t()

  @doc "What to call it in a sentence — `\"Trello\"`."
  @callback label() :: String.t()

  @doc "Whether a decoded document looks like this source's export."
  @callback recognises?(map()) :: boolean()

  @doc """
  The document as a `Slipdock.Portable` document, plus a sentence for each thing
  that could not come with it.
  """
  @callback to_portable(map()) :: {:ok, map(), [String.t()]} | {:error, term()}

  @sources [Slipdock.Importers.Trello]

  @doc "Every source this server can read besides its own format."
  def sources, do: @sources

  @doc "The keys a request may name in `from`, Slipdock's own first."
  def keys, do: ["slipdock" | Enum.map(@sources, & &1.key())]

  @doc """
  Why an import was refused, in a sentence for the person who tried it — the
  same words on the account page and in an API response. `nil` for a reason
  that is the server's own business rather than theirs.
  """
  @spec error_message(term()) :: String.t() | nil
  def error_message(:not_json), do: "That is not JSON."

  def error_message(:not_a_slipdock_export),
    do:
      "That is not a Slipdock export — it has no \"slipdock_portable\" version in it — " <>
        "nor a board export from #{Enum.map_join(@sources, " or ", & &1.label())}."

  def error_message({:unknown_source, from}),
    do: "This server can't import from “#{from}”; it reads #{Enum.join(keys(), ", ")}."

  def error_message(:not_a_trello_export),
    do: "That is not a Trello board export — it has no lists and cards in it."

  def error_message({:unsupported_version, version}),
    do:
      "That document is format version #{version}. This server reads version " <>
        "#{Portable.format_version()}, so it was written by a newer Slipdock."

  def error_message({:card_limit_reached, wanted, remaining}),
    do:
      "That document holds #{wanted} cards and pages and you have room for #{remaining}. " <>
        "Nothing was imported — half a board is worse than none."

  def error_message({:board_limit_reached, wanted, remaining}),
    do:
      "That document holds #{wanted} boards and you have room for #{remaining}. " <>
        "Nothing was imported."

  def error_message({:bad_sub_board, ref}),
    do:
      "In that document the sub-board “#{ref}” is the root board or belongs to more " <>
        "than one card, so it would be built inside itself or twice. Nothing was imported."

  def error_message({:too_many, kind, count, max}),
    do:
      "That document holds #{count} #{Portable.row_kind(kind)}; one import takes at most " <>
        "#{max}. Nothing was imported."

  def error_message(:trial_expired),
    do: "Your free trial has ended, so nothing new can be added. Nothing was imported."

  def error_message({:invalid, message}), do: "#{message} Nothing was imported."
  def error_message(_), do: nil

  @doc """
  Imports a document from any source this server reads.

  `from: "trello"` names the source; without it (or with `"auto"`) the document
  is matched against each one in turn, and anything nobody recognises is
  handed to `Portable` — which says it is not a Slipdock export, and that is
  the honest answer for a file nobody here understands.

  The report is `Portable`'s, with `source` saying which reader it went through.
  """
  @spec import(User.t(), map() | binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def import(user, document, opts \\ [])

  def import(%User{} = user, document, opts) when is_binary(document) do
    case Jason.decode(document) do
      {:ok, %{} = decoded} -> import(user, decoded, opts)
      {:ok, _} -> {:error, :not_a_slipdock_export}
      {:error, _} -> {:error, :not_json}
    end
  end

  def import(%User{} = user, %{} = document, opts) do
    {from, opts} = Keyword.pop(opts, :from)

    with {:ok, source} <- source_for(from, document) do
      run(source, user, document, opts)
    end
  end

  defp run(nil, user, document, opts) do
    with {:ok, report} <- Portable.import(user, document, opts) do
      {:ok, Map.put(report, :source, "slipdock")}
    end
  end

  defp run(source, user, document, opts) do
    with {:ok, portable, notes} <- source.to_portable(document),
         {:ok, report} <- Portable.import(user, portable, opts) do
      {:ok,
       report
       |> Map.put(:source, source.key())
       |> Map.update!(:skipped, &Enum.uniq(notes ++ &1))}
    end
  end

  # nil means Slipdock's own format; a module means one of `@sources`.
  defp source_for(from, document) when from in [nil, "", "auto"],
    do: {:ok, Enum.find(@sources, & &1.recognises?(document))}

  defp source_for("slipdock", _document), do: {:ok, nil}

  defp source_for(from, _document) do
    case Enum.find(@sources, &(&1.key() == String.downcase(to_string(from)))) do
      nil -> {:error, {:unknown_source, from}}
      source -> {:ok, source}
    end
  end

  ## Helpers every source wants ---------------------------------------------------

  @doc """
  A list category guessed from its name, so a board that arrives with a list
  called "Done" counts its cards as done here too. Nil when the name says
  nothing — a wrong guess is worse than none.
  """
  def guess_category(name) when is_binary(name) do
    name = name |> String.downcase() |> String.trim()

    cond do
      name =~ ~r/\b(done|complete|completed|finished|shipped|closed)\b/u -> "done"
      name =~ ~r/\b(doing|in progress|wip|working on|in review|review)\b/u -> "doing"
      name =~ ~r/\b(to ?do|to-do|next|up next|ready)\b/u -> "todo"
      true -> nil
    end
  end

  def guess_category(_), do: nil

  @doc "An ISO 8601 date or date-time as `YYYY-MM-DD`, or nil."
  def iso_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime |> DateTime.to_date() |> Date.to_iso8601()

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} -> Date.to_iso8601(date)
          _ -> nil
        end
    end
  end

  def iso_date(_), do: nil
end
