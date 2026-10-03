defmodule Slipdock.Automations.Runner do
  @moduledoc """
  Decides whether a rule applies to what just happened, and carries out its
  actions.

  `matches?/2` compares an event against a rule's trigger and conditions;
  `run/3` performs the actions, one at a time, collecting `{:ok, label}` or
  `{:error, reason}` for each so the rule can report on itself. Anything a
  rule can't resolve — a list that has been renamed, a person who has left —
  fails that action alone and leaves the rest of the rule running.

  Text in an action (a subject, a comment, an alert body) goes through
  `render/2` first, so rules can write `{{card.title}}`, `{{card.url}}`,
  `{{card.due_date}}`, `{{board.name}}` and the rest of the vocabulary in
  `variables/1`.
  """

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Automations.{Notifier, Spec}
  alias Slipdock.Boards.{Card, Column, Tag}
  alias Slipdock.Wiki.Page

  @doc """
  Whether `rule` should act on `event`. The event is a map with a `:type`
  and whatever that type carries (`:card`, `:from`, `:to`, `:field`, …).
  """
  def matches?(rule, event) do
    trigger_matches?(rule.spec["trigger"], event) and
      conditions_match?(Spec.conditions(rule.spec), event[:card])
  end

  ## Triggers -----------------------------------------------------------------

  defp trigger_matches?(%{"type" => type} = trigger, %{type: type} = event) do
    case type do
      "card_created" ->
        same_column?(trigger["column"], event[:column])

      "card_moved" ->
        same_column?(trigger["from"], event[:from]) and same_column?(trigger["to"], event[:to])

      "card_updated" ->
        field_changed?(trigger["field"], event)

      "card_assigned" ->
        is_nil(trigger["assignee"]) or person?(trigger["assignee"], event[:assignee])

      "tag_added" ->
        named?(trigger["tag"], event[:tag])

      "flag_added" ->
        named?(trigger["flag"], event[:flag])

      _ ->
        true
    end
  end

  defp trigger_matches?(_, _), do: false

  defp same_column?(nil, _), do: true
  defp same_column?(_, nil), do: false
  defp same_column?(name, %Column{name: column_name}), do: casefold(name) == casefold(column_name)
  defp same_column?(name, other), do: named?(name, other)

  defp named?(nil, _), do: true
  defp named?(_, nil), do: false
  defp named?(wanted, actual), do: casefold(wanted) == casefold(actual)

  defp person?(nil, _), do: true
  defp person?(_, nil), do: false

  defp person?(wanted, %User{} = user) do
    wanted = casefold(wanted)
    wanted in [casefold(user.email), casefold(user.name), casefold(User.display_name(user))]
  end

  defp person?(_, _), do: false

  # "any field" when the trigger doesn't name one; the event carries the list
  # of fields that actually changed.
  defp field_changed?(nil, _event), do: true

  defp field_changed?(field, event) do
    changed = Enum.map(event[:fields] || [], &to_string/1)
    to_string(field) in changed
  end

  ## Conditions ---------------------------------------------------------------

  @doc """
  Whether every condition holds for `card`.

  A wiki page placed on a board is card-shaped and stands beside the cards in
  every view, so it is tested the same way — which is what lets a document's
  own live query carry a `filter:` on a board that has pages on it (see
  `Slipdock.Wiki.Query`). Anything else matches nothing rather than raising: a
  condition that cannot be read is a condition that does not hold.
  """
  def conditions_match?([], _card), do: true
  def conditions_match?(_conditions, nil), do: false
  def conditions_match?(conditions, %Card{} = card), do: all_match?(conditions, card)
  def conditions_match?(conditions, %Page{} = page), do: all_match?(conditions, page)
  def conditions_match?(_conditions, _other), do: false

  defp all_match?(conditions, subject) do
    subject = decorate(subject)
    Enum.all?(conditions, &condition_match?(&1, subject))
  end

  defp condition_match?(%{"field" => field, "op" => op, "value" => value}, card) do
    test(op, field_value(field, card), value)
  end

  defp condition_match?(_, _), do: false

  defp field_value("column", card), do: card.column && card.column.name
  defp field_value("priority", card), do: card.priority
  defp field_value("tag", card), do: Enum.map(card.tags, & &1.name)
  defp field_value("assignee", card), do: card.assignee && User.display_name(card.assignee)
  defp field_value("flag", card), do: card.flags
  defp field_value("title", card), do: card.title
  defp field_value("description", card), do: card.description
  defp field_value("completed", card), do: card.completed
  defp field_value("archived", card), do: not is_nil(card.archived_at)
  defp field_value("blocked", card), do: Card.blocked?(card)
  defp field_value("has_due_date", card), do: not is_nil(card.due_date)
  defp field_value("has_assignee", card), do: not is_nil(card.assignee_id)
  defp field_value("due_date", card), do: card.due_date
  defp field_value("start_date", card), do: card.start_date
  defp field_value("percent_complete", card), do: card.percent_complete
  defp field_value("health", card), do: Card.stated_health(card)
  defp field_value("age_days", card), do: days_since(card.inserted_at)
  # Whether anything in the wiki talks about this card. "When a card lands in
  # Ready and has no spec, alert me" is the rule everyone writes first.
  # A page *is* the document, so it answers the question it was written for.
  defp field_value("has_doc", %Page{}), do: true
  defp field_value("has_doc", card), do: Slipdock.Wiki.pages_for_card(card) != []
  defp field_value(_, _), do: nil

  defp test("is_set", actual, _), do: present?(actual)
  defp test("is_not_set", actual, _), do: not present?(actual)
  defp test(_op, nil, _value), do: false

  defp test("is", actual, value) when is_list(actual), do: any_match?(actual, [value])
  defp test("is", actual, value), do: equal?(actual, value)
  defp test("is_not", actual, value), do: not test("is", actual, value)

  defp test("any_of", actual, value) when is_list(actual),
    do: any_match?(actual, List.wrap(value))

  defp test("any_of", actual, value),
    do: Enum.any?(List.wrap(value), &equal?(actual, &1))

  defp test("none_of", actual, value), do: not test("any_of", actual, value)
  defp test("contains", actual, value), do: casefold(actual) =~ casefold(value)
  defp test("not_contains", actual, value), do: not test("contains", actual, value)
  defp test("before", %Date{} = actual, value), do: compare_date(actual, value) == :lt
  defp test("after", %Date{} = actual, value), do: compare_date(actual, value) == :gt

  defp test("within_days", %Date{} = actual, value) when is_integer(value) do
    diff = Date.diff(actual, Date.utc_today())
    diff >= 0 and diff <= value
  end

  defp test("older_than_days", %Date{} = actual, value) when is_integer(value),
    do: Date.diff(Date.utc_today(), actual) > value

  defp test("older_than_days", actual, value) when is_number(actual) and is_integer(value),
    do: actual > value

  defp test("gt", actual, value) when is_number(actual), do: actual > to_number(value)
  defp test("lt", actual, value) when is_number(actual), do: actual < to_number(value)
  defp test(_, _, _), do: false

  defp any_match?(actuals, values) do
    wanted = Enum.map(values, &casefold/1)
    Enum.any?(actuals, &(casefold(&1) in wanted))
  end

  defp equal?(actual, value) when is_boolean(actual), do: actual == truthy(value)
  defp equal?(%Date{} = actual, value), do: compare_date(actual, value) == :eq
  defp equal?(actual, value), do: casefold(actual) == casefold(value)

  defp compare_date(%Date{} = date, value) do
    case parse_date(value) do
      %Date{} = other -> Date.compare(date, other)
      nil -> :error
    end
  end

  defp parse_date("today"), do: Date.utc_today()
  defp parse_date("tomorrow"), do: Date.add(Date.utc_today(), 1)
  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?([]), do: false
  defp present?(false), do: false
  defp present?(_), do: true

  defp truthy(true), do: true
  defp truthy(value) when is_binary(value), do: casefold(value) in ~w(true yes 1)
  defp truthy(_), do: false

  defp to_number(value) when is_number(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_number(_), do: 0

  defp casefold(nil), do: ""
  defp casefold(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp casefold(value), do: value |> to_string() |> String.downcase()

  defp days_since(%DateTime{} = at), do: DateTime.diff(DateTime.utc_now(), at, :day)
  defp days_since(_), do: 0

  ## Running ------------------------------------------------------------------

  @doc """
  Carries out the rule's actions for `event`. Returns a list of
  `{:ok, label}` / `{:error, reason}`, one per action, in order.
  """
  def run(rule, event, opts \\ []) do
    card = event[:card] && decorate(event[:card])
    board = Slipdock.Boards.Board |> Repo.get!(rule.board_id) |> Repo.preload(:columns)
    bindings = variables(event |> Map.merge(%{card: card, board: board, rule: rule}))

    context = %{
      rule: rule,
      board: board,
      card: card,
      event: event,
      bindings: bindings,
      opts: opts
    }

    rule.spec
    |> Spec.actions()
    |> Enum.map(&perform(&1, context))
  end

  defp perform(%{"type" => type} = action, context) do
    try do
      do_perform(type, action, context)
    rescue
      e -> {:error, "#{type}: #{Exception.message(e)}"}
    end
  end

  defp do_perform("email", action, ctx) do
    to = action["to"] |> List.wrap() |> Enum.map(&to_string/1)
    subject = text(action["subject"], ctx, default_subject(ctx))
    body = text(action["body"], ctx, default_body(ctx))

    case Notifier.deliver(to, subject, body) do
      :ok -> {:ok, "emailed #{Enum.join(to, ", ")}"}
      {:error, reason} -> {:error, "email failed: #{reason}"}
    end
  end

  defp do_perform("notify_assignee", action, ctx) do
    case ctx.card && ctx.card.assignee do
      nil ->
        {:error, "nobody is assigned"}

      %User{email: email} ->
        subject = text(action["subject"], ctx, default_subject(ctx))
        body = text(action["body"], ctx, default_body(ctx))

        case Notifier.deliver([email], subject, body) do
          :ok -> {:ok, "emailed #{email}"}
          {:error, reason} -> {:error, "email failed: #{reason}"}
        end
    end
  end

  defp do_perform("alert", action, ctx) do
    attrs = %{
      "title" => text(action["title"], ctx, "Alert"),
      "body" => text(action["body"], ctx, nil),
      "severity" => action["severity"] || "info",
      "board_id" => board_id(ctx),
      "card_id" => ctx.card && ctx.card.id,
      "rule_id" => ctx.rule.id
    }

    case Slipdock.Automations.raise_alert(attrs) do
      {:ok, alert} -> {:ok, "alerted: #{alert.title}"}
      {:error, changeset} -> {:error, "alert failed: #{errors(changeset)}"}
    end
  end

  defp do_perform("move_card", action, ctx) do
    with {:ok, card} <- need_card(ctx),
         {:ok, column} <- find_column(card, action["column"]) do
      if card.column_id == column.id do
        {:ok, "already in #{column.name}"}
      else
        Boards.move_card(card.id, column.id)
        {:ok, "moved to #{column.name}"}
      end
    end
  end

  defp do_perform("set_priority", action, ctx),
    do: set_fields(ctx, %{"priority" => to_string(action["priority"])}, "set priority")

  defp do_perform("complete_card", _action, ctx),
    do: set_fields(ctx, %{"completed" => true}, "completed")

  defp do_perform("reopen_card", _action, ctx),
    do: set_fields(ctx, %{"completed" => false}, "reopened")

  defp do_perform("clear_due_date", _action, ctx),
    do: set_fields(ctx, %{"due_date" => nil}, "cleared the due date")

  defp do_perform("set_due_date", action, ctx) do
    case due_date(action) do
      nil -> {:error, "no date given"}
      date -> set_fields(ctx, %{"due_date" => Date.to_iso8601(date)}, "due #{date}")
    end
  end

  defp do_perform("unassign", _action, ctx),
    do: set_fields(ctx, %{"assignee_id" => nil}, "unassigned")

  defp do_perform("assign", action, ctx) do
    case find_user(action["assignee"], ctx.board) do
      nil ->
        {:error, "no such person: #{action["assignee"]}"}

      user ->
        set_fields(ctx, %{"assignee_id" => user.id}, "assigned to #{User.display_name(user)}")
    end
  end

  defp do_perform("add_flags", action, ctx), do: change_flags(action, ctx, :add)
  defp do_perform("remove_flags", action, ctx), do: change_flags(action, ctx, :remove)
  defp do_perform("add_tags", action, ctx), do: change_tags(action, ctx, :add)
  defp do_perform("remove_tags", action, ctx), do: change_tags(action, ctx, :remove)

  defp do_perform("archive_card", _action, ctx) do
    with {:ok, card} <- need_card(ctx) do
      case Boards.archive_card(card) do
        {:ok, _} -> {:ok, "archived"}
        {:error, changeset} -> {:error, errors(changeset)}
      end
    end
  end

  defp do_perform("comment", action, ctx) do
    with {:ok, card} <- need_card(ctx) do
      body = text(action["body"], ctx, "")

      case Boards.add_comment(card, body) do
        {:ok, _} -> {:ok, "commented"}
        {:error, changeset} -> {:error, errors(changeset)}
      end
    end
  end

  defp do_perform("add_checklist_items", action, ctx) do
    with {:ok, card} <- need_card(ctx) do
      items = action["items"] |> List.wrap() |> Enum.map(&text(&1, ctx, ""))
      Enum.each(items, &Boards.add_checklist_item(card, &1))
      {:ok, "added #{length(items)} checklist items"}
    end
  end

  # A page for the card, pinned to it. The pin is the point: a page nobody can
  # reach from the work is a page nobody reads.
  defp do_perform("create_page", action, ctx) do
    case ctx[:card] do
      nil ->
        {:error, "there is no card to write up"}

      card ->
        opts =
          [
            user: nil,
            via: "automation",
            message: "created by the “#{ctx.rule && ctx.rule.name}” automation",
            title: text(action["title"], ctx, nil),
            summary: text(action["summary"], ctx, nil),
            body: text(action["body"], ctx, nil),
            template: action["template"],
            parent: action["parent"]
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        case Slipdock.Wiki.create_page_from_card(card, opts) do
          {:ok, page} -> {:ok, "started #{page.code} “#{page.title}”"}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, errors(changeset)}
          other -> {:error, inspect(other)}
        end
    end
  end

  defp do_perform("create_card", action, ctx) do
    board = ctx.board

    column =
      case action["column"] && Boards.find_column(board, to_string(action["column"])) do
        {:ok, column} -> column
        _ -> List.first(board.columns)
      end

    if column do
      attrs =
        %{"title" => text(action["title"], ctx, "Untitled")}
        |> put_if("description", text(action["description"], ctx, nil))
        |> put_if("priority", action["priority"] && to_string(action["priority"]))
        |> put_if("due_date", action["due_date"])
        |> put_if("assignee_id", find_user(action["assignee"], board) |> then(&(&1 && &1.id)))

      case Boards.create_card(column, attrs) do
        {:ok, card} ->
          tags = for name <- List.wrap(action["tags"]), tag = find_tag(board, name), do: tag
          if tags != [], do: Boards.set_card_tags(card, tags)
          {:ok, "created “#{card.title}”"}

        {:error, changeset} ->
          {:error, errors(changeset)}
      end
    else
      {:error, "the board has no lists"}
    end
  end

  defp do_perform("webhook", action, ctx) do
    url = text(action["url"], ctx, "")
    method = Notifier.method(action["method"])

    payload = %{
      rule: ctx.rule.name,
      event: to_string(ctx.event[:type]),
      board: board_payload(ctx.board),
      card: ctx.card && card_payload(ctx.card, ctx.board),
      at: DateTime.utc_now()
    }

    case Notifier.call(url, payload, method) do
      :ok -> {:ok, "#{method |> to_string() |> String.upcase()} #{url}"}
      {:error, reason} -> {:error, "callback failed: #{reason}"}
    end
  end

  defp do_perform("log", action, ctx) do
    message = text(action["message"], ctx, ctx.rule.name)
    Boards.log_activity(board_id(ctx), ctx.card && ctx.card.id, "automation", message)
    {:ok, "logged"}
  end

  defp do_perform(type, _action, _ctx), do: {:error, "unknown action “#{type}”"}

  ## Action helpers -----------------------------------------------------------

  defp set_fields(ctx, attrs, label) do
    with {:ok, card} <- need_card(ctx) do
      case Boards.update_card(card, attrs) do
        {:ok, _} -> {:ok, label}
        {:error, changeset} -> {:error, errors(changeset)}
      end
    end
  end

  defp change_flags(action, ctx, direction) do
    with {:ok, card} <- need_card(ctx) do
      wanted = action["flags"] |> List.wrap() |> Enum.map(&to_string/1)

      flags =
        case direction do
          :add -> Enum.uniq(card.flags ++ wanted)
          :remove -> card.flags -- wanted
        end

      if flags == card.flags do
        {:ok, "flags unchanged"}
      else
        set_fields(ctx, %{"flags" => flags}, "flags now #{Enum.join(flags, ", ")}")
      end
    end
  end

  defp change_tags(action, ctx, direction) do
    with {:ok, card} <- need_card(ctx) do
      board = Repo.get!(Slipdock.Boards.Board, card.board_id)
      names = action["tags"] |> List.wrap() |> Enum.map(&to_string/1)
      found = for name <- names, tag = find_tag(board, name), do: tag
      missing = names -- Enum.map(found, & &1.name)

      current = Repo.preload(card, :tags).tags

      tags =
        case direction do
          :add -> Enum.uniq_by(current ++ found, & &1.id)
          :remove -> Enum.reject(current, fn t -> t.id in Enum.map(found, & &1.id) end)
        end

      cond do
        found == [] and missing != [] ->
          {:error, "no such tag: #{Enum.join(missing, ", ")}"}

        Enum.map(tags, & &1.id) == Enum.map(current, & &1.id) ->
          {:ok, "tags unchanged"}

        true ->
          Boards.set_card_tags(card, tags)
          {:ok, "tags now #{Enum.map_join(tags, ", ", & &1.name)}"}
      end
    end
  end

  defp need_card(%{card: %Card{} = card}), do: {:ok, card}
  defp need_card(_), do: {:error, "there is no card to act on"}

  defp board_id(%{card: %Card{board_id: id}}), do: id
  defp board_id(%{board: board}), do: board.id

  defp find_column(card, name) do
    board = Repo.get!(Slipdock.Boards.Board, card.board_id)

    case Boards.find_column(board, to_string(name)) do
      {:ok, column} -> {:ok, column}
      _ -> {:error, "no list called “#{name}”"}
    end
  end

  defp find_tag(_board, nil), do: nil

  defp find_tag(board, name) do
    case Boards.find_tag(board, to_string(name)) do
      {:ok, %Tag{} = tag} -> tag
      _ -> nil
    end
  end

  defp find_user(nil, _board), do: nil

  # Scoped to the board's owner rather than to everybody: a rule on your board
  # must not be able to assign a card to somebody you have never shared
  # anything with, and on a shared server must not confirm they exist.
  defp find_user(reference, board) do
    wanted = casefold(reference)

    board
    |> Slipdock.Access.visible_users_for()
    |> Enum.find(fn user ->
      wanted in [casefold(user.email), casefold(user.name), casefold(User.display_name(user))]
    end)
  end

  defp due_date(%{"date" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      _ -> nil
    end
  end

  defp due_date(%{"in_days" => days}) when is_integer(days), do: Date.add(Date.utc_today(), days)
  defp due_date(_), do: nil

  defp put_if(attrs, _key, nil), do: attrs
  defp put_if(attrs, _key, ""), do: attrs
  defp put_if(attrs, key, value), do: Map.put(attrs, key, value)

  defp errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp errors(other), do: inspect(other)

  ## Templates ----------------------------------------------------------------

  @doc """
  Fills `{{...}}` placeholders in `template` from `bindings`. An unknown
  placeholder is left where it is rather than silently vanishing, so a typo
  in a rule shows up in the email instead of hiding in it.
  """
  def render(nil, _bindings), do: nil

  def render(template, bindings) when is_binary(template) do
    Regex.replace(~r/\{\{\s*([\w.]+)\s*\}\}/, template, fn whole, key ->
      case Map.fetch(bindings, key) do
        {:ok, value} -> to_string(value)
        :error -> whole
      end
    end)
  end

  def render(template, bindings), do: render(to_string(template), bindings)

  defp text(nil, _ctx, default), do: default
  defp text(template, ctx, _default), do: render(to_string(template), ctx.bindings)

  @doc "The placeholders a rule may use, for the event being handled."
  def variables(event) do
    card = event[:card]
    board = event[:board]
    rule = event[:rule]

    %{
      "event" => to_string(event[:type] || ""),
      "today" => Date.to_iso8601(Date.utc_today()),
      "now" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_string(),
      "rule.name" => rule && rule.name,
      "board.name" => board && board.name,
      "board.url" => board && "#{base_url()}/boards/#{board.id}"
    }
    |> Map.merge(card_variables(card, board))
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp card_variables(nil, _board), do: %{}

  defp card_variables(%Card{} = card, board) do
    card = decorate(card)
    board_id = (board && board.id) || card.board_id

    %{
      "card.id" => card.id,
      "card.title" => card.title,
      "card.description" => card.description,
      "card.priority" => card.priority,
      "card.column" => card.column && card.column.name,
      "card.assignee" => card.assignee && User.display_name(card.assignee),
      "card.due_date" => card.due_date && Date.to_iso8601(card.due_date),
      "card.start_date" => card.start_date && Date.to_iso8601(card.start_date),
      "card.tags" => Enum.map_join(card.tags, ", ", & &1.name),
      "card.flags" => Enum.join(card.flags, ", "),
      "card.status" => if(card.completed, do: "done", else: "open"),
      "card.url" => "#{base_url()}/boards/#{board_id}/cards/#{card.id}"
    }
  end

  # Everything a callback is told about the card: what it is, where to read
  # it, when it is meant to happen and how it is doing. The same keys reach a
  # GET as `card.title`, `card.url` and so on (see `Notifier.query/1`).
  defp card_payload(%Card{} = card, board) do
    %{
      id: card.id,
      title: card.title,
      url: card_url(card, board),
      description: card.description,
      column: card.column && card.column.name,
      priority: card.priority,
      assignee: card.assignee && User.display_name(card.assignee),
      assignee_email: card.assignee && card.assignee.email,
      start_date: card.start_date,
      due_date: card.due_date,
      completed: card.completed,
      status: card_status(card),
      health: Card.stated_health(card),
      percent_complete: card.percent_complete,
      blocked: Card.blocked?(card),
      flags: card.flags,
      tags: Enum.map(card.tags, & &1.name)
    }
  end

  defp card_status(%Card{archived_at: at}) when not is_nil(at), do: "archived"
  defp card_status(%Card{completed: true}), do: "done"
  defp card_status(%Card{}), do: "open"

  defp card_url(%Card{} = card, board) do
    "#{base_url()}/boards/#{(board && board.id) || card.board_id}/cards/#{card.id}"
  end

  defp board_payload(%{id: id} = board) do
    %{id: id, name: board.name, code: board.code, url: "#{base_url()}/boards/#{id}"}
  end

  defp board_payload(_), do: nil

  defp default_subject(%{card: %Card{title: title}, board: board}), do: "#{board.name}: #{title}"
  defp default_subject(%{board: board}), do: "#{board.name}: automation"

  defp default_body(%{card: %Card{} = card, rule: rule} = ctx) do
    """
    #{rule.name}

    #{card.title}
    #{Map.get(ctx.bindings, "card.url")}
    """
  end

  defp default_body(%{rule: rule, board: board}), do: "#{rule.name} (#{board.name})"

  @doc "The site's own address, for links in emails."
  def base_url do
    Application.get_env(:slipdock, :base_url) || endpoint_url()
  end

  defp endpoint_url do
    config = Application.get_env(:slipdock, SlipdockWeb.Endpoint, [])
    url = config[:url] || []
    scheme = url[:scheme] || "http"
    host = url[:host] || "localhost"

    port =
      url[:port] ||
        case config[:http] do
          nil -> nil
          http -> http[:port]
        end

    case {scheme, port} do
      {"https", 443} -> "https://#{host}"
      {"http", 80} -> "http://#{host}"
      {_, nil} -> "#{scheme}://#{host}"
      {_, port} -> "#{scheme}://#{host}:#{port}"
    end
  end

  @doc false
  # The facets conditions and templates read, loaded once per run.
  def decorate(%Card{} = card) do
    Repo.preload(card, [:tags, :column, :assignee, :status_updates, :blocked_by])
  end

  # A page's `blocked_by` and `description` are virtual (see
  # `Slipdock.Wiki.Page`), so only the real associations are preloaded and the
  # summary stands in for the description, as it does everywhere else.
  def decorate(%Page{} = page) do
    page
    |> Repo.preload([:tags, :column, :assignee, :status_updates])
    |> Page.for_board()
  end
end
