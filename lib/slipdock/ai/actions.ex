defmodule Slipdock.AI.Actions do
  @moduledoc """
  Turns the model's edit proposals (see `Slipdock.AI.Assistant.propose/4`)
  into checked, human-readable steps, and applies them.

  `prepare/2` resolves every reference (card ids, list names, tag names,
  people) against the page the proposal was made for and checks the user
  may make each change; a step that fails carries an `:error` and is never
  run. `apply/1` runs the steps that passed, each against a fresh copy of
  its card, and reports the outcome of each.

  A proposal is a list of maps with a `"type"`:

    * `update` – `card_id` and `changes` (title, description, priority,
      start_date, due_date, completed, percent_complete, assignee, column, add_tags,
      remove_tags, add_flags, remove_flags)
    * `create` – `title` plus any of column, description, priority,
      start_date, due_date, assignee, tags, flags
    * `comment` – `card_id`, `body`
    * `checklist` – `card_id` and `add`, `check`, `uncheck` or `remove` lists
    * `subcards` – `card_id` and `titles` (plus an optional `column` on the
      sub-board); the sub-board is created from the default template if the
      card has none
    * `archive` – `card_id`
    * `archive_page` – `page`, a wiki page's code ("W-31") or its exact
      title. Archiving a page puts the document away and takes it off the
      board; it is the only change this can make to the wiki, because a
      document is written in the wiki's own editor and not dictated here.
  """

  alias Slipdock.{Access, Boards}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Column, Tag}

  @type step :: %{
          label: String.t(),
          error: String.t() | nil,
          run: (-> :ok | {:error, String.t()}) | nil,
          result: :ok | {:error, String.t()} | nil
        }

  @doc """
  Prepares `actions` against a scope: `:cards` (the cards the model was shown
  and may touch), `:board` (where new cards go; nil forbids creating),
  `:user` (whose permissions apply) and `:users` (who can be assigned).
  """
  @spec prepare(list, map) :: [step]
  def prepare(actions, scope) when is_list(actions) do
    scope = Map.put_new(scope, :users, [])
    Enum.flat_map(actions, &prepare_one(&1, scope))
  end

  def prepare(_, _), do: []

  @doc "Runs every prepared step without an error; returns the steps with `:result` set."
  @spec apply([step]) :: [step]
  def apply(steps) do
    Enum.map(steps, fn
      %{error: nil, run: run} = step when is_function(run, 0) ->
        result =
          try do
            run.()
          rescue
            e -> {:error, "failed: #{Exception.message(e)}"}
          end

        %{step | result: result}

      step ->
        %{step | result: {:error, step.error || "skipped"}}
    end)
  end

  @doc "Whether any step can run."
  def runnable?(steps), do: Enum.any?(steps, &is_nil(&1.error))

  ## Update -----------------------------------------------------------------

  defp prepare_one(%{"type" => "update"} = action, scope) do
    with {:ok, card} <- find_card(action["card_id"], scope),
         :ok <- authorize(card, scope) do
      changes = action["changes"] || Map.drop(action, ["type", "card_id"])
      changes = if is_map(changes), do: changes, else: %{}

      Enum.flat_map(changes, &update_step(&1, card, scope))
    else
      {:error, msg} -> [failed("Update card #{action["card_id"]}", msg)]
    end
  end

  defp prepare_one(%{"type" => "create"} = action, %{board: %Board{} = board} = scope) do
    title = to_s(action["title"])

    cond do
      title == "" ->
        [failed("Create a card", "no title given")]

      not Access.can_write?(Access.board_permission(scope[:user], board)) ->
        [failed("Create “#{title}”", "you have read-only access to this board")]

      true ->
        with {:ok, column} <- find_column(action["column"], board),
             {:ok, attrs} <- create_attrs(action, scope) do
          tags = for name <- list(action["tags"]), {:ok, tag} <- [find_tag(name, board)], do: tag

          details =
            [
              attrs["priority"] && "priority #{attrs["priority"]}",
              attrs["start_date"] && "starts #{attrs["start_date"]}",
              attrs["due_date"] && "due #{attrs["due_date"]}",
              attrs["assignee_id"] && "assigned to #{name_of(attrs["assignee_id"], scope)}",
              tags != [] && "tags #{Enum.map_join(tags, ", ", & &1.name)}",
              attrs["flags"] && "flags #{Enum.join(attrs["flags"], ", ")}"
            ]
            |> Enum.filter(&is_binary/1)

          label =
            "Create “#{title}” in #{column.name}" <>
              if(details == [], do: "", else: " (" <> Enum.join(details, ", ") <> ")")

          [
            step(label, fn ->
              with {:ok, card} <- Boards.create_card(column, attrs) do
                if tags != [], do: Boards.set_card_tags(card, tags)
                :ok
              end
              |> normalize_result()
            end)
          ]
        else
          {:error, msg} -> [failed("Create “#{title}”", msg)]
        end
    end
  end

  defp prepare_one(%{"type" => "create"} = action, _scope),
    do: [failed("Create “#{to_s(action["title"])}”", "cards can't be created from this page")]

  defp prepare_one(%{"type" => "comment"} = action, scope) do
    body = to_s(action["body"])

    with {:ok, card} <- find_card(action["card_id"], scope),
         :ok <- authorize(card, scope),
         false <- body == "" do
      [
        step("Comment on “#{card.title}”: #{excerpt(body)}", fn ->
          with {:ok, fresh} <- fresh(card, scope) do
            normalize_result(Boards.add_comment(fresh, body))
          end
        end)
      ]
    else
      true -> [failed("Comment on card #{action["card_id"]}", "the comment is empty")]
      {:error, msg} -> [failed("Comment on card #{action["card_id"]}", msg)]
    end
  end

  defp prepare_one(%{"type" => "checklist"} = action, scope) do
    with {:ok, card} <- find_card(action["card_id"], scope),
         :ok <- authorize(card, scope) do
      items = if is_list(card.checklist_items), do: card.checklist_items, else: []
      add = action["add"] |> list() |> Enum.map(&to_s/1) |> Enum.reject(&(&1 == ""))

      add_steps =
        if add == [],
          do: [],
          else: [
            step(
              "Add #{length(add)} checklist #{plural(length(add), "item")} to “#{card.title}”: #{Enum.join(add, "; ")}",
              fn ->
                with {:ok, fresh} <- fresh(card, scope) do
                  Enum.each(add, &Boards.add_checklist_item(fresh, &1))
                  :ok
                end
              end
            )
          ]

      toggles =
        for {key, done} <- [{"check", true}, {"uncheck", false}],
            text <- list(action[key]) do
          case Enum.find(items, &(String.downcase(&1.text) == String.downcase(to_s(text)))) do
            nil ->
              failed(
                "#{if done, do: "Check", else: "Uncheck"} “#{text}” on “#{card.title}”",
                "no such checklist item"
              )

            %{done: ^done} ->
              failed(
                "#{if done, do: "Check", else: "Uncheck"} “#{text}” on “#{card.title}”",
                "already #{if done, do: "checked", else: "unchecked"}"
              )

            item ->
              step(
                "#{if done, do: "Check", else: "Uncheck"} “#{item.text}” on “#{card.title}”",
                fn ->
                  with {:ok, _} <- fresh(card, scope) do
                    Boards.toggle_checklist_item(item.id)
                    :ok
                  end
                end
              )
          end
        end

      removals =
        for text <- list(action["remove"] || action["delete"]) do
          case Enum.find(items, &(String.downcase(&1.text) == String.downcase(to_s(text)))) do
            nil ->
              failed(
                "Remove “#{text}” from the checklist of “#{card.title}”",
                "no such checklist item"
              )

            item ->
              step("Remove “#{item.text}” from the checklist of “#{card.title}”", fn ->
                with {:ok, _} <- fresh(card, scope) do
                  Boards.delete_checklist_item(item.id)
                  :ok
                end
              end)
          end
        end

      add_steps ++ toggles ++ removals
    else
      {:error, msg} -> [failed("Change the checklist of card #{action["card_id"]}", msg)]
    end
  end

  defp prepare_one(%{"type" => "subcards"} = action, scope) do
    titles = action["titles"] |> list() |> Enum.map(&to_s/1) |> Enum.reject(&(&1 == ""))

    with {:ok, card} <- find_card(action["card_id"], scope),
         :ok <- authorize(card, scope),
         false <- titles == [] do
      column = action["column"] && to_s(action["column"])
      has_sub = match?(%{id: _}, card.sub_board)

      label =
        "Add #{length(titles)} #{plural(length(titles), "subcard")} to “#{card.title}”" <>
          if(has_sub, do: "", else: " (creating its sub-board)") <>
          ": " <> Enum.join(titles, "; ")

      [
        step(label, fn ->
          with {:ok, fresh} <- fresh(card, scope),
               {:ok, sub} <- ensure_sub_board(fresh),
               {:ok, target} <- find_column(column, sub) do
            Enum.reduce_while(titles, :ok, fn title, :ok ->
              case Boards.create_card(target, %{"title" => title}) do
                {:ok, _} -> {:cont, :ok}
                error -> {:halt, normalize_result(error)}
              end
            end)
          end
        end)
      ]
    else
      true -> [failed("Add subcards to card #{action["card_id"]}", "no subcard titles given")]
      {:error, msg} -> [failed("Add subcards to card #{action["card_id"]}", msg)]
    end
  end

  defp prepare_one(%{"type" => "archive"} = action, scope) do
    with {:ok, card} <- find_card(action["card_id"], scope),
         :ok <- authorize(card, scope) do
      [
        step("Archive “#{card.title}”", fn ->
          with {:ok, fresh} <- fresh(card, scope) do
            normalize_result(Boards.archive_card(fresh))
          end
        end)
      ]
    else
      {:error, msg} -> [failed("Archive card #{action["card_id"]}", msg)]
    end
  end

  # A wiki page, which is not a card. The model is shown the board's pages by
  # code and title (see `Slipdock.AI.Context`) and names one of those; nothing
  # here ever falls back to matching card titles, which is how "remove the
  # wiki pages" once became "archive the cards with wiki in the name".
  defp prepare_one(%{"type" => "archive_page"} = action, scope) do
    ref = action["page"] || action["code"] || action["title"]

    with {:ok, page} <- find_page(ref, scope),
         :ok <- authorize_page(page, scope) do
      [
        step("Archive the page “#{page.title}” (#{page.code})", fn ->
          case Slipdock.Wiki.get_page(page.id) do
            nil -> {:error, "the page no longer exists"}
            fresh -> normalize_result(Slipdock.Wiki.archive_page(fresh))
          end
        end)
      ]
    else
      {:error, msg} -> [failed("Archive the page #{inspect(ref)}", msg)]
    end
  end

  defp prepare_one(%{"type" => type}, _scope), do: [failed("#{type}", "unknown action")]
  defp prepare_one(_, _scope), do: [failed("(malformed action)", "no type given")]

  ## Update steps, one per changed thing --------------------------------------

  defp update_step({"title", value}, card, scope) do
    title = to_s(value)

    cond do
      title == "" ->
        [failed("Rename “#{card.title}”", "the new title is empty")]

      title == card.title ->
        []

      true ->
        [field_step(card, scope, "Rename “#{card.title}” to “#{title}”", %{"title" => title})]
    end
  end

  defp update_step({"description", value}, card, scope) do
    text = if is_nil(value), do: nil, else: to_s(value)

    if text == card.description,
      do: [],
      else: [
        field_step(
          card,
          scope,
          if(text in [nil, ""],
            do: "Clear the description of “#{card.title}”",
            else: "Update the description of “#{card.title}”: #{excerpt(text)}"
          ),
          %{"description" => text}
        )
      ]
  end

  defp update_step({"priority", value}, card, scope) do
    p = value |> to_s() |> String.downcase()

    cond do
      p not in Card.priorities() ->
        [failed("Set priority of “#{card.title}”", "“#{value}” isn't a priority")]

      p == card.priority ->
        []

      true ->
        [field_step(card, scope, "Set priority of “#{card.title}” to #{p}", %{"priority" => p})]
    end
  end

  defp update_step({field, value}, card, scope) when field in ["start_date", "due_date"] do
    what = if field == "due_date", do: "due date", else: "start date"

    case parse_date(value) do
      {:ok, nil} ->
        if is_nil(Map.get(card, String.to_existing_atom(field))),
          do: [],
          else: [field_step(card, scope, "Clear the #{what} of “#{card.title}”", %{field => nil})]

      {:ok, date} ->
        if date == Map.get(card, String.to_existing_atom(field)),
          do: [],
          else: [
            field_step(card, scope, "Set the #{what} of “#{card.title}” to #{fmt(date)}", %{
              field => Date.to_iso8601(date)
            })
          ]

      :error ->
        [failed("Set the #{what} of “#{card.title}”", "“#{value}” isn't a date (use YYYY-MM-DD)")]
    end
  end

  defp update_step({"completed", value}, card, scope) do
    done = value in [true, "true", "yes", 1]

    if done == card.completed,
      do: [],
      else: [
        field_step(
          card,
          scope,
          if(done, do: "Mark “#{card.title}” complete", else: "Reopen “#{card.title}”"),
          %{"completed" => done}
        )
      ]
  end

  defp update_step({"percent_complete", value}, card, scope) do
    current = card.percent_complete

    case parse_percent(value) do
      {:ok, ^current} ->
        []

      {:ok, nil} ->
        [
          field_step(card, scope, "Clear % complete on “#{card.title}”", %{
            "percent_complete" => nil
          })
        ]

      {:ok, p} ->
        [
          field_step(card, scope, "Set “#{card.title}” to #{p}% complete", %{
            "percent_complete" => p
          })
        ]

      :error ->
        [
          failed(
            "Set % complete on “#{card.title}”",
            "“#{value}” isn't a whole number from 0 to 100"
          )
        ]
    end
  end

  defp update_step({"assignee", value}, card, scope) do
    if value in [nil, "", "nobody", "none", "unassigned"] do
      if is_nil(card.assignee_id),
        do: [],
        else: [field_step(card, scope, "Unassign “#{card.title}”", %{"assignee_id" => nil})]
    else
      case find_user(value, scope) do
        {:ok, %User{id: id}} when id == card.assignee_id ->
          []

        {:ok, user} ->
          [
            field_step(card, scope, "Assign “#{card.title}” to #{User.display_name(user)}", %{
              "assignee_id" => user.id
            })
          ]

        {:error, msg} ->
          [failed("Assign “#{card.title}”", msg)]
      end
    end
  end

  defp update_step({key, value}, card, scope) when key in ["column", "list"] do
    case find_column(value, %Board{id: card.board_id}) do
      {:ok, %Column{id: id}} when id == card.column_id ->
        []

      {:ok, column} ->
        [
          step("Move “#{card.title}” to #{column.name}", fn ->
            with {:ok, fresh} <- fresh(card, scope) do
              Boards.move_card(fresh.id, column.id, nil)
            end
          end)
        ]

      {:error, msg} ->
        [failed("Move “#{card.title}”", msg)]
    end
  end

  defp update_step({key, names}, card, scope) when key in ["add_tags", "remove_tags"] do
    adding? = key == "add_tags"
    current = if is_list(card.tags), do: card.tags, else: []

    for name <- list(names) do
      case find_tag(name, %{tags: scope_tags(scope, card)}) do
        {:ok, %Tag{} = tag} ->
          has = Enum.any?(current, &(&1.id == tag.id))

          cond do
            adding? and has ->
              nil

            not adding? and not has ->
              nil

            true ->
              step(
                "#{if adding?, do: "Add tag", else: "Remove tag"} “#{tag.name}” #{if adding?, do: "to", else: "from"} “#{card.title}”",
                fn ->
                  with {:ok, fresh} <- fresh(card, scope) do
                    still_has = Enum.any?(fresh.tags, &(&1.id == tag.id))
                    if still_has != adding?, do: Boards.toggle_card_tag(fresh, tag)
                    :ok
                  end
                end
              )
          end

        {:error, msg} ->
          failed("#{if adding?, do: "Add tag", else: "Remove tag"} “#{name}”", msg)
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp update_step({key, flags}, card, scope) when key in ["add_flags", "remove_flags"] do
    adding? = key == "add_flags"
    wanted = flags |> list() |> Enum.map(&(&1 |> to_s() |> String.downcase()))
    {known, unknown} = Enum.split_with(wanted, &(&1 in Card.flags()))

    new_flags =
      if adding?,
        do: Enum.uniq(card.flags ++ known),
        else: Enum.reject(card.flags, &(&1 in known))

    steps =
      if new_flags == card.flags,
        do: [],
        else: [
          field_step(
            card,
            scope,
            "#{if adding?, do: "Flag", else: "Unflag"} “#{card.title}”: #{Enum.join(known, ", ")}",
            %{"flags" => new_flags}
          )
        ]

    steps ++ Enum.map(unknown, &failed("Flag “#{card.title}” as #{&1}", "no such flag"))
  end

  defp update_step({"flags", flags}, card, scope) do
    wanted = flags |> list() |> Enum.map(&(&1 |> to_s() |> String.downcase()))

    if Enum.all?(wanted, &(&1 in Card.flags())) do
      if Enum.sort(wanted) == Enum.sort(card.flags),
        do: [],
        else: [
          field_step(
            card,
            scope,
            "Set flags of “#{card.title}” to #{if wanted == [], do: "none", else: Enum.join(wanted, ", ")}",
            %{
              "flags" => wanted
            }
          )
        ]
    else
      [failed("Set flags of “#{card.title}”", "unknown flag in #{inspect(wanted)}")]
    end
  end

  defp update_step({"tags", names}, card, scope) do
    current = if is_list(card.tags), do: Enum.map(card.tags, & &1.name), else: []
    wanted = names |> list() |> Enum.map(&to_s/1)
    down = &String.downcase/1

    update_step({"add_tags", wanted -- current}, card, scope) ++
      update_step(
        {"remove_tags", Enum.reject(current, &(down.(&1) in Enum.map(wanted, down)))},
        card,
        scope
      )
  end

  defp update_step({"date_precision", value}, card, scope) do
    p = to_s(value)

    cond do
      p not in Slipdock.Dates.precision_keys() ->
        [failed("Set date precision of “#{card.title}”", "unknown precision")]

      p == card.date_precision ->
        []

      true ->
        [field_step(card, scope, "Schedule “#{card.title}” by #{p}", %{"date_precision" => p})]
    end
  end

  defp update_step({key, _}, card, _scope),
    do: [failed("Change #{key} of “#{card.title}”", "unknown field")]

  # A step that sets fields through Boards.update_card on a fresh copy of the card.
  defp field_step(card, scope, label, attrs) do
    step(label, fn ->
      with {:ok, fresh} <- fresh(card, scope) do
        normalize_result(Boards.update_card(fresh, attrs))
      end
    end)
  end

  # The card's sub-board with its columns, created from the default template
  # when the card has none yet.
  defp ensure_sub_board(%Card{sub_board: %{id: id}}), do: {:ok, Boards.get_board!(id)}

  defp ensure_sub_board(%Card{} = card) do
    with {:ok, template} <- default_template(),
         {:ok, board} <- Boards.create_sub_board(card, template) do
      {:ok, Boards.get_board!(board.id)}
    end
  end

  defp default_template do
    case Boards.find_template("Simple") do
      {:ok, template} ->
        {:ok, template}

      _ ->
        case Boards.list_templates() do
          [template | _] -> {:ok, template}
          [] -> {:error, "no template to build the sub-board from"}
        end
    end
  end

  ## Resolution ----------------------------------------------------------------

  defp find_card(id, %{cards: cards}) do
    id = to_int(id)

    case id && Enum.find(cards, &(&1.id == id)) do
      %Card{} = card -> {:ok, card}
      _ -> {:error, "card ##{id || "?"} isn't on this page"}
    end
  end

  defp find_card(_, _), do: {:error, "no cards on this page"}

  # By code or by exact title, among the pages the model was shown — never by
  # a loose match, so a near-miss is a refusal rather than the wrong document.
  defp find_page(ref, %{pages: pages}) when is_list(pages) do
    ref = ref |> to_s() |> String.trim()
    down = String.downcase(ref)

    found =
      Enum.find(pages, &(String.downcase(&1.code) == down)) ||
        Enum.find(pages, &(String.downcase(&1.title) == down))

    case {ref, found} do
      {"", _} -> {:error, "no page was named"}
      {_, nil} -> {:error, "there is no wiki page called “#{ref}” on this board"}
      {_, page} -> {:ok, page}
    end
  end

  defp find_page(_, _), do: {:error, "this page has no wiki to change"}

  defp authorize_page(page, scope) do
    if Access.can_write?(Access.page_permission(scope[:user], page)),
      do: :ok,
      else: {:error, "you have read-only access to “#{page.title}”"}
  end

  # Reloads the card right before a change, checking it still may be edited.
  defp fresh(%Card{id: id}, scope) do
    case Boards.get_card(id) do
      nil -> {:error, "the card no longer exists"}
      %Card{archived_at: at} when not is_nil(at) -> {:error, "the card was archived"}
      card -> with(:ok <- authorize(card, scope), do: {:ok, card})
    end
  end

  defp authorize(card, scope) do
    allowed? =
      case scope[:authorize] do
        fun when is_function(fun, 1) -> fun.(card)
        _ -> Access.can_write?(Access.card_permission(scope[:user], card))
      end

    if allowed?, do: :ok, else: {:error, "you have read-only access to “#{card.title}”"}
  end

  defp find_column(nil, %Board{} = board), do: first_column(board)
  defp find_column("", %Board{} = board), do: first_column(board)

  defp find_column(ref, %Board{} = board) do
    case Boards.find_column(board, to_s(ref)) do
      {:ok, column} -> {:ok, column}
      _ -> {:error, "there is no list called “#{ref}”"}
    end
  end

  defp first_column(%Board{columns: [column | _]}), do: {:ok, column}

  defp first_column(%Board{id: id}) do
    case Boards.get_board!(id).columns do
      [column | _] -> {:ok, column}
      [] -> {:error, "the board has no lists"}
    end
  end

  defp find_tag(name, %{tags: tags}) when is_list(tags) do
    n = name |> to_s() |> String.downcase()

    case Enum.find(tags, &(String.downcase(&1.name) == n)) do
      %Tag{} = tag -> {:ok, tag}
      nil -> {:error, "there is no tag called “#{name}” (tags aren't created by the assistant)"}
    end
  end

  defp find_tag(name, _), do: {:error, "there is no tag called “#{name}”"}

  # The tags the card may carry: the board's when it is on it, else its own root's.
  defp scope_tags(%{board: %Board{id: id, tags: tags}}, %Card{board_id: id}) when is_list(tags),
    do: tags

  defp scope_tags(_scope, %Card{board_id: board_id}),
    do: Boards.list_tags(Boards.root_of_board(board_id))

  defp find_user(ref, scope) do
    r = ref |> to_s() |> String.downcase()
    # Scoped to whoever is asking. The unscoped list would let the model name,
    # and assign cards to, people the asker shares nothing with.
    users =
      if scope[:users] == [],
        do: Slipdock.Access.visible_users(scope[:user]),
        else: scope[:users]

    match =
      Enum.find(users, fn u ->
        String.downcase(u.email) == r or String.downcase(User.display_name(u)) == r
      end) ||
        Enum.find(users, fn u ->
          String.contains?(String.downcase(User.display_name(u)), r) or
            String.starts_with?(String.downcase(u.email), r)
        end)

    if match, do: {:ok, match}, else: {:error, "nobody called “#{ref}” can be assigned"}
  end

  defp name_of(id, scope) do
    case Enum.find(scope[:users] || [], &(&1.id == id)) do
      %User{} = u -> User.display_name(u)
      _ -> "someone"
    end
  end

  defp create_attrs(action, scope) do
    with {:ok, start} <- parse_date(action["start_date"]),
         {:ok, due} <- parse_date(action["due_date"]),
         {:ok, assignee} <- optional_user(action["assignee"], scope) do
      priority = action["priority"] && String.downcase(to_s(action["priority"]))
      flags = action["flags"] |> list() |> Enum.map(&String.downcase(to_s(&1)))

      cond do
        priority && priority not in Card.priorities() ->
          {:error, "“#{priority}” isn't a priority"}

        Enum.any?(flags, &(&1 not in Card.flags())) ->
          {:error, "unknown flag"}

        true ->
          {:ok,
           %{
             "title" => to_s(action["title"]),
             "description" => action["description"] && to_s(action["description"]),
             "priority" => priority,
             "start_date" => start && Date.to_iso8601(start),
             "due_date" => due && Date.to_iso8601(due),
             "assignee_id" => assignee && assignee.id,
             "flags" => if(flags == [], do: nil, else: flags)
           }
           |> Enum.reject(fn {_, v} -> is_nil(v) end)
           |> Map.new()}
      end
    else
      :error -> {:error, "a date isn't in YYYY-MM-DD form"}
      {:error, msg} -> {:error, msg}
    end
  end

  defp optional_user(nil, _), do: {:ok, nil}
  defp optional_user("", _), do: {:ok, nil}
  defp optional_user(ref, scope), do: find_user(ref, scope)

  ## Helpers ----------------------------------------------------------------

  defp step(label, run), do: %{label: label, error: nil, run: run, result: nil}
  defp failed(label, msg), do: %{label: label, error: msg, run: nil, result: nil}

  defp normalize_result({:ok, _}), do: :ok
  defp normalize_result(:ok), do: :ok

  defp normalize_result({:error, %Ecto.Changeset{} = cs}) do
    msg =
      cs.errors
      |> Enum.map(fn {field, {m, _}} -> "#{field} #{m}" end)
      |> Enum.join(", ")

    {:error, "invalid: #{msg}"}
  end

  defp normalize_result({:error, msg}) when is_binary(msg), do: {:error, msg}
  defp normalize_result(other), do: {:error, inspect(other)}

  defp parse_date(nil), do: {:ok, nil}
  defp parse_date(""), do: {:ok, nil}
  defp parse_date("null"), do: {:ok, nil}
  defp parse_date("none"), do: {:ok, nil}
  defp parse_date(%Date{} = d), do: {:ok, d}

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(String.trim(s)) do
      {:ok, d} -> {:ok, d}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(String.trim_leading(s, "#")) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  defp to_s(nil), do: ""
  defp to_s(s) when is_binary(s), do: String.trim(s)
  defp to_s(other), do: to_string(other)

  defp list(nil), do: []
  defp list(l) when is_list(l), do: l

  defp list(s) when is_binary(s),
    do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp list(_), do: []

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp excerpt(text) do
    text = text |> to_s() |> String.replace(~r/\s+/, " ")
    if String.length(text) > 80, do: "“#{String.slice(text, 0, 80)}…”", else: "“#{text}”"
  end

  defp fmt(%Date{} = d), do: Calendar.strftime(d, "%a %-d %b %Y")

  defp parse_percent(nil), do: {:ok, nil}
  defp parse_percent(n) when is_integer(n) and n in 0..100, do: {:ok, n}
  defp parse_percent(n) when is_float(n), do: parse_percent(round(n))

  defp parse_percent(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, rest} when rest in ["", "%"] -> parse_percent(n)
      _ -> :error
    end
  end

  defp parse_percent(_), do: :error
end
