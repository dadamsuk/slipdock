defmodule Slipdock.Blueprint do
  @moduledoc """
  A board blueprint: everything a board starts with beyond its cards — its
  lists, wiki folders, tags, page skeletons and automation rules — as data,
  and the one place that builds a board from it (#959).

  Templates (`Slipdock.Boards.Template`) and Tools (`Slipdock.Tools`, whose
  packages carry a `board.json`) both go through `apply/3`, so a board made
  either way is made the same way. The server builds it, not an agent: the
  structure comes out the same every time, and a list meant to be the ready
  list gets the category that makes it one.

  The shape, as a Tool's `board.json` writes it (every key optional but
  `lists`):

      {
        "lists": [
          {"name": "Found", "role": "ready"},
          {"name": "Doing", "category": "doing", "color": "amber", "wip_limit": 3},
          {"name": "Closed", "role": "done"}
        ],
        "folders": ["Config", "Runs", "Roles/Archive"],
        "tags": ["interim", {"name": "urgent", "color": "red"}],
        "pages": [
          {"title": "Config", "folder": "Config", "body": "# {{board.name}}", "summary": "…",
           "front_matter": "kind: config"}
        ],
        "automations": [
          {"preset": "feed_runner", "params": {"column": "Found", "pool": "default"}}
        ],
        "cards": [
          {"title": "Check the config", "description": "…", "repeat": "every mon"}
        ]
      }

  A list's `role` is what the agent guide reads it as — `ready` (where work
  is taken from), `backlog`, `doing`, `done` or `dropped` — and sets its
  category. `validate/1` checks the server will actually read each list that
  way, since that reading also depends on the other lists' names and order.

  Cards are made once, by title, in the ready list unless `list` names
  another; `repeat` makes one recurring (`Slipdock.Recurrence`).

  Automations are `Slipdock.Automations.Presets` recipes: a preset key and its
  form values, never a hand-written spec, so a blueprint can only ask for what
  the preset gallery offers.

  `apply/3` adds only what the board does not have yet — lists, tags, pages
  and rules by name, folders by path — so applying a blueprint twice changes
  nothing the second time, and applying a newer one adds what is new.
  """

  import Ecto.Query

  alias Slipdock.Automations
  alias Slipdock.Automations.Presets
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Column, Template}
  alias Slipdock.Repo
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Folders, Page}

  @roles %{
    "ready" => "todo",
    "backlog" => "todo",
    "doing" => "doing",
    "done" => "done",
    "dropped" => "dropped"
  }
  @keys ~w(lists folders tags pages automations cards)
  @max_lists 20
  @max_folders 50
  @max_tags 50
  @max_pages 50
  @max_automations 20
  @max_cards 20

  @doc "The roles a list can be given, and the category each one sets."
  def roles, do: @roles

  @doc "An empty blueprint: applying it adds nothing."
  def empty,
    do: %{
      "lists" => [],
      "folders" => [],
      "tags" => [],
      "pages" => [],
      "automations" => [],
      "cards" => []
    }

  ## Reading one ---------------------------------------------------------------

  @doc """
  Checks a blueprint and cleans it up: `{:ok, blueprint}` with string keys and
  every list, tag and page in one shape, or `{:error, message}` naming the
  first thing wrong, in words a person writing a `board.json` can act on.

  `lists: :optional` accepts a blueprint with no lists (a template's extras,
  added to a board that already has its lists).
  """
  def validate(blueprint, opts \\ [])

  def validate(blueprint, opts) when is_map(blueprint) do
    blueprint = Map.new(blueprint, fn {k, v} -> {to_string(k), v} end)

    with :ok <- known_keys(blueprint),
         {:ok, lists} <- lists(blueprint["lists"], opts[:lists]),
         {:ok, folders} <- folders(blueprint["folders"]),
         {:ok, tags} <- tags(blueprint["tags"]),
         {:ok, pages} <- pages(blueprint["pages"], folders),
         {:ok, automations} <- automations(blueprint["automations"], lists),
         {:ok, cards} <- cards(blueprint["cards"]) do
      {:ok,
       %{
         "lists" => lists,
         "folders" => folders,
         "tags" => tags,
         "pages" => pages,
         "automations" => automations,
         "cards" => cards
       }}
    end
  end

  def validate(_, _), do: {:error, "a blueprint is a JSON object"}

  @doc """
  A template as a blueprint: its lists and pages, and the folders, tags and
  automations it carries.
  """
  def from_template(%Template{} = template) do
    %{
      "lists" => Template.normalize_columns(template.columns || []),
      "folders" => template.folders || [],
      "tags" => template.tags || [],
      "pages" => template.pages || [],
      "automations" => template.automations || []
    }
  end

  defp known_keys(blueprint) do
    case Map.keys(blueprint) -- @keys do
      [] -> :ok
      [key | _] -> {:error, "unknown key “#{key}” — a blueprint has #{Enum.join(@keys, ", ")}"}
    end
  end

  # Lists ----------------------------------------------------------------------

  defp lists(nil, :optional), do: {:ok, []}
  defp lists([], :optional), do: {:ok, []}
  defp lists(nil, _), do: {:error, "lists: a board needs at least one list"}
  defp lists([], _), do: {:error, "lists: a board needs at least one list"}

  defp lists(lists, _) when is_list(lists) and length(lists) > @max_lists,
    do: {:error, "lists: at most #{@max_lists}"}

  defp lists(lists, _) when is_list(lists) do
    lists
    |> Enum.with_index(1)
    |> reduce_ok(&list/1)
    |> then(fn
      {:ok, lists} ->
        with :ok <- unique(lists, "name", "lists"), :ok <- roles_hold(lists), do: {:ok, lists}

      error ->
        error
    end)
  end

  defp lists(_, _), do: {:error, "lists: a list of lists"}

  defp list({name, i}) when is_binary(name), do: list({%{"name" => name}, i})

  defp list({%{} = list, i}) do
    list = stringify(list)
    name = list["name"] |> to_string() |> String.trim()
    role = blank(list["role"])
    category = blank(list["category"])

    cond do
      name == "" ->
        {:error, "lists[#{i}]: a list needs a name"}

      String.length(name) > 60 ->
        {:error, "lists[#{i}] “#{name}”: names are at most 60 characters"}

      role && not Map.has_key?(@roles, role) ->
        {:error,
         "lists[#{i}] “#{name}”: role must be one of #{Enum.join(Map.keys(@roles), ", ")}"}

      category && category not in Column.category_keys() ->
        {:error,
         "lists[#{i}] “#{name}”: category must be one of #{Enum.join(Column.category_keys(), ", ")}"}

      role && category && @roles[role] != category ->
        {:error,
         "lists[#{i}] “#{name}”: role #{role} means category #{@roles[role]}, not #{category}"}

      true ->
        [normalised] = Template.normalize_columns([list])

        category =
          category || (role && @roles[role]) ||
            Slipdock.Importers.guess_category(name)

        {:ok,
         normalised |> Map.put("name", name) |> Map.put("category", category) |> put_role(role)}
    end
  end

  defp list({_, i}), do: {:error, "lists[#{i}]: a name, or an object with a name"}

  defp put_role(list, nil), do: list
  defp put_role(list, role), do: Map.put(list, "role", role)

  # The guide reads which list is ready, backlog, doing and done from the
  # categories, the names and the order together (`SlipdockWeb.APIGuide`), so
  # a role is checked against that reading rather than trusted.
  defp roles_hold(lists) do
    columns =
      lists
      |> Enum.with_index(1)
      |> Enum.map(fn {l, i} -> %Column{id: i, name: l["name"], category: l["category"]} end)

    read = SlipdockWeb.APIGuide.list_roles(columns)

    lists
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn {list, i} ->
      role = list["role"]
      key = role && role != "dropped" && String.to_existing_atom(role)

      if key && (read[key] == nil or read[key].id != i) do
        actual = read[key] && read[key].name

        {:error,
         "lists: “#{list["name"]}” is meant to be the #{role} list, but the server would read " <>
           if(actual, do: "“#{actual}” as that", else: "none as that") <>
           " — reorder the lists, or rename the one that takes it"}
      end
    end)
  end

  # Folders --------------------------------------------------------------------

  defp folders(nil), do: {:ok, []}

  defp folders(folders) when is_list(folders) and length(folders) > @max_folders,
    do: {:error, "folders: at most #{@max_folders}"}

  defp folders(folders) when is_list(folders) do
    folders
    |> Enum.with_index(1)
    |> reduce_ok(fn
      {path, i} when is_binary(path) ->
        case path |> String.split("/", trim: true) |> Enum.map(&String.trim/1) do
          [] ->
            {:error, "folders[#{i}]: a folder needs a name"}

          segments ->
            if Enum.any?(segments, &(&1 == "" or String.length(&1) > 120)),
              do: {:error, "folders[#{i}] “#{path}”: each name is 1 to 120 characters"},
              else: {:ok, Enum.join(segments, "/")}
        end

      {_, i} ->
        {:error, "folders[#{i}]: a folder is a name, or a path like Config/Archive"}
    end)
    |> then(fn
      {:ok, paths} -> {:ok, Enum.uniq_by(paths, &String.downcase/1)}
      error -> error
    end)
  end

  defp folders(_), do: {:error, "folders: a list of folder names"}

  # Tags -----------------------------------------------------------------------

  defp tags(nil), do: {:ok, []}

  defp tags(tags) when is_list(tags) and length(tags) > @max_tags,
    do: {:error, "tags: at most #{@max_tags}"}

  defp tags(tags) when is_list(tags) do
    tags
    |> Enum.with_index(1)
    |> reduce_ok(fn
      {name, i} when is_binary(name) ->
        tag(%{"name" => name}, i)

      {%{} = tag, i} ->
        tag(stringify(tag), i)

      {_, i} ->
        {:error, "tags[#{i}]: a name, or an object with a name"}
    end)
    |> then(fn
      {:ok, tags} -> with :ok <- unique(tags, "name", "tags"), do: {:ok, tags}
      error -> error
    end)
  end

  defp tags(_), do: {:error, "tags: a list of tags"}

  defp tag(tag, i) do
    name = tag["name"] |> to_string() |> String.trim()
    color = blank(tag["color"])

    cond do
      name == "" ->
        {:error, "tags[#{i}]: a tag needs a name"}

      String.length(name) > 30 ->
        {:error, "tags[#{i}] “#{name}”: tags are at most 30 characters"}

      color && color not in Slipdock.Palette.names() ->
        {:error, "tags[#{i}] “#{name}”: unknown colour #{color}"}

      true ->
        {:ok, %{"name" => name, "color" => color}}
    end
  end

  # Pages ----------------------------------------------------------------------

  defp pages(nil, _folders), do: {:ok, []}

  defp pages(pages, _folders) when is_list(pages) and length(pages) > @max_pages,
    do: {:error, "pages: at most #{@max_pages}"}

  defp pages(pages, folders) when is_list(pages) do
    known = MapSet.new(folders, &String.downcase/1)

    pages
    |> Enum.with_index(1)
    |> reduce_ok(fn
      {%{} = page, i} ->
        page = stringify(page)
        title = page["title"] |> to_string() |> String.trim()
        folder = blank(page["folder"])

        cond do
          title == "" ->
            {:error, "pages[#{i}]: a page needs a title"}

          not (is_nil(page["body"]) or is_binary(page["body"])) ->
            {:error, "pages[#{i}] “#{title}”: body is text"}

          not front_matter?(page["front_matter"]) ->
            {:error, "pages[#{i}] “#{title}”: front_matter is a string of YAML"}

          folder && not MapSet.member?(known, String.downcase(folder)) ->
            {:error, "pages[#{i}] “#{title}”: folder “#{folder}” is not in folders"}

          true ->
            [clean] = Template.normalize_pages([page])
            {:ok, Map.put(clean, "folder", folder)}
        end

      {_, i} ->
        {:error, "pages[#{i}]: an object with a title"}
    end)
    |> then(fn
      {:ok, pages} -> with :ok <- unique(pages, "title", "pages"), do: {:ok, pages}
      error -> error
    end)
  end

  defp pages(_, _), do: {:error, "pages: a list of pages"}

  # Cards ----------------------------------------------------------------------

  defp cards(nil), do: {:ok, []}

  defp cards(cards) when is_list(cards) and length(cards) > @max_cards,
    do: {:error, "cards: at most #{@max_cards}"}

  defp cards(cards) when is_list(cards) do
    cards
    |> Enum.with_index(1)
    |> reduce_ok(fn
      {%{} = card, i} ->
        card = stringify(card)
        title = card["title"] |> to_string() |> String.trim()

        cond do
          title == "" ->
            {:error, "cards[#{i}]: a card needs a title"}

          Enum.any?(~w(description list repeat), &(not (is_nil(card[&1]) or is_binary(card[&1])))) ->
            {:error, "cards[#{i}] “#{title}”: description, list and repeat are text"}

          (repeat = blank(card["repeat"])) &&
              not match?({:ok, _}, Slipdock.Recurrence.Rule.parse_phrase(repeat)) ->
            {:error,
             "cards[#{i}] “#{title}”: repeat “#{repeat}” is not a rule (try \"every mon\")"}

          true ->
            {:ok,
             %{
               "title" => title,
               "description" => card["description"] || "",
               "list" => blank(card["list"]),
               "repeat" => blank(card["repeat"])
             }}
        end

      {_, i} ->
        {:error, "cards[#{i}]: an object with a title"}
    end)
    |> then(fn
      {:ok, cards} -> with :ok <- unique(cards, "title", "cards"), do: {:ok, cards}
      error -> error
    end)
  end

  defp cards(_), do: {:error, "cards: a list of cards"}

  defp front_matter?(nil), do: true
  defp front_matter?(yaml) when is_binary(yaml), do: Slipdock.Wiki.FrontMatter.valid_yaml?(yaml)
  defp front_matter?(_), do: false

  # Automations ----------------------------------------------------------------

  defp automations(nil, _lists), do: {:ok, []}

  defp automations(rules, _lists) when is_list(rules) and length(rules) > @max_automations,
    do: {:error, "automations: at most #{@max_automations}"}

  defp automations(rules, lists) when is_list(rules) do
    names = MapSet.new(lists, &String.downcase(&1["name"]))

    rules
    |> Enum.with_index(1)
    |> reduce_ok(fn
      {%{} = rule, i} ->
        rule = stringify(rule)
        key = to_string(rule["preset"] || "")
        params = rule["params"] || %{}

        with {:ok, preset} <- preset(key, i),
             :ok <- params_map(params, i),
             :ok <- lists_known(preset, stringify(params), names, i),
             {:ok, _attrs} <- recipe_builds(key, params, i) do
          {:ok, %{"preset" => key, "params" => stringify(params), "name" => blank(rule["name"])}}
        end

      {_, i} ->
        {:error, "automations[#{i}]: an object with a preset"}
    end)
  end

  defp automations(_, _), do: {:error, "automations: a list of preset recipes"}

  defp preset(key, i) do
    case Presets.get(key) do
      nil ->
        {:error,
         "automations[#{i}]: unknown preset “#{key}” — one of #{Enum.join(Presets.keys(), ", ")}"}

      preset ->
        {:ok, preset}
    end
  end

  defp params_map(params, _i) when is_map(params), do: :ok
  defp params_map(_, i), do: {:error, "automations[#{i}]: params is an object"}

  # A rule that names a list the blueprint does not make would never fire.
  # With no lists in the blueprint (a template's extras), the board's own are
  # checked when it is applied.
  defp lists_known(preset, params, names, i) do
    missing =
      for %{type: "column", name: field} <- preset.fields,
          value = blank(params[field]),
          MapSet.size(names) > 0,
          not MapSet.member?(names, String.downcase(value)),
          do: value

    case missing do
      [] -> :ok
      [list | _] -> {:error, "automations[#{i}] #{preset.key}: no list called “#{list}”"}
    end
  end

  defp recipe_builds(key, params, i) do
    case Presets.build(key, params) do
      {:ok, attrs} -> {:ok, attrs}
      {:error, message} -> {:error, "automations[#{i}] #{key}: #{message}"}
    end
  end

  ## Building a board from one --------------------------------------------------

  @doc """
  Adds what `blueprint` describes to `board`, leaving alone anything already
  there: a list, tag or rule of the same name, a folder at the same path, a
  page with the same title. Returns `{:ok, report}` where the report says
  what was `added` and what was `skipped`, each a map of `lists`, `folders`,
  `tags`, `pages` and `automations` to names; or `{:error, message}` when the
  blueprint does not validate or a part of it is refused.

  Options: `:user` (who is building — recorded on pages and rules),
  `:message` (each new page's first revision note), `:refresh_pages` (a map
  of page title to the skeleton an earlier version made it from: a page whose
  body is still exactly that skeleton has not been edited, and is replaced
  with the new one — see `Slipdock.Tools` upgrades). An edited page is never
  touched.

  Page bodies may use `{{board.name}}` and `{{today}}`.
  """
  def apply(%Board{} = board, blueprint, opts \\ []) do
    with {:ok, blueprint} <- validate(blueprint, lists: :optional) do
      Repo.transaction(fn ->
        report = %{added: empty_report(), skipped: empty_report()}

        with {:ok, report} <- apply_lists(board, blueprint["lists"], report),
             {:ok, report, folders} <- apply_folders(board, blueprint["folders"], report),
             {:ok, report} <- apply_tags(board, blueprint["tags"], report),
             {:ok, report} <- apply_pages(board, blueprint["pages"], folders, report, opts),
             {:ok, report} <- apply_automations(board, blueprint["automations"], report, opts),
             {:ok, report} <- apply_cards(board, blueprint["cards"], report, opts) do
          report
        else
          {:error, message} -> Repo.rollback(message)
        end
      end)
    end
  end

  defp empty_report, do: Map.new(@keys, &{&1, []})

  defp note(report, outcome, part, name),
    do: update_in(report, [outcome, part], &(&1 ++ [name]))

  defp apply_lists(board, lists, report) do
    existing = board.id |> columns() |> MapSet.new(&String.downcase(&1.name))

    reduce_ok(lists, report, fn list, report ->
      if MapSet.member?(existing, String.downcase(list["name"])) do
        {:ok, note(report, :skipped, "lists", list["name"])}
      else
        attrs = Map.take(list, ~w(name category color wip_limit))

        case Boards.create_column(board, attrs) do
          {:ok, _} -> {:ok, note(report, :added, "lists", list["name"])}
          {:error, cs} -> {:error, "list “#{list["name"]}”: #{errors(cs)}"}
        end
      end
    end)
  end

  defp columns(board_id),
    do: Repo.all(from(c in Column, where: c.board_id == ^board_id, order_by: c.position))

  # Folders come back as a map of lowercased path to folder, for the pages.
  defp apply_folders(board, paths, report) do
    Enum.reduce_while(paths, {:ok, report, %{}}, fn path, {:ok, report, made} ->
      case Folders.find(board, "/" <> path) do
        {:ok, folder} ->
          {:cont,
           {:ok, note(report, :skipped, "folders", path),
            Map.put(made, String.downcase(path), folder)}}

        _ ->
          case Folders.create(board, %{"name" => path}) do
            {:ok, folder} ->
              {:cont,
               {:ok, note(report, :added, "folders", path),
                Map.put(made, String.downcase(path), folder)}}

            {:error, cs} ->
              {:halt, {:error, "folder “#{path}”: #{errors(cs)}"}}
          end
      end
    end)
  end

  defp apply_tags(board, tags, report) do
    existing =
      board |> Board.root_id() |> Boards.list_tags() |> MapSet.new(&String.downcase(&1.name))

    reduce_ok(tags, report, fn tag, report ->
      if MapSet.member?(existing, String.downcase(tag["name"])) do
        {:ok, note(report, :skipped, "tags", tag["name"])}
      else
        attrs = %{"name" => tag["name"], "color" => tag["color"]} |> reject_nil()

        case Boards.create_tag(board, attrs) do
          {:ok, _} -> {:ok, note(report, :added, "tags", tag["name"])}
          {:error, cs} -> {:error, "tag “#{tag["name"]}”: #{errors(cs)}"}
        end
      end
    end)
  end

  defp apply_pages(board, pages, folders, report, opts) do
    user = opts[:user]
    refresh = opts[:refresh_pages] || %{}

    reduce_ok(pages, report, fn page, report ->
      folder = page["folder"] && folders[String.downcase(page["folder"])]
      rendered = Wiki.render_skeleton(board, page)

      case existing_page(board, rendered["title"]) do
        nil ->
          attrs =
            rendered
            |> Map.put("template", page["template"])
            |> then(&if(folder, do: Map.put(&1, "folder_id", folder.id), else: &1))
            |> put_front_matter(page["front_matter"])

          case Wiki.create_page(board, attrs, user: user, via: "web", message: opts[:message]) do
            {:ok, _} -> {:ok, note(report, :added, "pages", page["title"])}
            {:error, cs} -> {:error, "page “#{page["title"]}”: #{errors(cs)}"}
          end

        %Page{} = existing ->
          old = refresh[page["title"]]

          if old != nil and untouched?(board, existing, old) and existing.body != rendered["body"] do
            case Wiki.update_page(existing, Map.take(rendered, ~w(body summary)),
                   user: user,
                   via: "web",
                   message: opts[:message]
                 ) do
              {:ok, _} -> {:ok, note(report, :added, "pages", page["title"] <> " (updated)")}
              {:error, cs} -> {:error, "page “#{page["title"]}”: #{errors(cs)}"}
            end
          else
            {:ok, note(report, :skipped, "pages", page["title"])}
          end
      end
    end)
  end

  defp put_front_matter(attrs, yaml) when is_binary(yaml) and yaml != "",
    do: Map.put(attrs, "front_matter", Slipdock.Wiki.FrontMatter.with_yaml(nil, yaml))

  defp put_front_matter(attrs, _yaml), do: attrs

  # A card is made once: one of the same title already on the board, open,
  # done or archived, means it was made before, so applying again (or after
  # somebody finished the card) never makes a second.
  defp apply_cards(board, cards, report, opts) do
    existing =
      from(c in Slipdock.Boards.Card, where: c.board_id == ^board.id, select: c.title)
      |> Repo.all()
      |> MapSet.new(&String.downcase/1)

    columns = columns(board.id)

    reduce_ok(cards, report, fn card, report ->
      with false <- MapSet.member?(existing, String.downcase(card["title"])),
           {:ok, column} <- card_column(columns, card["list"]),
           {:ok, made} <-
             Boards.create_card(
               column,
               %{"title" => card["title"], "description" => card["description"]},
               by: opts[:user]
             ),
           :ok <- repeat(made, card["repeat"], opts[:user]) do
        {:ok, note(report, :added, "cards", card["title"])}
      else
        true -> {:ok, note(report, :skipped, "cards", card["title"])}
        {:error, %Ecto.Changeset{} = cs} -> {:error, "card “#{card["title"]}”: #{errors(cs)}"}
        {:error, message} -> {:error, "card “#{card["title"]}”: #{message}"}
      end
    end)
  end

  defp card_column(columns, nil) do
    case Slipdock.Flow.ready_list(columns) || List.first(columns) do
      nil -> {:error, "the board has no lists"}
      column -> {:ok, column}
    end
  end

  defp card_column(columns, name) do
    case Enum.find(columns, &(String.downcase(&1.name) == String.downcase(name))) do
      nil -> {:error, "there is no list “#{name}”"}
      column -> {:ok, column}
    end
  end

  defp repeat(_card, nil, _user), do: :ok
  defp repeat(_card, _rule, nil), do: {:error, "a repeating card needs somebody to make it"}

  defp repeat(card, rule, user) do
    case Slipdock.Recurrence.set(card, %{"rule" => rule}, user) do
      {:ok, _series} -> :ok
      {:error, %Ecto.Changeset{} = cs} -> {:error, errors(cs)}
      {:error, message} when is_binary(message) -> {:error, message}
      other -> {:error, inspect(other)}
    end
  end

  defp existing_page(board, title) do
    Repo.one(
      from(p in Page,
        where:
          p.board_id == ^board.id and fragment("lower(?)", p.title) == ^String.downcase(title),
        order_by: [asc: p.id],
        limit: 1
      )
    )
  end

  # Nobody has edited a page whose body is still the skeleton it was made
  # from. (A skeleton using {{today}} renders differently on another day, so
  # such a page reads as edited and is left alone: the safe way to be wrong.)
  defp untouched?(board, %Page{body: body}, old),
    do: (body || "") == (Wiki.render_skeleton(board, old)["body"] || "")

  defp apply_automations(board, rules, report, opts) do
    existing = board.id |> Automations.list_rules() |> MapSet.new(&String.downcase(&1.name))
    lists = board.id |> columns() |> MapSet.new(&String.downcase(&1.name))

    reduce_ok(rules, report, fn rule, report ->
      with {:ok, attrs} <- built(rule, opts[:user]),
           :ok <- board_lists_known(rule, lists) do
        if MapSet.member?(existing, String.downcase(attrs["name"])) do
          {:ok, note(report, :skipped, "automations", attrs["name"])}
        else
          case Automations.create_rule(Map.put(attrs, "board_id", board.id),
                 created_by: opts[:user]
               ) do
            {:ok, rule} -> {:ok, note(report, :added, "automations", rule.name)}
            {:error, cs} -> {:error, "automation “#{attrs["name"]}”: #{errors(cs)}"}
          end
        end
      end
    end)
  end

  defp built(rule, user) do
    case Presets.build(rule["preset"], rule["params"], user: user) do
      {:ok, attrs} ->
        {:ok, if(rule["name"], do: Map.put(attrs, "name", rule["name"]), else: attrs)}

      {:error, message} ->
        {:error, "automation #{rule["preset"]}: #{message}"}
    end
  end

  defp board_lists_known(rule, lists) do
    preset = Presets.get(rule["preset"])

    missing =
      for %{type: "column", name: field} <- preset.fields,
          value = blank(rule["params"][field]),
          not MapSet.member?(lists, String.downcase(value)),
          do: value

    case missing do
      [] ->
        :ok

      [list | _] ->
        {:error, "automation #{rule["preset"]}: the board has no list called “#{list}”"}
    end
  end

  ## Helpers --------------------------------------------------------------------

  defp reduce_ok(items, fun) do
    items
    |> reduce_ok([], fn item, acc ->
      with {:ok, value} <- fun.(item), do: {:ok, [value | acc]}
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp reduce_ok(items, acc, fun) do
    Enum.reduce_while(items, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp unique(items, key, what) do
    items
    |> Enum.map(&String.downcase(&1[key]))
    |> Enum.frequencies()
    |> Enum.find(fn {_, n} -> n > 1 end)
    |> case do
      nil ->
        :ok

      {name, _} ->
        original = Enum.find(items, &(String.downcase(&1[key]) == name))[key]
        {:error, "#{what}: “#{original}” appears twice"}
    end
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp blank(nil), do: nil

  defp blank(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank(value), do: to_string(value)

  defp reject_nil(map), do: Map.reject(map, fn {_, v} -> is_nil(v) end)

  defp errors(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp errors(other) when is_binary(other), do: other
  defp errors(other), do: inspect(other)
end
