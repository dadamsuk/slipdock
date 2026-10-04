defmodule Slipdock.Automations do
  @moduledoc """
  Rules the user writes in plain language — "when a card lands in Done,
  email ops@example.com", "move anything untouched for a week back to
  Backlog", "warn me when a card is due within a day" — parsed once by
  `Slipdock.Automations.Parser` into a spec and then run by the app itself.

  Two things set a rule off:

    * **events** — `Slipdock.Boards` calls `dispatch/1` after every change it
      makes, and rules whose trigger matches run there and then;
    * **the clock** — `Slipdock.Automations.Scheduler` calls `run_scheduled/0`
      every few minutes for the triggers that are about elapsed time (stale,
      due soon, overdue), each firing once per occasion thanks to
      `Slipdock.Automations.Fire`.

  Rules can change cards, and changing a card dispatches more events, so a
  run carries a depth and stops at `@max_depth`: a rule that moves a card
  into the list a second rule watches works, a pair of rules that bat a card
  back and forth stops after a few passes and says so in the activity log.

  Alerts (`raise_alert/1`) are the quiet action: no email, just a line in
  the header bar of every page until the reader dismisses it.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Slipdock.Repo
  alias Slipdock.Accounts.User

  alias Slipdock.Automations.{
    Alert,
    Callback,
    Dismissal,
    Fire,
    Parser,
    Presets,
    Rule,
    Runner,
    Spec
  }

  alias Slipdock.Boards.{Board, Card}

  @pubsub Slipdock.PubSub
  @alerts_topic "alerts"
  @max_depth 3
  @alert_limit 100
  @callback_limit 200
  @max_rules 50

  ## PubSub -------------------------------------------------------------------

  @doc "Subscribes to `{:alerts_changed}`, broadcast whenever an alert appears or goes."
  def subscribe_alerts, do: Phoenix.PubSub.subscribe(@pubsub, @alerts_topic)

  defp broadcast_alerts do
    Phoenix.PubSub.broadcast(@pubsub, @alerts_topic, {:alerts_changed})
    :ok
  end

  ## Rules --------------------------------------------------------------------

  @examples [
    "When a card is added to Doing, email me@example.com with the card title and a link",
    "Move cards in In progress that nobody has touched for 7 days back to Backlog and flag them blocked",
    "Send an email to ops@example.com when a card is completed",
    "Show an alert if a card is due in less than 24 hours",
    "When a card is tagged urgent, set its priority to critical and raise an urgent alert",
    "Every weekday at 09:00, alert me about anything overdue",
    "When a card lands in Review, assign it to me and add a comment asking for a check",
    "If a high priority card has no due date, alert me with a warning",
    "POST to https://example.com/hooks/kanban whenever a card is archived",
    "When a card changes, GET https://example.com/hooks/kanban with the card and its dates"
  ]

  @doc "Example sentences for the rule composer."
  def examples, do: @examples

  @doc "The board's rules, newest last."
  def list_rules(board_id) do
    from(r in Rule, where: r.board_id == ^board_id, order_by: [asc: r.inserted_at])
    |> Repo.all()
  end

  def get_rule!(id), do: Repo.get!(Rule, id)

  @doc """
  The rule with `id` if it is on `board_id`, else nil. For ids that come from
  a client: owning the board you have open is no licence to touch a rule on
  somebody else's.
  """
  def get_board_rule(board_id, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.one(from(r in Rule, where: r.board_id == ^board_id and r.id == ^id))
      _ -> nil
    end
  end

  @doc "Finds a rule on `board` by id or (case-insensitive) name."
  def find_rule(%Board{id: board_id}, ref) do
    ref = to_string(ref)

    query =
      case Integer.parse(ref) do
        {id, ""} ->
          from(r in Rule, where: r.board_id == ^board_id and r.id == ^id)

        _ ->
          name = ref |> String.trim() |> String.downcase()

          from(r in Rule,
            where: r.board_id == ^board_id and fragment("lower(?)", r.name) == ^name
          )
      end

    case Repo.one(from(q in query, limit: 1)) do
      nil -> {:error, :not_found}
      rule -> {:ok, rule}
    end
  end

  @doc "One alert by id, or nil."
  def get_alert(id), do: Repo.get(Alert, to_int(id))

  @doc """
  Creates a rule from a spec. `attrs` needs "name", "spec" and "board_id";
  `opts[:created_by]` records who wrote it. `create_rule_from_text/3` is the
  friendlier way in.
  """
  def create_rule(attrs, opts \\ []) do
    %Rule{created_by_id: opts[:created_by] && opts[:created_by].id}
    |> Rule.changeset(attrs)
    |> check_rule_count()
    |> check_recipients()
    |> Repo.insert()
    |> tap_ok(&log_rule(&1, "added automation “#{&1.name}”"))
  end

  def update_rule(%Rule{} = rule, attrs) do
    rule
    |> Rule.changeset(attrs)
    |> check_recipients()
    |> Repo.update()
  end

  @doc "How many rules one board may have."
  def max_rules, do: @max_rules

  defp check_rule_count(changeset) do
    board_id = Ecto.Changeset.get_field(changeset, :board_id)

    if changeset.valid? and is_integer(board_id) and
         Repo.aggregate(from(r in Rule, where: r.board_id == ^board_id), :count) >= @max_rules do
      Ecto.Changeset.add_error(changeset, :board_id, "already has #{@max_rules} automations")
    else
      changeset
    end
  end

  # Automation email goes out under this server's name, so it may only go to
  # people who can already read the board: otherwise a rule is an open relay
  # to any address its author cares to type. Checked when the spec changes;
  # `allowed_recipients/2` checks again at send time, since access can be
  # taken away after the rule was saved.
  defp check_recipients(changeset) do
    with true <- changeset.valid?,
         spec when is_map(spec) <- Ecto.Changeset.get_change(changeset, :spec),
         [_ | _] = wanted <- email_recipients(spec),
         %Board{} = board <- Repo.get(Board, Ecto.Changeset.get_field(changeset, :board_id)) do
      case allowed_recipients(board, wanted) do
        {_, []} ->
          changeset

        {_, refused} ->
          Ecto.Changeset.add_error(
            changeset,
            :spec,
            "can only email people who can see this board, not #{Enum.join(refused, ", ")}"
          )
      end
    else
      _ -> changeset
    end
  end

  defp email_recipients(spec) do
    spec
    |> Spec.actions()
    |> Enum.filter(&(&1["type"] == "email"))
    |> Enum.flat_map(&List.wrap(&1["to"]))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  @doc """
  Splits `addresses` into those that belong to somebody who can read `board`
  and those that don't: `{allowed, refused}`, compared case-insensitively.
  """
  def allowed_recipients(%Board{} = board, addresses) do
    readers =
      board
      |> Slipdock.Wiki.Links.members()
      |> MapSet.new(&String.downcase(&1.email))

    Enum.split_with(addresses, &MapSet.member?(readers, Slipdock.Email.normalize(&1)))
  end

  def delete_rule(%Rule{} = rule) do
    Repo.delete(rule) |> tap_ok(&log_rule(&1, "removed automation “#{&1.name}”"))
  end

  def toggle_rule(%Rule{} = rule) do
    rule |> Ecto.Changeset.change(enabled: !rule.enabled) |> Repo.update()
  end

  def change_rule(%Rule{} = rule, attrs \\ %{}), do: Rule.changeset(rule, attrs)

  @doc """
  Turns a sentence into a rule on `board`, asking the model to write the
  spec. Returns `{:ok, rule}` or `{:error, message}`.
  """
  def create_rule_from_text(%Board{} = board, text, opts \\ []) do
    with {:ok, ai_opts} <- parser_opts(opts),
         {:ok, %{"name" => name, "spec" => spec} = parsed} <-
           Parser.parse(board, text, ai_opts) do
      attrs = %{
        "name" => name,
        "source" => text,
        "spec" => spec,
        "scope" => parsed["scope"] || "board",
        "board_id" => board.id
      }

      case create_rule(attrs, opts) do
        {:ok, rule} -> {:ok, rule}
        {:error, changeset} -> {:error, changeset_message(changeset)}
      end
    end
  end

  @doc """
  Adds one of the ready-made rules (`Slipdock.Automations.Presets`) to
  `board`, filled in with `params` — no model involved. Returns `{:ok, rule}`
  or `{:error, message}`.
  """
  def create_rule_from_preset(%Board{} = board, key, params, opts \\ []) do
    with {:ok, attrs} <- Presets.build(key, params, user: opts[:created_by]) do
      case create_rule(Map.put(attrs, "board_id", board.id), opts) do
        {:ok, rule} -> {:ok, rule}
        {:error, changeset} -> {:error, changeset_message(changeset)}
      end
    end
  end

  # Writing a rule is an AI call, so it runs on the author's own model and
  # key (`:created_by`) — see `Slipdock.AI.provider/1`. Without one it would
  # fall through to the system settings, which are somebody else's, so an
  # author is required rather than assumed.
  defp parser_opts(opts) do
    case opts[:created_by] do
      %Slipdock.Accounts.User{} = user ->
        {:ok, opts |> Keyword.delete(:created_by) |> Keyword.put(:user, user)}

      _ ->
        {:error, "Writing a rule needs to know who is asking, to use their AI model."}
    end
  end

  @doc """
  Re-reads a rule's plain-language description and replaces its spec, on the
  model of whoever is asking (`:created_by`, required).
  """
  def rewrite_rule(%Rule{} = rule, text, opts \\ []) do
    board = Repo.get!(Board, rule.board_id) |> Repo.preload([:columns, :tags])

    with {:ok, ai_opts} <- parser_opts(opts),
         {:ok, %{"name" => name, "spec" => spec} = parsed} <-
           Parser.parse(board, text, ai_opts) do
      case update_rule(rule, %{
             "name" => name,
             "source" => text,
             "spec" => spec,
             "scope" => parsed["scope"] || rule.scope
           }) do
        {:ok, rule} -> {:ok, rule}
        {:error, changeset} -> {:error, changeset_message(changeset)}
      end
    end
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  ## Events -------------------------------------------------------------------

  @doc """
  Runs the rules that match `event`. Called by `Slipdock.Boards` after each
  change; safe to call with anything, and a no-op when no rule cares.

  The event is a map with a `:type` (see `Slipdock.Automations.Spec`) and
  whatever that type carries: `:card`, `:column`, `:from`, `:to`, `:fields`,
  `:assignee`, `:tag`, `:flag`.
  """
  def dispatch(event) when is_map(event) do
    depth = Process.get(:automation_depth, 0)

    cond do
      not enabled?() ->
        :ok

      depth >= @max_depth ->
        Logger.warning("Automations stopped at depth #{depth} for #{inspect(event[:type])}")
        :ok

      true ->
        event
        |> rules_for()
        |> Enum.filter(&(&1.enabled and Runner.matches?(&1, event)))
        |> Enum.each(&fire(&1, event, depth))

        :ok
    end
  end

  def dispatch(_), do: :ok

  # Rules live on a board; a "tree" rule also watches the sub-boards beneath it.
  defp rules_for(%{card: %Card{board_id: board_id}}), do: rules_watching(board_id)
  defp rules_for(%{board_id: board_id}) when is_integer(board_id), do: rules_watching(board_id)
  defp rules_for(_), do: []

  defp rules_watching(board_id) do
    root_id = Slipdock.Boards.root_of_board(board_id)

    from(r in Rule,
      where: r.board_id == ^board_id or (r.board_id == ^root_id and r.scope == "tree"),
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
  end

  # One rule, one event. The depth travels with the process so that changes
  # this rule makes know how deep they already are, and a rule that blows up
  # is the rule's problem, never the caller's: dragging a card must not fail
  # because an automation did.
  defp fire(rule, event, depth) do
    previous = Process.get(:automation_depth, 0)
    Process.put(:automation_depth, depth + 1)

    try do
      results = Runner.run(rule, event)
      record_run(rule, results)
      if Enum.any?(results, &match?({:ok, _}, &1)), do: broadcast_alerts()
      results
    rescue
      exception ->
        record_run(rule, [{:error, Exception.message(exception)}])
        [{:error, Exception.message(exception)}]
    after
      Process.put(:automation_depth, previous)
    end
  end

  defp record_run(rule, results) do
    error =
      results
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map_join("; ", fn {:error, reason} -> reason end)

    error = if error == "", do: nil, else: String.slice(error, 0, 250)

    if error, do: Logger.warning("Automation “#{rule.name}” (##{rule.id}): #{error}")

    from(r in Rule, where: r.id == ^rule.id)
    |> Repo.update_all(
      set: [last_run_at: DateTime.utc_now(:second), last_error: error],
      inc: [run_count: 1]
    )
  end

  @doc "Runs one rule against one card now, whatever its trigger says."
  def run_now(%Rule{} = rule, card \\ nil) do
    event = %{type: Spec.trigger_type(rule.spec), card: card, board_id: rule.board_id}
    fire(rule, event, Process.get(:automation_depth, 0))
  end

  @doc """
  The “Run now” button: a time-based rule forgets what it has already acted
  on and looks again, an event rule runs once with no card. Returns how many
  times it fired.
  """
  def run_rule_now(%Rule{} = rule, now \\ DateTime.utc_now()) do
    if Spec.scheduled?(rule.spec) do
      clear_fires(rule)
      run_scheduled_rule(rule, now)
    else
      run_now(rule)
      1
    end
  end

  defp enabled?, do: Application.get_env(:slipdock, :automations, [])[:enabled] != false

  ## Scheduled rules ----------------------------------------------------------

  @doc """
  Runs every enabled rule whose trigger is about elapsed time. Each rule
  fires once per occasion — one card going stale, one due date coming up,
  one day passing — recorded in `automation_fires`.
  """
  def run_scheduled(now \\ DateTime.utc_now()) do
    scheduled_types = Spec.scheduled_types()

    from(r in Rule, where: r.enabled == true, order_by: [asc: r.id])
    |> Repo.all()
    |> Enum.filter(&(Spec.trigger_type(&1.spec) in scheduled_types))
    |> Enum.map(&run_scheduled_rule(&1, now))
    |> Enum.sum()
  end

  defp run_scheduled_rule(rule, now) do
    trigger = rule.spec["trigger"]

    case trigger["type"] do
      "schedule" -> run_board_schedule(rule, trigger, now)
      _ -> run_card_schedule(rule, trigger, now)
    end
  end

  # A board-level rule: nothing to match against, just a time of day.
  defp run_board_schedule(rule, trigger, now) do
    today = DateTime.to_date(now)
    at = trigger["at"] || "09:00"

    due? =
      due_today?(at, now) and
        (is_nil(trigger["weekday"]) or Date.day_of_week(today) == trigger["weekday"])

    if due? and claim(rule, nil, "schedule:#{Date.to_iso8601(today)}") do
      fire(rule, %{type: "schedule", card: nil, board_id: rule.board_id}, 0)
      1
    else
      0
    end
  end

  defp due_today?(at, now) do
    case String.split(to_string(at), ":") do
      [h, m] ->
        with {hour, ""} <- Integer.parse(h), {minute, ""} <- Integer.parse(m) do
          time = DateTime.to_time(now)
          Time.compare(time, Time.new!(hour, minute, 0)) != :lt
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  # A card-level rule: every active card the rule watches, tested against the
  # trigger's own sense of "now".
  defp run_card_schedule(rule, trigger, now) do
    today = DateTime.to_date(now)

    rule
    |> watched_cards()
    |> Enum.filter(&due_card?(trigger, &1, now, today))
    |> Enum.filter(&Runner.conditions_match?(Spec.conditions(rule.spec), &1))
    |> Enum.filter(&claim(rule, &1, occasion(trigger, &1, today)))
    |> Enum.map(fn card ->
      fire(rule, %{type: trigger["type"], card: card, board_id: rule.board_id}, 0)
      1
    end)
    |> Enum.sum()
  end

  defp watched_cards(%Rule{scope: "tree", board_id: board_id}) do
    root_id = Slipdock.Boards.root_of_board(board_id)

    active_cards(
      from(c in Card,
        join: b in Board,
        on: b.id == c.board_id,
        where: b.id == ^root_id or b.root_id == ^root_id
      )
    )
  end

  defp watched_cards(%Rule{board_id: board_id}),
    do: active_cards(from(c in Card, where: c.board_id == ^board_id))

  defp active_cards(query) do
    query
    |> where([c], is_nil(c.archived_at))
    |> Repo.all()
    |> Repo.preload([:column, :tags, :assignee, :assignees, :status_updates, :blocked_by])
  end

  defp due_card?(%{"type" => "card_stale"} = trigger, card, now, _today) do
    days = trigger["days"] || 7

    not card.completed and
      column_matches?(trigger["column"], card) and
      DateTime.diff(now, card.updated_at, :day) >= days
  end

  defp due_card?(%{"type" => "card_due_soon"} = trigger, card, _now, today) do
    hours =
      trigger["within_hours"] || (trigger["within_days"] && trigger["within_days"] * 24) || 24

    window = ceil(hours / 24)

    case card.due_date do
      nil ->
        false

      due ->
        days = Date.diff(due, today)
        not card.completed and days >= 0 and days <= window
    end
  end

  defp due_card?(%{"type" => "card_overdue"} = trigger, card, _now, today) do
    by = trigger["by_days"] || 0

    case card.due_date do
      nil -> false
      due -> not card.completed and Date.diff(today, due) > by
    end
  end

  defp due_card?(%{"type" => "card_starts_soon"} = trigger, card, _now, today) do
    window = trigger["within_days"] || 1

    case card.start_date do
      nil ->
        false

      start ->
        days = Date.diff(start, today)
        not card.completed and days >= 0 and days <= window
    end
  end

  defp due_card?(_, _, _, _), do: false

  defp column_matches?(nil, _card), do: true

  defp column_matches?(name, card) do
    card.column && String.downcase(card.column.name) == String.downcase(to_string(name))
  end

  # What the rule is firing about, so it fires again when that changes but
  # not before: a new due date, a card touched and gone stale again, a new day.
  defp occasion(%{"type" => "card_stale"}, card, _today),
    do: "stale:#{card.id}:#{DateTime.to_unix(card.updated_at)}"

  defp occasion(%{"type" => "card_due_soon"}, card, _today),
    do: "due_soon:#{card.id}:#{card.due_date}"

  defp occasion(%{"type" => "card_overdue"}, card, today),
    do: "overdue:#{card.id}:#{card.due_date}:#{Date.to_iso8601(today)}"

  defp occasion(%{"type" => "card_starts_soon"}, card, _today),
    do: "starts_soon:#{card.id}:#{card.start_date}"

  defp occasion(%{"type" => type}, card, today),
    do: "#{type}:#{card.id}:#{Date.to_iso8601(today)}"

  # The unique index does the work: whoever inserts the row first gets to run.
  defp claim(rule, card, key) do
    attrs = %{
      rule_id: rule.id,
      card_id: card && card.id,
      key: key,
      inserted_at: DateTime.utc_now(:second)
    }

    case Repo.insert_all(Fire, [attrs], on_conflict: :nothing) do
      {1, _} -> true
      _ -> false
    end
  end

  @doc "Forgets what a rule has already done, so it can fire again (used by “Run now”)."
  def clear_fires(%Rule{} = rule) do
    from(f in Fire, where: f.rule_id == ^rule.id) |> Repo.delete_all()
    :ok
  end

  ## Callbacks ----------------------------------------------------------------

  @doc "Subscribes to `{:callbacks_changed, board_id}`, broadcast as each of the board's callbacks lands."
  def subscribe_callbacks(board_id),
    do: Phoenix.PubSub.subscribe(@pubsub, "callbacks:#{board_id}")

  @doc """
  Records one callback a rule made (see `Slipdock.Automations.Callback`),
  and lets the board's oldest go once there are more than #{@callback_limit}.
  Called by `Slipdock.Automations.Notifier` when the call has finished.
  """
  def log_callback(%{board_id: board_id} = attrs) when is_integer(board_id) do
    row =
      attrs
      |> Map.take([:board_id, :rule_id, :card_id, :method, :status, :duration_ms])
      |> Map.merge(%{
        rule_name: clip(attrs[:rule_name], 255),
        card_title: clip(attrs[:card_title], 255),
        url: clip(attrs[:url], 2000),
        error: clip(attrs[:error], 500),
        inserted_at: DateTime.utc_now(:second)
      })

    {1, _} = Repo.insert_all(Callback, [row])
    prune_callbacks(board_id)
    Phoenix.PubSub.broadcast(@pubsub, "callbacks:#{board_id}", {:callbacks_changed, board_id})
    :ok
  end

  def log_callback(_), do: :ok

  defp prune_callbacks(board_id) do
    oldest_kept =
      from(c in Callback,
        where: c.board_id == ^board_id,
        order_by: [desc: c.id],
        offset: @callback_limit - 1,
        limit: 1,
        select: c.id
      )
      |> Repo.one()

    if oldest_kept do
      from(c in Callback, where: c.board_id == ^board_id and c.id < ^oldest_kept)
      |> Repo.delete_all()
    end
  end

  @doc "The board's callbacks, newest first."
  def list_callbacks(board_id, limit \\ nil) do
    limit =
      if limit in [nil, ""], do: 50, else: limit |> to_int() |> max(1) |> min(@callback_limit)

    from(c in Callback, where: c.board_id == ^board_id, order_by: [desc: c.id], limit: ^limit)
    |> Repo.all()
  end

  defp clip(nil, _), do: nil
  defp clip(text, max), do: text |> to_string() |> String.slice(0, max)

  ## Alerts -------------------------------------------------------------------

  @doc """
  Raises an alert, unless the same rule already has an undismissed one on
  the same card: a rule that keeps noticing the same thing says it once.
  """
  def raise_alert(attrs) do
    case existing_alert(attrs) do
      %Alert{} = alert ->
        {:ok, alert}

      nil ->
        %Alert{}
        |> Alert.changeset(attrs)
        |> Repo.insert()
        |> tap_ok(fn _ -> broadcast_alerts() end)
    end
  end

  defp existing_alert(%{"rule_id" => rule_id, "title" => title} = attrs)
       when not is_nil(rule_id) do
    from(a in Alert,
      where: a.rule_id == ^rule_id and a.title == ^title,
      where: ^card_clause(attrs["card_id"]),
      limit: 1
    )
    |> Repo.one()
  end

  defp existing_alert(_), do: nil

  defp card_clause(nil), do: dynamic([a], is_nil(a.card_id))
  defp card_clause(card_id), do: dynamic([a], a.card_id == ^card_id)

  @doc """
  The alerts this user should see: raised on a board they can read and not
  yet dismissed by them, most urgent first.
  """
  def list_alerts(%User{} = user) do
    board_ids = Slipdock.Access.readable_board_ids(user)

    from(a in Alert,
      left_join: d in Dismissal,
      on: d.alert_id == a.id and d.user_id == ^user.id,
      where: a.board_id in ^board_ids and is_nil(d.id),
      order_by: [desc: a.inserted_at],
      limit: @alert_limit
    )
    |> Repo.all()
    |> Repo.preload([:card, :board])
    |> Enum.sort_by(&{severity_rank(&1.severity), -DateTime.to_unix(&1.inserted_at)})
  end

  def list_alerts(_), do: []

  defp severity_rank("urgent"), do: 0
  defp severity_rank("warning"), do: 1
  defp severity_rank(_), do: 2

  @doc "Marks one alert as read by this person. Others still see it."
  def dismiss_alert(%User{} = user, alert_id) do
    Repo.insert_all(
      Dismissal,
      [%{alert_id: to_int(alert_id), user_id: user.id, inserted_at: DateTime.utc_now(:second)}],
      on_conflict: :nothing
    )

    broadcast_alerts()
  end

  @doc "Dismisses every alert this person can currently see."
  def dismiss_all_alerts(%User{} = user) do
    now = DateTime.utc_now(:second)

    rows =
      user
      |> list_alerts()
      |> Enum.map(&%{alert_id: &1.id, user_id: user.id, inserted_at: now})

    if rows != [], do: Repo.insert_all(Dismissal, rows, on_conflict: :nothing)
    broadcast_alerts()
  end

  @doc "Deletes an alert outright, for everyone (used when its rule is removed)."
  def delete_alert(id) do
    from(a in Alert, where: a.id == ^to_int(id)) |> Repo.delete_all()
    broadcast_alerts()
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, _} -> id
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  ## Helpers ------------------------------------------------------------------

  defp log_rule(%Rule{} = rule, message) do
    Slipdock.Boards.log_activity(rule.board_id, nil, "automation", message)
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(result, _fun), do: result
end
