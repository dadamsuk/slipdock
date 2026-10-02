defmodule Slipdock.QuickAdd.Capture do
  @moduledoc """
  The header's quick add: one line of plain English in, one card out.

  A line is read twice over. `Slipdock.QuickAdd` always parses it for the
  explicit syntax (`due: friday`, `#high`, `@dan`); when the model is
  configured and the user hasn't turned it off, `Slipdock.QuickAdd.Model`
  also reads it as prose, and what it finds wins. Either way the names it
  comes back with are matched against what the user can actually reach —
  their boards, those boards' lists and tags, the people on the app — so
  nothing invented ever reaches the database.

  Where a card lands when the line doesn't say is the user's own setting
  (`quick_add_board_id` / `quick_add_column_id`, see `Slipdock.Accounts`),
  falling back to the first board they can write to.
  """

  import Ecto.Query

  alias Slipdock.{Access, Boards, QuickAdd, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.QuickAdd.Model

  @max_boards 25
  @max_tags 16

  @type catalogue :: %{
          today: Date.t(),
          boards: [%{board: Board.t(), columns: [Column.t()], tags: list}],
          people: [User.t()],
          default_board: Board.t() | nil,
          default_column: Column.t() | nil
        }

  @doc """
  The boards, lists, tags and people this quick add may choose between, with
  the user's default destination resolved. Everything the line is read
  against comes from here, so an unreachable board simply isn't an option.
  """
  @spec catalogue(User.t(), keyword) :: catalogue
  def catalogue(%User{} = user, opts \\ []) do
    boards =
      user
      |> writable_boards()
      |> Enum.take(@max_boards)
      |> Enum.map(&%{board: &1, columns: columns_of(&1), tags: tags_of(&1)})

    {board, column} = default_destination(user, boards)

    %{
      today: opts[:today] || Date.utc_today(),
      boards: boards,
      people: opts[:people] || Slipdock.Access.visible_users(user),
      default_board: board,
      default_column: column
    }
  end

  @doc "Whether the user has anywhere at all to quick add to."
  def available?(catalogue), do: catalogue.default_column != nil

  @doc """
  Reads `text` and creates the card. Returns `{:ok, capture}` where capture
  is the card with the board and list it landed in, chips describing what
  was understood (the shape `Slipdock.QuickAdd` uses) and any note about what
  had to be ignored — or `{:error, message}`.

  Options: `:today`, `:catalogue` (one already built), `:ai` (force the
  model on or off, otherwise the user's setting decides).
  """
  @spec capture(User.t(), String.t(), keyword) :: {:ok, map} | {:error, String.t()}
  def capture(%User{} = user, text, opts \\ []) do
    text = String.trim(text || "")
    catalogue = opts[:catalogue] || catalogue(user, opts)

    cond do
      text == "" ->
        {:error, "Type what you want to add."}

      catalogue.boards == [] ->
        {:error, "You don't have a board to add to yet."}

      is_nil(catalogue.default_column) ->
        {:error, "Your default board has no lists — pick another in Account settings."}

      true ->
        {plan, notes} = read(user, text, catalogue, opts)
        create(plan, notes, catalogue)
    end
  end

  ## Reading the line ----------------------------------------------------------

  # The plain parser first (it never fails), then the model over the top.
  defp read(user, text, catalogue, opts) do
    fallback = parse_syntax(text, catalogue)

    if use_model?(user, opts) do
      case Model.parse(text, catalogue, [user: user] ++ Keyword.take(opts, [:model])) do
        {:ok, answer} -> {resolve(Map.put(answer, "line", text), catalogue), []}
        {:error, message} -> {fallback, ["Added without the model: #{message}"]}
      end
    else
      {fallback, []}
    end
  end

  defp use_model?(user, opts) do
    case Keyword.fetch(opts, :ai) do
      {:ok, value} -> value and Slipdock.AI.configured?(user)
      :error -> user.quick_add_ai and Slipdock.AI.configured?(user)
    end
  end

  # The explicit syntax, read against the default board (the only one whose
  # lists and tags that syntax knows about).
  defp parse_syntax(text, catalogue) do
    entry = entry_for(catalogue, catalogue.default_board)

    board =
      %{columns: (entry && entry.columns) || [], tags: (entry && entry.tags) || []}

    parsed =
      QuickAdd.parse(text, board,
        today: catalogue.today,
        users: catalogue.people,
        columns: board.columns
      )

    %{
      title: parsed.title,
      board: catalogue.default_board,
      column: parsed.column || catalogue.default_column,
      attrs: parsed.attrs,
      tags: parsed.tags,
      chips: parsed.chips
    }
  end

  # The model answers in names; every one of them is matched back to a row
  # here, and anything that doesn't match is simply dropped.
  defp resolve(answer, catalogue) do
    entry = pick_board(answer["board"], catalogue)
    column = pick_column(answer["column"], entry, catalogue)

    %{attrs: attrs, chips: chips} =
      %{attrs: %{}, chips: []}
      |> put_date("start_date", answer["start"], catalogue.today)
      |> put_date("due_date", answer["due"], catalogue.today)
      |> put_priority(answer["priority"])
      |> put_flags(answer["flags"])
      |> put_assignee(answer["assignee"], catalogue.people, answer["line"])

    tags = pick_tags(answer["tags"], entry)

    %{
      title: String.trim(answer["title"]),
      board: entry.board,
      column: column,
      attrs: attrs,
      tags: tags,
      chips:
        chips ++
          board_chips(entry.board, column, catalogue) ++
          Enum.map(tags, &{:tag, &1.name})
    }
  end

  # The board and list are only worth showing back when they aren't the
  # default — the user knows where their quick adds normally go.
  defp board_chips(board, column, catalogue) do
    cond do
      catalogue.default_board && board.id != catalogue.default_board.id ->
        [{:board, board.name}, {:column, column.name}]

      catalogue.default_column && column.id != catalogue.default_column.id ->
        [{:column, column.name}]

      true ->
        []
    end
  end

  defp pick_board(name, catalogue) do
    find_by_name(catalogue.boards, name, & &1.board.name) ||
      entry_for(catalogue, catalogue.default_board) ||
      List.first(catalogue.boards)
  end

  defp pick_column(name, entry, catalogue) do
    default =
      if catalogue.default_board && entry.board.id == catalogue.default_board.id,
        do: catalogue.default_column

    find_by_name(entry.columns, name, & &1.name) || default || List.first(entry.columns)
  end

  defp pick_tags(nil, _entry), do: []

  defp pick_tags(names, entry) do
    names
    |> Enum.map(&find_by_name(entry.tags, &1, fn tag -> tag.name end))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  # Exact (ignoring case and punctuation) first, then a unique prefix.
  defp find_by_name(_items, name, _fun) when name in [nil, ""], do: nil

  defp find_by_name(items, name, fun) do
    wanted = norm(name)

    Enum.find(items, &(norm(fun.(&1)) == wanted)) ||
      Enum.find(items, &String.starts_with?(norm(fun.(&1)), wanted))
  end

  # The model hands back the phrase, not a date: the arithmetic is done here,
  # by the same parser the typed `due:` syntax uses.
  defp put_date(acc, field, value, today) do
    with text when is_binary(text) <- value,
         {:ok, %Date{} = date} <- QuickAdd.parse_date(strip_preposition(text), today),
         # A misread year can strand a card decades away.
         true <- Date.diff(date, today) |> abs() <= 3650 do
      acc
      |> Map.update!(:attrs, &Map.put(&1, field, Date.to_iso8601(date)))
      |> chip(:date, "#{date_label(field)} #{Calendar.strftime(date, "%a %-d %b")}")
    else
      _ -> acc
    end
  end

  # "by friday", "on the 3rd", "starting next week" — the model is told to
  # leave these off, and sometimes leaves them on anyway.
  defp strip_preposition(text) do
    text
    |> String.trim()
    |> String.replace(~r/^(by|on|at|from|due|starts?|starting|beginning)\s+/i, "")
    |> String.replace(~r/^the\s+/i, "")
    |> String.trim_trailing(".")
  end

  defp date_label("due_date"), do: "Due"
  defp date_label("start_date"), do: "Start"

  defp put_priority(acc, p) when is_binary(p) do
    if p in Card.priorities() and p != "none" do
      acc |> Map.update!(:attrs, &Map.put(&1, "priority", p)) |> chip(:priority, p)
    else
      acc
    end
  end

  defp put_priority(acc, _), do: acc

  defp put_flags(acc, flags) when is_list(flags) do
    case Enum.uniq(Enum.filter(flags, &(&1 in Card.flags()))) do
      [] ->
        acc

      flags ->
        Enum.reduce(
          flags,
          Map.update!(acc, :attrs, &Map.put(&1, "flags", flags)),
          &chip(&2, :flag, &1)
        )
    end
  end

  defp put_flags(acc, _), do: acc

  # Someone is only assigned when the line really named them: "waiting on
  # them" has landed a card on a colleague more than once in testing.
  defp put_assignee(acc, name, people, line) when is_binary(name) do
    with user when not is_nil(user) <- QuickAdd.find_user(name, people),
         true <- named?(user, line) do
      acc
      |> Map.update!(:attrs, &Map.put(&1, "assignee_id", user.id))
      |> chip(:assignee, User.display_name(user))
    else
      _ -> acc
    end
  end

  defp put_assignee(acc, _, _, _), do: acc

  # Any real word of the person's name or email, as typed in the line.
  defp named?(_user, nil), do: false

  defp named?(%User{} = user, line) do
    line = String.downcase(line)

    [user.email, hd(String.split(user.email, "@")), User.display_name(user)]
    |> Enum.flat_map(&String.split(String.downcase(&1), ~r/[\s@._+-]+/, trim: true))
    |> Enum.uniq()
    |> Enum.any?(&(String.length(&1) >= 3 and String.contains?(line, &1)))
  end

  defp chip(acc, kind, text), do: Map.update!(acc, :chips, &(&1 ++ [{kind, text}]))

  ## Writing the card ----------------------------------------------------------

  defp create(%{title: ""}, _notes, _catalogue), do: {:error, "That line has no title in it."}

  defp create(plan, notes, _catalogue) do
    attrs = Map.put(plan.attrs, "title", plan.title)

    case Boards.create_card(plan.column, attrs) do
      {:ok, card} ->
        if plan.tags != [], do: Boards.set_card_tags(card, plan.tags)

        if plan.board.parent_card_id,
          do: Boards.broadcast_tree(Boards.root_of_board(plan.board.id))

        {:ok,
         %{
           card: card,
           board: plan.board,
           column: plan.column,
           chips: plan.chips,
           notes: notes
         }}

      {:error, _changeset} ->
        {:error, "Couldn't add that card."}
    end
  end

  ## The catalogue -------------------------------------------------------------

  defp writable_boards(user) do
    user
    |> Access.list_boards()
    |> Enum.filter(&Access.can_write?(Access.board_permission(user, &1)))
  end

  defp columns_of(%Board{} = board) do
    Repo.all(from(c in Column, where: c.board_id == ^board.id, order_by: [asc: c.position]))
  end

  defp tags_of(%Board{} = board),
    do: board |> Board.root_id() |> Boards.list_tags() |> Enum.take(@max_tags)

  # The user's saved default, checked against what they can still reach, or
  # the first list of the first board they can write to.
  defp default_destination(user, boards) do
    entry = Enum.find(boards, &(&1.board.id == user.quick_add_board_id)) || List.first(boards)

    case entry do
      nil ->
        {nil, nil}

      %{board: board, columns: columns} ->
        column =
          Enum.find(columns, &(&1.id == user.quick_add_column_id)) || List.first(columns)

        {board, column}
    end
  end

  defp entry_for(_catalogue, nil), do: nil
  defp entry_for(catalogue, board), do: Enum.find(catalogue.boards, &(&1.board.id == board.id))

  defp norm(s), do: s |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
end
