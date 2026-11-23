defmodule SlipdockWeb.MCP.Tools.ListCards do
  @moduledoc "Cards on a board, filtered the way `slipdock cards` filters them."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.{Args, Tools}
  alias SlipdockWeb.MCP.Tools.GetCard

  @max 200
  # A card in full carries every comment and checklist item, so a page of
  # them is far bigger than a page of lines.
  @full_default 20

  # What `Boards.Cards.list_cards/2` takes for each.
  @archived %{"exclude" => nil, "include" => "all", "only" => "true"}
  @snoozed ~w(exclude include only)

  @impl true
  def name, do: "list_cards"

  @impl true
  def title, do: "List cards"

  @impl true
  def description,
    do:
      "Cards on a board in brief, in list order, done lists left out unless include_done. " <>
        "Ready work: open, deps \"ready\", no_assignee in the ready list. full: as get_card. " <>
        "One page: truncated = more match; the rest is offset = next_offset."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        column: %{
          type: "string",
          description: "Only this list (name or id). A list not on the board is an error."
        },
        open: %{
          type: "boolean",
          description: "true: only cards not completed; false: only completed."
        },
        deps: %{
          type: "string",
          enum: keys(Config.deps()),
          description: "Dependency state; \"ready\" = nothing unfinished blocks it."
        },
        assignee: %{type: "string", description: "Email or name; \"me\" for yourself."},
        no_assignee: %{type: "boolean", description: "Only cards nobody is assigned to."},
        archived: %{
          type: "string",
          enum: Map.keys(@archived),
          description: "Archived cards: left out (exclude, the default), as well, or alone."
        },
        snoozed: %{
          type: "string",
          enum: @snoozed,
          description:
            "Snoozed cards (hidden until a date): left out (exclude, the default), as well, or alone."
        },
        due: %{type: "string", enum: keys(Config.dues())},
        tag: %{type: "string"},
        q: %{
          type: "string",
          description:
            "Words in the title or description; a card's id (123, #123) or link finds that card too."
        },
        stuck: %{type: "boolean", description: "Only cards past their list's usual stay."},
        driver: %{
          type: "string",
          enum: keys(Config.drivers()),
          description: "agent: an agent holds or last moved it; human: a person last moved it."
        },
        origin: %{
          type: "string",
          enum: keys(Slipdock.Origin.buckets()),
          description: "Who or what made it; none for cards made before origins were kept."
        },
        descriptions: %{
          type: "boolean",
          description: "Each card's description in its brief too (left out unless asked)."
        },
        include_done: %{
          type: "boolean",
          description: "Cards in the done and dropped lists too (left out unless asked for)."
        },
        full: %{
          type: "boolean",
          description:
            "Each card in full, as get_card returns it (comments, checklist, docs), " <>
              "instead of a line."
        },
        limit: %{
          type: "integer",
          description:
            "At most this many on the page (default 50, or #{@full_default} when full; " <>
              "max #{@max}). A truncated answer is one page, not the whole board: " <>
              "ask again with offset = next_offset for the rest."
        },
        offset: %{
          type: "integer",
          description:
            "Skip this many matching cards first (default 0): the answer's next_offset, " <>
              "to read the page after it."
        }
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, filters} <- filters(args, context.user),
         {:ok, opts} <- options(args),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :read)),
         :ok <- Boards.check_column(board, filters["column"]) do
      listed = Authorize.visible(auth, Boards.Cards.list_cards(board, filters))
      cards = leave_out_done(listed, board, filters, opts.all_done)
      {page, paging} = page(cards, opts)

      {:ok,
       %{
         board: %{id: board.id, code: board.code, name: board.name},
         cards: lines(board, page, context, opts)
       }
       |> Map.merge(paging)
       |> put_left_out(length(listed) - length(cards))
       |> Map.merge(V.paused(board))}
    end
  end

  # One page of the matching cards (#3654), and where the next one starts:
  # nil once this page reaches the end.
  defp page(cards, %{offset: offset, limit: limit}) do
    total = length(cards)
    next = offset + limit
    more = total > next

    {cards |> Enum.drop(offset) |> Enum.take(limit),
     %{total: total, offset: offset, truncated: more, next_offset: if(more, do: next)}}
  end

  defp options(args) do
    with {:ok, full} <- Args.boolean(args, "full", false),
         {:ok, all_done} <- Args.boolean(args, "include_done", false),
         {:ok, descriptions} <- Args.boolean(args, "descriptions", false),
         {:ok, limit} <- Args.limit(args, "limit", if(full, do: @full_default, else: 50), @max),
         {:ok, offset} <- Args.offset(args, "offset") do
      {:ok,
       %{
         full: full,
         all_done: all_done,
         descriptions: descriptions,
         limit: limit,
         offset: offset
       }}
    end
  end

  defp lines(board, page, context, %{full: true}), do: in_full(board, page, context)

  defp lines(_board, page, _context, opts),
    do: Enum.map(page, &Tools.card_brief(&1, descriptions: opts.descriptions))

  defp put_left_out(answer, 0), do: answer
  defp put_left_out(answer, n), do: Map.put(answer, :done_left_out, n)

  # The cards in done and dropped lists, unless the call asks for them (#3176):
  # include_done, a list named, or open = false (which asks for done cards).
  defp leave_out_done(cards, board, filters, all_done) do
    if all_done or filters["column"] != nil or filters["completed"] == "true" do
      cards
    else
      columns = Boards.Columns.board_columns(board)

      done =
        for col <- columns,
            Tools.GetBoard.done_list?(columns, col),
            into: MapSet.new(),
            do: col.id

      Enum.reject(cards, &MapSet.member?(done, &1.column_id))
    end
  end

  # What get_card answers, for each card, with the docs looked up in one go
  # rather than once a card.
  defp in_full(board, cards, context) do
    docs = Slipdock.Wiki.pages_for_cards(cards, context.user)
    ids = Enum.map(cards, & &1.id)
    waits = Boards.Waits.current_waits(ids)
    last_waits = Boards.Waits.last_waits(ids)
    findings = Slipdock.Findings.open_counts(ids)
    # What in each epic's tree waits on the caller (#2095), worked out once.
    tree = Slipdock.Work.Tree.for_board(context.user, board)

    board
    |> Boards.Cards.with_details(cards)
    |> Enum.map(fn card ->
      card
      |> V.card()
      |> Map.put(:docs, docs |> Map.get(card.id, []) |> Enum.map(&GetCard.doc/1))
      |> Map.put(:wait, V.wait(waits[card.id]))
      |> Map.put(:last_wait, V.wait(last_waits[card.id]))
      |> Map.put(:url, GetCard.url(card, context.base_url))
      |> Map.put(:rejection, Slipdock.Verified.rejection(card))
      |> Map.put(:findings, Map.get(findings, card.id, 0))
      # Who made it and changed it last (#2028), as get_card has it.
      |> V.put_authors(card)
      |> Map.put(
        :waiting_on_me,
        SlipdockWeb.API.WaitingJSON.entry(Slipdock.Work.Tree.of(tree, card.id))
      )
    end)
  end

  defp filters(args, user) do
    with {:ok, column} <- Args.optional(args, "column"),
         {:ok, open} <- Args.boolean(args, "open"),
         {:ok, deps} <- bucket(args, "deps", Config.deps()),
         {:ok, due} <- bucket(args, "due", Config.dues()),
         {:ok, assignee} <- Args.optional(args, "assignee"),
         {:ok, nobody} <- Args.boolean(args, "no_assignee", false),
         {:ok, tag} <- Args.optional(args, "tag"),
         {:ok, q} <- Args.optional(args, "q"),
         {:ok, archived} <- archived(args),
         {:ok, snoozed} <- snoozed(args),
         {:ok, stuck} <- Args.boolean(args, "stuck", false),
         {:ok, driver} <- bucket(args, "driver", Config.drivers()),
         {:ok, origin} <- bucket(args, "origin", Slipdock.Origin.buckets()) do
      assignee =
        cond do
          nobody -> "none"
          Enum.member?(~w(me myself mine), assignee) -> user.email
          true -> assignee
        end

      filters =
        %{
          "column" => column,
          "completed" => if(is_boolean(open), do: to_string(not open)),
          "deps" => deps,
          "due" => due,
          "assignee" => assignee,
          "tag" => tag,
          "q" => q,
          "archived" => archived,
          "snoozed" => snoozed,
          "stuck" => if(stuck, do: "true"),
          "driver" => driver,
          "origin" => origin
        }
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()

      {:ok, filters}
    end
  end

  defp archived(args) do
    with {:ok, value} <- Args.optional(args, "archived") do
      case Map.fetch(@archived, value || "exclude") do
        {:ok, filter} -> {:ok, filter}
        :error -> {:error, "archived must be one of: exclude, include, only"}
      end
    end
  end

  defp snoozed(args) do
    with {:ok, value} <- Args.optional(args, "snoozed") do
      if Enum.member?([nil | @snoozed], value),
        do: {:ok, value},
        else: {:error, "snoozed must be one of: exclude, include, only"}
    end
  end

  # A value that isn't one of the buckets would be quietly ignored by
  # `Boards.Cards.list_cards/2`, handing back everything as if it were the answer.
  defp bucket(args, key, allowed) do
    with {:ok, value} <- Args.optional(args, key) do
      cond do
        is_nil(value) -> {:ok, nil}
        Enum.member?(keys(allowed), value) -> {:ok, value}
        true -> {:error, "#{key} must be one of: #{Enum.join(keys(allowed), ", ")}"}
      end
    end
  end

  defp keys(buckets), do: buckets |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == ""))
end
