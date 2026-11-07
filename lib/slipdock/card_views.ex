defmodule Slipdock.CardViews do
  @moduledoc """
  Card views (#2031): what each person sees of a card, on its front and when
  it is opened.

  Card views are personal and stored here, so they follow a person across
  browsers. There are three levels, which cascade from lowest to highest:
  the built-in defaults (`Slipdock.CardViews.Elements`), then **global**,
  then a **board**, then one **list** on it. When an open saved view names a
  card view (`card_view` in its config, by name, since saved views are shared
  and card views aren't), that card view sits above the list while the saved
  view is open. Each level states only the elements it changes: it can apply
  one of the person's named card views and state its own elements on top.

  A board's level also holds its **Show all** switch, which shows every
  element of the card front while it is on, whatever the cascade says.

  Board settings always win. A simple board's hidden facets and a list's own
  settings (no age chip, no front image) are taken off after the cascade, by
  the views that draw the card, so a card view can only hide more. Agents'
  output never follows card views: they are a display preference.

  A scope names a level: `:global`, `{:board, board}` or
  `{:list, board, column}`. `scope/3` builds one and checks that the person
  can read the board.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Column}
  alias Slipdock.CardViews.{CardView, Elements, Level}
  alias Slipdock.{Access, Repo}

  @pubsub Slipdock.PubSub

  defmodule Resolved do
    @moduledoc """
    The card view a person has on one board, before the card's size and the
    board's own settings are applied: `base` is the global and board levels
    merged, `columns` each list's own elements, `top` a saved view's card view.
    """
    defstruct base: %{}, columns: %{}, top: %{}, show_all: false
    @type t :: %__MODULE__{}
  end

  ## Change notices

  @doc "Subscribes to `user`'s card view changes: `{:card_views_changed, user_id}`."
  def subscribe(%User{id: id}), do: Phoenix.PubSub.subscribe(@pubsub, topic(id))
  def subscribe(_), do: :ok

  defp topic(user_id), do: "card_views:#{user_id}"

  defp changed({:ok, _} = result, %User{id: id}) do
    Phoenix.PubSub.broadcast(@pubsub, topic(id), {:card_views_changed, id})
    result
  end

  defp changed(result, _user), do: result

  ## Named card views

  @doc "`user`'s named card views, by name."
  def list(%User{id: id}) do
    Repo.all(from(v in CardView, where: v.user_id == ^id, order_by: [asc: v.name]))
  end

  def list(_), do: []

  @doc """
  One of `user`'s card views by id (an integer, or a string of one) or by
  name. `{:error, :not_found}` when it is nobody's, or somebody else's.
  """
  def get(%User{} = user, ref) when is_integer(ref) do
    case Repo.get_by(CardView, id: ref, user_id: user.id) do
      nil -> {:error, :not_found}
      view -> {:ok, view}
    end
  end

  def get(%User{} = user, ref) when is_binary(ref) do
    ref = String.trim(ref)

    case Integer.parse(ref) do
      {id, ""} ->
        get(user, id)

      _ ->
        case Repo.get_by(CardView, name: ref, user_id: user.id) do
          nil -> {:error, :not_found}
          view -> {:ok, view}
        end
    end
  end

  def get(_user, _ref), do: {:error, :not_found}

  @doc """
  Saves a new named card view. `attrs` has its `name`, and what it states as
  any of: `elements` (a map of element to true, false or nil), `show`, `hide`
  (lists of elements, or comma-joined strings).
  """
  def create(%User{} = user, attrs) do
    with {:ok, elements} <- changes(%{}, attrs) do
      %CardView{user_id: user.id}
      |> CardView.changeset(%{name: attr(attrs, :name), elements: elements})
      |> Repo.insert()
      |> changed(user)
    end
  end

  @doc """
  Changes a named card view: its `name`, and its elements as in `create/2`,
  plus `inherit` (elements it stops stating) and `reset` (start from none).
  """
  def update(%User{} = user, %CardView{user_id: owner} = view, attrs) when owner == user.id do
    with {:ok, elements} <- changes(view.elements, attrs) do
      params = %{elements: elements}
      params = if name = attr(attrs, :name), do: Map.put(params, :name, name), else: params

      view
      |> CardView.changeset(params)
      |> Repo.update()
      |> changed(user)
    end
  end

  def update(_user, _view, _attrs), do: {:error, :not_found}

  @doc "How many of `user`'s levels apply `view`: what deleting it puts back to inheriting."
  def levels_using(%User{id: user_id}, %CardView{id: id}) do
    Repo.aggregate(
      from(l in Level, where: l.user_id == ^user_id and l.card_view_id == ^id),
      :count
    )
  end

  @doc "Deletes a named card view. The levels that applied it keep their own elements."
  def delete(%User{} = user, %CardView{user_id: owner} = view) when owner == user.id do
    view |> Repo.delete() |> changed(user)
  end

  def delete(_user, _view), do: {:error, :not_found}

  ## Levels

  @doc """
  A board with what a level needs of it: its lists and saved views, not its
  cards. Takes a board or an id; nil when there is no such board.
  """
  def with_lists(%Board{} = board), do: Repo.preload(board, [:columns, :saved_views])

  def with_lists(id) when is_integer(id) do
    case Repo.get(Board, id) do
      nil -> nil
      board -> with_lists(board)
    end
  end

  def with_lists(_), do: nil

  @doc """
  The scope for a level: global with no board, a board's with a board, or a
  list's with both. The board must be one `user` can read, and the list on it.
  """
  def scope(_user, nil, nil), do: {:ok, :global}

  def scope(user, %Board{} = board, nil) do
    if readable?(user, board), do: {:ok, {:board, board}}, else: {:error, :not_found}
  end

  def scope(user, %Board{} = board, %Column{board_id: board_id} = column)
      when board_id == board.id do
    if readable?(user, board), do: {:ok, {:list, board, column}}, else: {:error, :not_found}
  end

  def scope(_user, _board, _column), do: {:error, :not_found}

  defp readable?(user, board), do: Access.board_permission(user, board) != :none

  @doc "What `user` states at a level, its named card view preloaded; an empty one if nothing."
  def level(%User{} = user, scope) do
    level_query(user, scope)
    |> Repo.one()
    |> case do
      nil -> new_level(user, scope)
      level -> level
    end
    |> Repo.preload(:card_view)
  end

  defp new_level(user, :global), do: %Level{user_id: user.id}
  defp new_level(user, {:board, b}), do: %Level{user_id: user.id, board_id: b.id}

  defp new_level(user, {:list, b, c}),
    do: %Level{user_id: user.id, board_id: b.id, column_id: c.id}

  defp level_query(user, :global),
    do: from(l in Level, where: l.user_id == ^user.id and is_nil(l.board_id))

  defp level_query(user, {:board, b}),
    do:
      from(l in Level,
        where: l.user_id == ^user.id and l.board_id == ^b.id and is_nil(l.column_id)
      )

  defp level_query(user, {:list, b, c}),
    do:
      from(l in Level,
        where: l.user_id == ^user.id and l.board_id == ^b.id and l.column_id == ^c.id
      )

  @doc """
  Changes what `user` states at a level. `attrs` takes `card_view` (a named
  view's id or name to apply, or nil/"" /"none" to apply none), the element
  changes of `update/3` (`elements`, `show`, `hide`, `inherit`, `reset`), and
  on a board's level `show_all`. A level left stating nothing is removed.
  """
  def update_level(%User{} = user, scope, attrs) do
    level = level(user, scope)

    with {:ok, elements} <- changes(level.elements, attrs),
         {:ok, view_id} <- view_ref(user, level, attrs),
         {:ok, show_all} <- show_all(scope, level, attrs) do
      level
      |> Level.changeset(%{elements: elements, card_view_id: view_id, show_all: show_all})
      |> save_level()
      |> changed(user)
    end
  end

  @doc "Clears a level: it states nothing, and inherits everything."
  def clear_level(%User{} = user, scope) do
    {count, _} = user |> level_query(scope) |> Repo.delete_all()
    changed({:ok, count}, user)
  end

  @doc "Turns a board's Show all switch on or off for `user`."
  def put_show_all(%User{} = user, %Board{} = board, on?) when is_boolean(on?),
    do: update_level(user, {:board, board}, %{"show_all" => on?})

  defp save_level(changeset) do
    level = Ecto.Changeset.apply_changes(changeset)

    cond do
      not changeset.valid? -> {:error, changeset}
      Level.empty?(level) and is_nil(level.id) -> {:ok, level}
      Level.empty?(level) -> delete_level(changeset.data)
      is_nil(level.id) -> Repo.insert(changeset)
      true -> Repo.update(changeset)
    end
    |> case do
      {:ok, level} -> {:ok, Repo.preload(level, :card_view, force: true)}
      error -> error
    end
  end

  # A level left stating nothing: its row goes, and what is returned is the
  # empty level it now is.
  defp delete_level(%Level{} = row) do
    with {:ok, _} <- Repo.delete(row),
         do: {:ok, %Level{user_id: row.user_id, board_id: row.board_id, column_id: row.column_id}}
  end

  defp view_ref(user, level, attrs) do
    case fetch_attr(attrs, :card_view) do
      :error ->
        {:ok, level.card_view_id}

      {:ok, none} when none in [nil, "", "none"] ->
        {:ok, nil}

      {:ok, ref} ->
        case get(user, ref) do
          {:ok, view} -> {:ok, view.id}
          error -> error
        end
    end
  end

  defp show_all(scope, level, attrs) do
    case fetch_attr(attrs, :show_all) do
      :error -> {:ok, level.show_all}
      {:ok, value} -> show_all_value(scope, value)
    end
  end

  defp show_all_value({:board, _}, value) when value in [true, "true", "on", "1"], do: {:ok, true}

  defp show_all_value(_scope, value) when value in [false, "false", "off", "0", nil],
    do: {:ok, false}

  defp show_all_value({:board, _}, _), do: {:error, "show_all must be true or false"}

  defp show_all_value(_scope, _),
    do: {:error, "show_all is a board's switch, not a list's or global"}

  ## The cascade

  @doc """
  The card view `user` has on `board`: their global and board levels, each
  list's, and the card view named by an open saved view (`card_view:`, a
  name), ready for `front_shown/3` and `panel_shown/2`. Nobody signed in has
  the built-in defaults.
  """
  def resolve(user, board, opts \\ [])

  def resolve(%User{} = user, %Board{id: board_id}, opts) do
    levels =
      Repo.all(
        from(l in Level,
          where: l.user_id == ^user.id and (is_nil(l.board_id) or l.board_id == ^board_id),
          preload: :card_view
        )
      )

    global = Enum.find(levels, &is_nil(&1.board_id))
    board_level = Enum.find(levels, &(&1.board_id == board_id and is_nil(&1.column_id)))

    columns =
      for %Level{column_id: id} = level <- levels,
          not is_nil(id),
          into: %{},
          do: {id, stated(level)}

    %Resolved{
      base: Map.merge(stated(global), stated(board_level)),
      columns: columns,
      top: saved_view_elements(user, opts[:card_view]),
      show_all: match?(%Level{show_all: true}, board_level)
    }
  end

  def resolve(_user, _board, _opts), do: %Resolved{}

  defp stated(nil), do: %{}

  defp stated(%Level{card_view: %CardView{elements: view}, elements: own}),
    do: Map.merge(view, own)

  defp stated(%Level{elements: own}), do: own

  defp saved_view_elements(_user, name) when name in [nil, ""], do: %{}

  defp saved_view_elements(user, name) do
    case Repo.get_by(CardView, user_id: user.id, name: name) do
      nil -> %{}
      view -> view.elements
    end
  end

  @doc "Puts a saved view's card view (by name) on top of a resolved view."
  def with_saved_view(%Resolved{} = resolved, user, name),
    do: %{resolved | top: saved_view_elements(user, name)}

  @doc "Every element's value for a card in `column_id` (nil for the board's own), at `density`."
  def elements(%Resolved{} = r, column_id, density \\ "normal") do
    Elements.defaults(density)
    |> Map.merge(r.base)
    |> Map.merge(Map.get(r.columns, column_id, %{}))
    |> Map.merge(r.top)
  end

  @doc """
  The card front's elements shown for a card in `column_id` at `density`, as
  a MapSet. Show all puts every one of them on.
  """
  def front_shown(%Resolved{show_all: true}, _column_id, _density),
    do: MapSet.new(Elements.front_keys())

  def front_shown(%Resolved{} = r, column_id, density) do
    r
    |> elements(column_id, density)
    |> Map.take(Elements.front_keys())
    |> on_keys()
  end

  @doc "The opened card's sections and sidebar groups shown for a card in `column_id`."
  def panel_shown(%Resolved{} = r, column_id) do
    r
    |> elements(column_id)
    |> Map.take(Elements.panel_keys())
    |> on_keys()
  end

  def panel_shown(nil, _column_id), do: MapSet.new(Elements.panel_keys())

  defp on_keys(map), do: for({k, true} <- map, into: MapSet.new(), do: k)

  @doc """
  Each element of the view that applies to a card in `column` (or the board
  itself) on `board` (nil for the global level alone), with where its value comes from: `"default"`,
  `"global"`, `"board"`, `"list"`, `"saved view"`, `"show all"` or
  `"board setting"` (the board hides it whatever a card view says).
  `opts`: `card_view:` a saved view's card view name, `density:`.
  """
  def explain(%User{} = user, board, column \\ nil, opts \\ []) do
    density = opts[:density] || "normal"
    board_level = if board, do: level(user, {:board, board}), else: %Level{}

    layers = [
      {"global", stated(level(user, :global))},
      {"board", stated(board_level)},
      {"list", stated(list_level(user, board, column))},
      {"saved view", saved_view_elements(user, opts[:card_view])}
    ]

    overrides = %{
      hidden: if(board, do: board_hidden(board, column), else: []),
      show_all: board_level.show_all
    }

    for {group, _title, elements} <- Elements.groups(), {key, label} <- elements do
      {value, source} =
        layers
        |> Enum.reduce({Elements.default?(key, density), "default"}, &layer_value(key, &1, &2))
        |> overridden(key, group, overrides)

      %{key: key, label: label, group: group, shown: value, source: source}
    end
  end

  defp list_level(user, %Board{} = board, %Column{} = column),
    do: level(user, {:list, board, column})

  defp list_level(_user, _board, _column), do: %Level{}

  defp layer_value(key, {name, stated}, acc) do
    case Map.fetch(stated, key) do
      {:ok, value} -> {value, name}
      :error -> acc
    end
  end

  # Board settings win over everything; Show all over the cascade, on the front.
  defp overridden(value_source, key, group, %{hidden: hidden, show_all: show_all}) do
    cond do
      Enum.member?(hidden, key) -> {false, "board setting"}
      show_all and group == "front" -> {true, "show all"}
      true -> value_source
    end
  end

  @doc """
  The elements the board itself keeps off a card (in `column`, if given):
  a simple board's technical facets, and a list's own age and image switches.
  """
  def board_hidden(%Board{} = board, column \\ nil),
    do: Board.hidden_facets(board) ++ list_hidden(column)

  @doc "What a list's own settings keep off its cards' fronts: the age chip, the front image."
  def list_hidden(nil), do: []

  def list_hidden(column) do
    if(Map.get(column, :show_age) == false, do: ["age"], else: []) ++
      if Map.get(column, :show_images) == false, do: ["images"], else: []
  end

  ## Element changes

  @doc """
  Applies element changes from `attrs` to `elements`: `reset` (start from
  none), `elements` (a map, nil removing a key), then `show`, `hide` and
  `inherit` (lists, or comma-joined strings). `{:error, message}` names any
  element that isn't one.
  """
  def changes(elements, attrs) do
    start = if truthy?(attr(attrs, :reset)), do: %{}, else: elements || %{}

    with {:ok, map} <- element_map(attr(attrs, :elements)),
         {:ok, show} <- key_list(attr(attrs, :show)),
         {:ok, hide} <- key_list(attr(attrs, :hide)),
         {:ok, inherit} <- key_list(attr(attrs, :inherit)) do
      result =
        Enum.reduce(map, start, fn
          {k, nil}, acc -> Map.delete(acc, k)
          {k, v}, acc -> Map.put(acc, k, v)
        end)

      result = Enum.reduce(show, result, &Map.put(&2, &1, true))
      result = Enum.reduce(hide, result, &Map.put(&2, &1, false))
      {:ok, Map.drop(result, inherit)}
    end
  end

  defp element_map(nil), do: {:ok, %{}}

  defp element_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      key = to_string(k)

      case {Elements.known?(key), element_value(v)} do
        {false, _} -> {:halt, unknown([key])}
        {true, :error} -> {:halt, {:error, "#{key} must be true, false or null"}}
        {true, {:ok, value}} -> {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp element_map(_), do: {:error, "elements must be an object of element: true | false | null"}

  defp element_value(v) when v in [true, "true", "on", "show"], do: {:ok, true}
  defp element_value(v) when v in [false, "false", "off", "hide"], do: {:ok, false}
  defp element_value(v) when v in [nil, "", "inherit"], do: {:ok, nil}
  defp element_value(_), do: :error

  defp key_list(nil), do: {:ok, []}
  defp key_list(value) when is_binary(value), do: key_list(String.split(value, ",", trim: true))

  defp key_list(list) when is_list(list) do
    keys = list |> Enum.map(&(&1 |> to_string() |> String.trim())) |> Enum.reject(&(&1 == ""))

    case Enum.reject(keys, &Elements.known?/1) do
      [] -> {:ok, keys}
      bad -> unknown(bad)
    end
  end

  defp key_list(_), do: {:error, "show, hide and inherit take a list of elements"}

  defp unknown(keys),
    do: {:error, "not an element: #{Enum.join(keys, ", ")} (see the elements list)"}

  defp truthy?(v) when v in [true, "true", "on", "1"], do: true
  defp truthy?(_), do: false

  defp attr(attrs, key) do
    case fetch_attr(attrs, key) do
      {:ok, v} -> v
      :error -> nil
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, v} -> {:ok, v}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp fetch_attr(_attrs, _key), do: :error
end
