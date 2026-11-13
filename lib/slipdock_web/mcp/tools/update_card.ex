defmodule SlipdockWeb.MCP.Tools.UpdateCard do
  @moduledoc """
  Changes a card's fields, flags, tags and assignees, what blocks it, its
  checklist and whether it repeats. All of it lands or none of it does.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias Slipdock.Boards.CardEdits
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.{Args, Tools, WaitingList}

  @fields ~w(title short_name description priority due_date start_date percent_complete bar paths profile color border_top
             border_right border_bottom border_left caused_by missed_by)
  @lists ~w(add_flags remove_flags add_tags remove_tags assignees add_assignees remove_assignees)
  @id_lists ~w(add_blocked_by remove_blocked_by check_items uncheck_items)

  @impl true
  def name, do: "update_card"

  @impl true
  def title, do: "Update a card"

  @impl true
  def description,
    do:
      "Changes a card: title, description, priority, dates, percent_complete, " <>
        "colours, flags (blocked, waiting, review), tags, assignees, blockers, incident, " <>
        "checklist (item ids from get_card), recurrence, snoozed_until. Only what you " <>
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
        short_name: %{
          type: "string",
          description: "At most 40 characters, for tight spaces. \"\" hands it back to be made."
        },
        description: %{type: "string", description: "Replaces the whole description."},
        priority: %{type: "string", enum: ["none", "low", "medium", "high", "critical"]},
        due_date: %{type: "string", description: "YYYY-MM-DD; \"\" clears it."},
        start_date: %{type: "string", description: "YYYY-MM-DD; \"\" clears it."},
        percent_complete: %{type: "integer", minimum: 0, maximum: 100},
        bar: %{
          type: "string",
          description: "What done means for it; locks when work starts, where the board asks."
        },
        # The caller's own Waiting on you (#2069).
        waiting_list: WaitingList.property(card: true),
        paths: %{
          type: "array",
          items: %{type: "string"},
          description:
            "Globs of the files its work touches (lib/x/**); [] clears. On a lanes board an " <>
              "agent can't start a card whose paths overlap one in progress."
        },
        # What kind of change it is (#1951).
        profile: %{
          type: "string",
          enum: Slipdock.Profiles.names() ++ [""],
          description:
            "What kind of change it is: security, schema, feature, fix, docs or spike; \"\" " <>
              "clears it. Inferred when an agent starts it on a board with profiles on."
        },
        # An incident (#1946): what shipped it and which check missed it.
        caused_by: %{
          type: ["integer", "null"],
          description:
            "This card is an incident: the id of the card whose shipping caused it, on any " <>
              "board you can read. null clears it."
        },
        missed_by: %{
          type: ["string", "null"],
          enum: Slipdock.Boards.Card.layers() ++ [nil],
          description:
            "The check that should have caught the incident: bar, rules, ci, verify, audit " <>
              "or none. With caused_by it records a process finding (source incident) on " <>
              "the causing card. null clears it."
        },
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
              "withdraws the open wait (a moot one: with wait_reason, which another agent's " <>
              "wait needs). A runner job's session links its job by itself.",
          properties: %{
            needs: %{
              type: "string",
              description:
                "What you need, as one question in Markdown: each option and what it means, " <>
                  "and the one you recommend; or the line before questions."
            },
            questions:
              Map.put(
                list,
                :description,
                "Several questions: one each, asked as a numbered series with an answer " <>
                  "box each. Use this, not a block of questions in needs."
              ),
            on: %{
              type: "string",
              description: "Who it waits on: email or \"me\"; omit to route it by question."
            },
            question: %{
              type: "string",
              enum: Slipdock.WaitRoutes.kinds(),
              description:
                "What kind of question: the board routes each kind to a person (default other)."
            },
            choices: Map.put(list, :description, "Answers to pick from, if it is a choice."),
            default: %{
              type: "integer",
              minimum: 1,
              description:
                "The choice you propose, by number: the one-click answer, and what stands " <>
                  "after the board's wait_default_after on an approval (kind other) wait."
            },
            job_id: %{type: "integer", description: "Your runner job on this card, if any."}
          },
          additionalProperties: false
        },
        wait_reason: %{
          type: "string",
          description:
            "With wait: null, why the wait is withdrawn (moot: answered elsewhere, the bar " <>
              "or description edited, the cited rule in place). Needed for a wait you didn't open."
        },
        answer_wait: %{
          type: "object",
          description:
            "Answers the card's open wait, as a comment from you. Not one you opened yourself.",
          properties: %{
            answers:
              Map.put(list, :description, "One answer per question, in order; \"\" skips one."),
            answer: %{type: "string"},
            skip: %{
              type: "boolean",
              description: "Skip all the questions unanswered and move the card on."
            },
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
    case WaitingList.action(args, "card") do
      :no ->
        update(args, context)

      {:ok, action} ->
        with {:ok, id} <- Args.id(args, "card"),
             do: WaitingList.card(Args.auth(context), id, action)

      error ->
        error
    end
  end

  defp update(args, context) do
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
      card = if wait_op == :untouched, do: card, else: Boards.Cards.get_card!(card.id)
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
      {{:ok, _}, {:ok, _}} ->
        {:error, "pass wait or answer_wait, not both"}

      {{:ok, nil}, :error} ->
        with {:ok, reason} <- Args.optional(args, "wait_reason"),
             do: {:ok, {:withdraw, reason}}

      {{:ok, %{} = wait}, :error} ->
        {:ok, {:open, wait}}

      {{:ok, _}, :error} ->
        {:error, "wait is an object ({needs: \"…\"} or {questions: […]}) or null"}

      {:error, {:ok, %{} = answer}} ->
        {:ok, {:answer, answer}}

      {:error, {:ok, _}} ->
        {:error, "answer_wait is an object ({answer: \"…\"} or {choice: 1})"}

      {:error, :error} ->
        {:ok, :untouched}
    end
  end

  defp write_wait(_auth, _card, :untouched), do: {:ok, nil}

  defp write_wait(auth, card, {:withdraw, reason}),
    do: Args.refusal(CardWrites.withdraw_wait(auth, card, %{"reason" => reason}))

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

  # The checks are all done above; the write is the context's (#2790), all
  # of it or none.
  defp write(auth, card, params, blockers, unblockers, to_check, to_uncheck, {recurrence, snooze}) do
    fields = Map.drop(params, @id_lists ++ ["add_checklist"])

    edit = %{
      fields: if(map_size(fields) > 0, do: &CardWrites.update(auth, &1, fields)),
      recurrence: recurrence,
      snooze: snooze,
      add_blockers: blockers,
      remove_blockers: unblockers,
      add_checklist: params["add_checklist"] || [],
      check: to_check,
      uncheck: to_uncheck
    }

    Args.refusal(CardEdits.edit(card, edit, by: auth.assigns.current_user))
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
