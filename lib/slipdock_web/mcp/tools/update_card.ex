defmodule SlipdockWeb.MCP.Tools.UpdateCard do
  @moduledoc """
  Changes a card's fields, flags, tags and assignees, what blocks it, its
  checklist and whether it repeats. All of it lands or none of it does.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Boards, Repo}
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.{Args, Tools}

  @fields ~w(title description priority due_date start_date percent_complete color border_top
             border_right border_bottom border_left)
  @lists ~w(add_flags remove_flags add_tags remove_tags assignees add_assignees remove_assignees)
  @id_lists ~w(add_blocked_by remove_blocked_by check_items uncheck_items)

  @impl true
  def name, do: "update_card"

  @impl true
  def title, do: "Update a card"

  @impl true
  def description,
    do:
      "Changes a card: title, description, priority, dates, percent_complete, its cover " <>
        "colour (color) and the colour of each edge (border_top/right/bottom/left), flags " <>
        "(blocked, waiting, review), tags, assignees, the cards blocking it and its " <>
        "checklist (item ids from get_card), and whether it repeats: recurrence " <>
        "{rule: \"every mon\"} makes it a recurring card (null stops it), and whether it " <>
        "is snoozed: snoozed_until hides it until then (null wakes it). Only what you " <>
        "pass changes."

  @impl true
  def input_schema do
    list = %{type: "array", items: %{type: "string"}}
    ids = %{type: "array", items: %{type: "integer"}}

    border = %{
      type: "string",
      enum: ["" | Slipdock.Palette.names()],
      description: "That edge of the card's front in a palette colour; \"\" takes it off."
    }

    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        title: %{type: "string"},
        description: %{type: "string", description: "Replaces the whole description."},
        priority: %{type: "string", enum: ["none", "low", "medium", "high", "critical"]},
        due_date: %{type: "string", description: "YYYY-MM-DD; \"\" clears it."},
        start_date: %{type: "string", description: "YYYY-MM-DD; \"\" clears it."},
        percent_complete: %{type: "integer", minimum: 0, maximum: 100},
        color: %{
          border
          | description: "The card's cover colour, from the palette; \"\" takes it off."
        },
        border_top: border,
        border_right: border,
        border_bottom: border,
        border_left: border,
        add_flags: list,
        remove_flags: list,
        add_tags:
          Map.put(
            list,
            :description,
            "Tag names already on the board (get_board lists them; create_tag adds one)."
          ),
        remove_tags: Map.put(list, :description, "Tag names on the board."),
        assignees:
          Map.put(list, :description, "Replaces who is on it; [] unassigns. \"me\" for yourself."),
        add_assignees: list,
        remove_assignees: list,
        add_blocked_by: Map.put(ids, :description, "Cards that must finish before this one."),
        remove_blocked_by: ids,
        add_checklist: Map.put(list, :description, "New checklist items, in order."),
        check_items: Map.put(ids, :description, "Checklist item ids to tick."),
        uncheck_items: ids,
        snoozed_until: %{
          type: ["string", "null"],
          description:
            "Snooze (W-1803): hide the card from the lists, My work and runners until then " <>
              "— YYYY-MM-DD (midnight where you are), an ISO datetime, or tomorrow, mon, " <>
              "next week, in 3 days. It wakes to the top of its list. null wakes it now. " <>
              "Use it rather than flagging waiting when the wait has a date."
        },
        snooze_note: %{
          type: "string",
          description: "Why it is snoozed (≤ 280 characters), with snoozed_until."
        },
        wait: %{
          type: ["object", "null"],
          description:
            "Opens a wait: the card needs something only a person can give. It flags the " <>
              "card waiting and comments the question; answering it clears the flag. null " <>
              "withdraws the open wait. A runner job's session links its job by itself.",
          properties: %{
            needs: %{type: "string", description: "What you need, as a question."},
            on: %{
              type: "string",
              description: "Who it waits on: email or \"me\"; omit for anyone."
            },
            choices: Map.put(list, :description, "Answers to pick from, if it is a choice."),
            job_id: %{type: "integer", description: "Your runner job on this card, if any."}
          },
          required: ["needs"],
          additionalProperties: false
        },
        answer_wait: %{
          type: "object",
          description:
            "Answers the card's open wait, as a comment from you. Not one you opened yourself.",
          properties: %{
            answer: %{type: "string"},
            choice: %{type: "integer", minimum: 1, description: "A choice's number, from 1."}
          },
          additionalProperties: false
        },
        recurrence: %{
          type: ["object", "null"],
          description:
            "Makes the card repeat, or changes how (W-1802); null stops it. The next " <>
              "instance is a copy of this card as it is then, made on the scheduler's tick " <>
              "in the card's ready list. A card with no due date becomes the first " <>
              "occurrence. get_card shows it, with next_at.",
          properties: %{
            rule: %{
              type: "string",
              description:
                "How often: \"every mon\", \"weekday\", \"2w mon thu\", \"month 1\", " <>
                  "\"month last fri\", \"year\", \"3d after\" (3 days after the last " <>
                  "is done), or an RRULE subset (FREQ=WEEKLY;BYDAY=MO). Required to start one."
            },
            at: %{type: "string", description: "Time of day it is made, HH:MM (07:00)."},
            timezone: %{type: "string", description: "IANA name; defaults to yours."},
            lead_days: %{
              type: "integer",
              minimum: 0,
              description: "Make it this many days early."
            },
            on_missed: %{
              type: "string",
              enum: ["bump", "skip", "stack"],
              description:
                "When the last one is still open: bump (default) moves its due date on, " <>
                  "skip lets the occurrence go, stack makes another anyway."
            },
            ends: %{type: "string", enum: ["never", "on", "after"]},
            ends_on: %{type: "string", description: "YYYY-MM-DD, with ends: on."},
            count: %{
              type: "integer",
              minimum: 1,
              description: "How many in all, with ends: after."
            },
            column: %{type: "string", description: "A list on the board to put each one in."},
            paused: %{type: "boolean"},
            skip: %{type: "boolean", description: "true lets the next occurrence go."}
          },
          additionalProperties: false
        }
      },
      required: ["card"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def destructive?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- Args.id(args, "card"),
         {:ok, params} <- params(args),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :write)),
         {:ok, blockers} <- blockers(auth, params["add_blocked_by"]),
         {:ok, unblockers} <- cards(params["remove_blocked_by"]),
         {:ok, to_check} <- items(card, params["check_items"]),
         {:ok, to_uncheck} <- items(card, params["uncheck_items"]),
         {:ok, recurrence} <- recurrence_arg(args),
         {:ok, snooze} <- snooze_arg(args),
         {:ok, wait_op} <- wait_arg(args),
         {:ok, card} <-
           write(
             auth,
             card,
             params,
             blockers,
             unblockers,
             to_check,
             to_uncheck,
             {recurrence, snooze}
           ),
         {:ok, wait} <- write_wait(auth, card, wait_op) do
      card = if wait_op == :untouched, do: card, else: Boards.get_card!(card.id)
      written = Tools.card_written(card, context.base_url)

      written =
        if(recurrence == :untouched,
          do: written,
          else: Map.put(written, :recurrence, card.recurrence && V.recurrence(card.recurrence))
        )

      {:ok, if(wait_op == :untouched, do: written, else: Map.put(written, :wait, V.wait(wait)))}
    end
  end

  # Waiting on a person (#1114): open one, withdraw it (null), or answer it.
  defp wait_arg(args) do
    case {Map.fetch(args, "wait"), Map.fetch(args, "answer_wait")} do
      {{:ok, _}, {:ok, _}} -> {:error, "pass wait or answer_wait, not both"}
      {{:ok, nil}, :error} -> {:ok, :withdraw}
      {{:ok, %{} = wait}, :error} -> {:ok, {:open, wait}}
      {{:ok, _}, :error} -> {:error, "wait is an object ({needs: \"…\"}) or null"}
      {:error, {:ok, %{} = answer}} -> {:ok, {:answer, answer}}
      {:error, {:ok, _}} -> {:error, "answer_wait is an object ({answer: \"…\"} or {choice: 1})"}
      {:error, :error} -> {:ok, :untouched}
    end
  end

  defp write_wait(_auth, _card, :untouched), do: {:ok, nil}

  defp write_wait(auth, card, :withdraw),
    do: Args.refusal(CardWrites.withdraw_wait(auth, card))

  defp write_wait(auth, card, {:open, wait}),
    do: Args.refusal(CardWrites.open_wait(auth, card, wait))

  defp write_wait(auth, card, {:answer, answer}),
    do: Args.refusal(CardWrites.answer_wait(auth, card, answer))

  defp recurrence_arg(args) do
    case Map.fetch(args, "recurrence") do
      :error -> {:ok, :untouched}
      {:ok, nil} -> {:ok, :stop}
      {:ok, %{} = attrs} -> {:ok, attrs}
      {:ok, _} -> {:error, "recurrence is an object ({rule: \"every mon\"}) or null"}
    end
  end

  defp snooze_arg(args) do
    note = Map.get(args, "snooze_note")

    case Map.fetch(args, "snoozed_until") do
      :error when is_nil(note) -> {:ok, :untouched}
      :error -> {:ok, {:note, note}}
      {:ok, nil} -> {:ok, :wake}
      {:ok, until} when is_binary(until) -> {:ok, {:until, until, note}}
      {:ok, _} -> {:error, "snoozed_until is a date or datetime string, or null"}
    end
  end

  defp write_snooze(_auth, _card, :untouched), do: :ok

  # Waking a card that is already awake is what was asked for.
  defp write_snooze(auth, card, :wake) do
    case Slipdock.Snooze.wake(Repo.reload!(card), by: auth.assigns.current_user) do
      {:ok, _} -> :ok
      {:error, :not_snoozed} -> :ok
    end
  end

  # A note alone changes the note on the snooze the card already has.
  defp write_snooze(auth, card, {:note, note}) do
    card = Repo.reload!(card)

    if Slipdock.Boards.Card.snoozed?(card),
      do: snooze(auth, card, card.snoozed_until, note, card),
      else: {:error, "card ##{card.id} isn't snoozed: pass snoozed_until with the note"}
  end

  defp write_snooze(auth, card, {:until, until, note}) do
    card = Repo.reload!(card)
    snooze(auth, card, until, note, card)
  end

  defp snooze(auth, card, until, note, current) do
    opts = [
      note: note,
      notify: current.snooze_notify,
      wake_on_activity: current.snooze_wake_on_activity
    ]

    case Slipdock.Snooze.snooze(card, auth.assigns.current_user, until, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "snooze: " <> Slipdock.Snooze.error_message(reason)}
    end
  end

  defp write_recurrence(_auth, _card, :untouched), do: :ok

  defp write_recurrence(_auth, card, :stop) do
    Slipdock.Recurrence.stop(card)
    :ok
  end

  defp write_recurrence(auth, card, attrs) do
    {skip?, attrs} = Map.pop(attrs, "skip")

    with :ok <- set_recurrence(auth, card, attrs),
         :ok <- if(skip? == true, do: skip_recurrence(card), else: :ok) do
      :ok
    end
  end

  # Only `skip` given changes nothing else about the series.
  defp set_recurrence(_auth, _card, attrs) when map_size(attrs) == 0, do: :ok

  defp set_recurrence(auth, card, attrs) do
    case Slipdock.Recurrence.set(card, attrs, auth.assigns.current_user) do
      {:ok, _} -> :ok
      {:error, message} when is_binary(message) -> {:error, "recurrence " <> message}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  defp skip_recurrence(card) do
    case Slipdock.Recurrence.skip(card) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        {:error, "card ##{card.id} doesn't repeat, so there is nothing to skip"}

      {:error, message} ->
        {:error, message}
    end
  end

  # Everything is checked before anything is written; what can still fail
  # (a dependency that would make a loop, say) rolls the rest back with it.
  defp write(auth, card, params, blockers, unblockers, to_check, to_uncheck, {recurrence, snooze}) do
    Repo.transaction(fn ->
      with {:ok, card} <-
             update_fields(auth, card, Map.drop(params, @id_lists ++ ["add_checklist"])),
           :ok <- write_recurrence(auth, card, recurrence),
           :ok <- write_snooze(auth, card, snooze),
           :ok <- each(blockers, &add_blocker(card, &1)),
           :ok <- each(unblockers, &Boards.remove_dependency(card, &1)),
           added = params["add_checklist"] || [],
           ticked = Enum.reject(to_check, & &1.done),
           unticked = Enum.filter(to_uncheck, & &1.done),
           :ok <- each(added, &Boards.add_checklist_item(card, &1, log: false)),
           :ok <- each(ticked, &Boards.toggle_checklist_item(&1, log: false)),
           :ok <- each(unticked, &Boards.toggle_checklist_item(&1, log: false)),
           :ok <-
             Boards.log_checklist(card,
               added: length(added),
               ticked: length(ticked),
               unticked: length(unticked)
             ) do
        Boards.get_card!(card.id)
      else
        error -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, card} -> {:ok, card}
      {:error, error} -> Args.refusal(error)
    end
  end

  defp update_fields(_auth, card, params) when map_size(params) == 0, do: {:ok, card}
  defp update_fields(auth, card, params), do: CardWrites.update(auth, card, params)

  # Already blocked by it is what was asked for, not a mistake.
  defp add_blocker(card, blocker) do
    if Enum.any?(card.blocked_by, &(&1.id == blocker.id)),
      do: {:ok, card},
      else: Boards.add_dependency(card, blocker)
  end

  defp each(things, fun) do
    Enum.reduce_while(things, :ok, fn thing, :ok ->
      case fun.(thing) do
        {:error, message} when is_binary(message) -> {:halt, {:error, message}}
        {:error, _} = error -> {:halt, error}
        _ -> {:cont, :ok}
      end
    end)
  end

  # A blocker may sit on another board; reading it is enough, as over the API.
  defp blockers(auth, ids) do
    with {:ok, cards} <- cards(ids) do
      Enum.reduce_while(cards, {:ok, cards}, fn card, acc ->
        case Authorize.card(auth, card, :read) do
          :ok -> {:cont, acc}
          refused -> {:halt, Args.refusal(refused)}
        end
      end)
    end
  end

  defp cards(nil), do: {:ok, []}

  defp cards(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case CardWrites.fetch_card(id) do
        {:ok, card} -> {:cont, {:ok, acc ++ [card]}}
        _ -> {:halt, {:error, "no card ##{id} you can see"}}
      end
    end)
  end

  defp items(_card, nil), do: {:ok, []}

  defp items(card, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Enum.find(card.checklist_items, &(&1.id == id)) do
        nil -> {:halt, {:error, "checklist item #{id} is not on card ##{card.id}"}}
        item -> {:cont, {:ok, acc ++ [item]}}
      end
    end)
  end

  defp params(args) do
    with {:ok, params} <- collect(@lists, &Args.strings/2, args, Map.take(args, @fields)),
         {:ok, params} <- collect(~w(add_checklist), &Args.strings/2, args, params),
         {:ok, params} <- collect(@id_lists, &Args.ids/2, args, params) do
      if map_size(params) == 0 and
           not Enum.any?(
             ~w(recurrence snoozed_until snooze_note wait answer_wait),
             &Map.has_key?(args, &1)
           ),
         do: {:error, "nothing to change: pass at least one field"},
         else: {:ok, params}
    end
  end

  defp collect(keys, read, args, params) do
    Enum.reduce_while(keys, {:ok, params}, fn key, {:ok, acc} ->
      case read.(args, key) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        error -> {:halt, error}
      end
    end)
  end
end
