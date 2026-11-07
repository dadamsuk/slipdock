defmodule SlipdockCLI.CardViews do
  @moduledoc false

  # Card views (#2031): which elements of a card the token's owner sees, by
  # global, board and list. Like favourites and hotkeys they are the owner's
  # own; nobody else's view changes, and agents' output never follows them.
  #
  # `card-views` lists the named views (`--elements`: every element a view
  # can set); `card-view show|new|edit|rm` handles one; `card-view
  # level|set|clear` reads, changes or clears a level (no --board: global;
  # --board: the board's; --board and --list: that list's); `card-view
  # applied` says what a card there shows, and why.
  #
  # Each command is planned first (`plan/3`: the request, or a usage error),
  # so what is sent and what is refused can be checked without the halt a
  # refusal ends in.

  import SlipdockCLI.Util

  alias SlipdockCLI.{HTTP, Render}

  @commands ~w(card-views card-view)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  @usage "usage: slipdock card-view show|new|edit|rm|level|set|clear|applied … (see slipdock help)"

  def run(cmd, args, o) do
    case plan(cmd, args, o) do
      {:ok, {sub, request}} -> request |> send_request() |> out(o, &render(sub, &1, o))
      {:error, message} -> fail(message)
    end
  end

  @doc """
  What a command sends: `{:ok, {what, {method, path, body_or_query}}}`, or
  `{:error, message}` for a usage it can't make a request of.
  """
  def plan("card-views", [], _o), do: {:ok, {:list, {:get, "/card-views", []}}}
  def plan("card-views", _args, _o), do: {:error, "usage: slipdock card-views [--elements]"}

  def plan("card-view", ["show", ref], _o), do: {:ok, {:view, {:get, view_path(ref), []}}}

  def plan("card-view", ["new", name | rest], o) do
    {:ok, {:created, {:post, "/card-views", Map.put(elements(o), "name", join([name | rest]))}}}
  end

  def plan("card-view", ["edit", ref], o) do
    body = o |> elements() |> put_if("name", o[:name])

    if body == %{},
      do: {:error, "say what to change: --name N, --show, --hide, --inherit or --reset"},
      else: {:ok, {:view, {:patch, view_path(ref), body}}}
  end

  def plan("card-view", ["rm", ref], _o), do: {:ok, {:deleted, {:delete, view_path(ref), []}}}

  def plan("card-view", ["level"], o) do
    with {:ok, where} <- where(o), do: {:ok, {:level, {:get, "/card-views/level", where}}}
  end

  def plan("card-view", ["set"], o) do
    with {:ok, where} <- where(o),
         {:ok, body} <- level_body(o, where) do
      if map_size(body) == length(where),
        do:
          {:error,
           "say what to change: --apply VIEW|none, --show, --hide, --inherit, --reset or --show-all on|off"},
        else: {:ok, {:level, {:put, "/card-views/level", body}}}
    end
  end

  def plan("card-view", ["clear"], o) do
    with {:ok, where} <- where(o), do: {:ok, {:level, {:delete, "/card-views/level", where}}}
  end

  def plan("card-view", ["applied"], o) do
    with {:ok, where} <- where(o) do
      query = if o[:view], do: where ++ [view: o[:view]], else: where
      {:ok, {:applied, {:get, "/card-views/applied", query}}}
    end
  end

  def plan("card-view", [sub], _o) when sub in ~w(show new edit rm),
    do: {:error, "usage: slipdock card-view #{sub} <view>"}

  def plan("card-view", _args, _o), do: {:error, @usage}

  @doc "Sends a planned request: the API's answer, as `SlipdockCLI.HTTP` gives it."
  def send_request({:get, path, query}), do: HTTP.get(path, query)
  def send_request({:delete, path, query}), do: HTTP.delete(path, query)
  def send_request({:post, path, body}), do: HTTP.post(path, body)
  def send_request({:patch, path, body}), do: HTTP.patch(path, body)
  def send_request({:put, path, body}), do: HTTP.put(path, body)

  defp view_path(ref), do: "/card-views/#{enc(ref)}"

  defp join(words), do: Enum.join(words, " ")

  # The level a command is about: none (global), a board's, or a list's on it.
  defp where(o) do
    board = nonblank(o[:board])
    list = o |> Keyword.get_values(:list) |> List.last() |> nonblank()

    cond do
      list && !board -> {:error, "--list needs --board: a list is named on its board"}
      list -> {:ok, [board: board, list: list]}
      board -> {:ok, [board: board]}
      true -> {:ok, []}
    end
  end

  # The element changes a view or a level takes, as the API's fields.
  defp elements(o) do
    %{}
    |> put_if("show", o[:show])
    |> put_if("hide", o[:hide])
    |> put_if("inherit", o[:inherit])
    |> put_if("reset", if(o[:reset], do: true))
  end

  defp level_body(o, where) do
    body = Map.merge(Map.new(where, fn {k, v} -> {Atom.to_string(k), v} end), elements(o))
    body = put_if(body, "card_view", o[:apply])

    case o[:show_all] do
      nil ->
        {:ok, body}

      value ->
        cond do
          Keyword.has_key?(where, :list) or where == [] ->
            {:error, "--show-all is a board's switch: give --board without --list"}

          Enum.member?(~w(on true yes), value) ->
            {:ok, Map.put(body, "show_all", true)}

          Enum.member?(~w(off false no), value) ->
            {:ok, Map.put(body, "show_all", false)}

          true ->
            {:error, "--show-all takes on or off"}
        end
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  ## Rendering

  @doc false
  def render(:list, %{"card_views" => views, "elements" => catalogue}, o) do
    if views == [],
      do:
        IO.puts(Render.dim("no card views yet — try: slipdock card-view new Focus --hide tags")),
      else:
        Render.table(
          ["ID", "NAME", "SHOWS", "HIDES"],
          Enum.map(views, &[to_string(&1["id"]), &1["name"], states(&1, true), states(&1, false)])
        )

    if o[:elements] && catalogue != [] do
      IO.puts("")
      catalogue(catalogue)
    end
  end

  def render(:view, %{"card_view" => v}, _o), do: view(v)

  def render(:created, %{"card_view" => v}, _o) do
    IO.puts("saved card view #{v["name"]} (#{v["id"]})")
    view(v)
  end

  def render(:deleted, %{"deleted" => v}, _o),
    do: IO.puts("deleted card view #{v["name"]}; the levels that applied it keep their own")

  def render(:level, %{"level" => level}, _o), do: level(level)
  def render(:applied, data, _o), do: applied(data)

  defp view(v) do
    IO.puts("#{v["name"]}  " <> Render.dim("id #{v["id"]}"))
    IO.puts("  shows:  " <> states(v, true))
    IO.puts("  hides:  " <> states(v, false))
  end

  defp level(l) do
    IO.puts(place(l))
    view = l["card_view"]
    IO.puts("  applies: " <> if(view, do: "#{view["name"]} (#{view["id"]})", else: "none"))
    IO.puts("  shows:   " <> states(l, true))
    IO.puts("  hides:   " <> states(l, false))
    if l["level"] == "board", do: IO.puts("  show all: " <> on_off(l["show_all"]))
  end

  defp place(%{"level" => "global"}), do: "global level (every board)"
  defp place(%{"level" => "board", "board" => b}), do: "board level: #{board(b)}"

  defp place(%{"level" => "list", "board" => b, "list" => c}),
    do: "list level: #{c["name"]} on #{board(b)}"

  defp board(b), do: "#{b["name"]} (#{b["code"] || b["id"]})"

  defp applied(data) do
    where =
      case data do
        %{"board" => nil} -> "global level only (give --board for a board's)"
        %{"board" => b, "list" => nil} -> "on #{board(b)}"
        %{"board" => b, "list" => c} -> "in #{c["name"]} on #{board(b)}"
      end

    IO.puts("a card " <> where)
    if data["show_all"], do: IO.puts("  show all is on: every element of the front shows")

    if name = data["saved_view_card_view"],
      do: IO.puts("  the saved view applies card view #{name} on top")

    rows =
      Enum.map(data["elements"] || [], fn e ->
        [e["key"], if(e["shown"], do: "shown", else: "hidden"), e["source"], e["label"]]
      end)

    Render.table(["ELEMENT", "", "FROM", "LABEL"], rows)
  end

  defp catalogue(elements) do
    Render.table(
      ["ELEMENT", "GROUP", "DEFAULT", "LABEL"],
      Enum.map(elements, &[&1["key"], &1["group"], on_off(&1["default"]), &1["label"]])
    )
  end

  defp states(%{"elements" => elements}, want) do
    case for({k, ^want} <- elements || %{}, do: k) |> Enum.sort() do
      [] -> "—"
      keys -> Enum.join(keys, ", ")
    end
  end

  defp on_off(true), do: "on"
  defp on_off(_), do: "off"
end
