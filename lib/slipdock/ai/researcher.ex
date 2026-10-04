defmodule Slipdock.AI.Researcher do
  @moduledoc """
  The assistant behind `/ask`: a conversation about *everything* a person can
  see, rather than the page in front of them.

  `Slipdock.AI.Assistant` works by being handed the current view as text, which
  is exactly right for "what's overdue here" and useless for "where did we
  land on the Stripe migration" — the answer is on a board nobody is looking
  at. So this one is given no boards at all. It is given tools, and it goes
  and finds them:

    * `search_cards` — semantic search (`Slipdock.Search`) over every card,
      comment and status update the asker may read
    * `read_card` — one card in full, once a search has named it
    * `list_cards` — the cards on a board, by list, with counts, and filtered
      the way the board's own views filter (overdue, blocked, a person's, a
      tag's): the questions ranked search cannot answer
    * `list_boards` — the boards the asker can see, and their lists
    * `read_board` — one board's furniture: lists, tags, people, milestones
    * `assigned_cards` — one person's work across every board and level
    * `recent_activity` — what actually happened, from the activity log,
      with the comments and status updates written in the period
    * `alerts` — what the boards' own automations have raised for the asker

  Two things are worth knowing about counting. Cards nest: a card on a board
  can have a sub-board of its own beneath it, so `list_cards` takes a `depth`
  and says which it counted — a total that quietly means "top-level only" is
  worse than no total at all. And a filter means the same thing here as in a
  swimlane, because both go through `Slipdock.Swimlanes`.

  The loop runs until the model answers in prose or `@max_rounds` tool calls
  have gone by, whichever comes first. Every tool is executed with the asking
  user as its scope, so the model cannot reach anything the person could not
  open themselves — there is no privileged path through here.

  What came back is returned alongside the answer as `:sources`, because an
  answer assembled from four cards on three boards is worth very little if
  the reader can't go and check it.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Slipdock.{Access, AI, Automations, Boards, Rollup, Search, Work}
  alias Slipdock.AI.Context
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Column, StatusUpdate}
  alias Slipdock.Repo

  @history_limit 10
  # Enough for a search, a follow-up search and a couple of card reads, plus
  # room for the listing tools to be tried in turn. A model that hasn't
  # answered by then is going round in circles, and the partial answer is
  # better than another minute of waiting.
  @max_rounds 8
  @search_limit 12
  # Cards written out in full by `list_cards` before it falls back to counts
  # alone. The counts are always exact; it is the lines that cost tokens.
  @list_limit 60
  # Entries `recent_activity` returns at most, and how far back it looks when
  # the model doesn't say.
  @activity_limit 40
  @activity_days 7
  # How deep `list_cards` will walk sub-boards when asked for "all".
  @max_depth 6
  # Cheap models now and then return a turn with neither prose nor a tool
  # call. `Slipdock.AI.complete/2` retries once for the same reason; asking
  # again almost always settles it, and it is far better than telling
  # someone their question failed.
  @empty_retries 2

  @prompt """
  You are the assistant inside a kanban / project-planning app, answering questions about everything the user can see: every board, card, comment, status update and wiki page they have access to.

  You start out knowing nothing about their work. Use the tools to find out:

  - `search_cards` searches by meaning, not by keyword, across cards, comments and status updates. Ask it the way the user asked you. If the first search misses, try again with different words rather than giving up — "blocked on the vendor" and "waiting for the supplier contract" are the same question to it.
  - `read_card` gives you one card in full: description, checklist, every comment, every status update, subcards, dependencies. Search results are snippets; read the card before saying anything detailed about it.
  - `list_cards` lists what is actually on a board, list (column) by list, with an exact count for each, and filters the way the board's own views do: `due` (overdue, today, week, month, none), `deps` (blocked, ready, blocking), `assignee`, `priority`, `tag`, `flag`, `completed`. Search ranks by meaning and returns only its best matches, so it can never tell you *how many* of anything there are — use `list_cards` for "how many", "what's in the To do list", "what's overdue", "what's blocked", and for any counting or completeness.
  - `list_boards` tells you what boards exist, with their lists, when you need to narrow a search or the user names a board you haven't seen.
  - `read_board` describes one board: its lists, the tags and people available on it, its milestones and its custom fields. Read it before using a tag or a person's name you haven't seen.
  - `assigned_cards` is one person's work: every card assigned to them, across every board and every level, grouped by when it is due. Use it for "what am I meant to be doing", "what's on Jess's plate", "what have I got this week".
  - `recent_activity` is what actually happened: cards created, moved and completed, comments written, status reported, in a date range. Use it for "what changed this week", "what's happened since Friday", "where did we get to". Searching cannot answer these — the index has no idea when anything happened.
  - `alerts` is what the boards' automations have raised for this person and they haven't dismissed.
  - `search_pages` searches the **wiki** by meaning: the Markdown pages kept on each board for how something works, what was decided and why. The board says what is being done; the wiki says why it is done that way. Reach for it when the question is "how does X work", "what did we decide about X", "is there a runbook for X", or when a card's comments plainly refer to a document.
  - `read_page` gives you one page in full. Search returns sections; read the page before quoting it.
  - `list_pages` lists a board's wiki as a tree, so you can see what has been written down at all.

  **When a card and a page disagree, say so rather than choosing.** A page is what somebody wrote once; a card is what is happening now.

  **Cards nest.** A card can have a sub-board of subcards beneath it: an epic with its tasks. `list_cards` covers one board's own cards unless you pass `depth` (a number, or "all"), and its answer always says which it counted. When a question is about totals — "how many cards do I have" — pass `depth: "all"`, or say plainly that you counted the top level only.

  Pick the tool that answers the question rather than searching by reflex: a count needs `list_cards`, a person's workload needs `assigned_cards`, "what changed" needs `recent_activity`. Search first, answer second, and never answer from memory of earlier turns alone when the question is about the current state of the work. Never say you cannot see something without trying the tool that would show it.

  Write the answer in Markdown: short paragraphs or bullets, no headings. Refer to cards by their title and board ("Ship v2 billing, on Product Launch"), never by their # id. Be specific — quote what a comment actually said, give the date, name the person — and say plainly when the search turned up nothing rather than filling the gap. Never invent a card, a date or an event.

  Today's date is %{today}.

  You cannot change anything. If asked to, say so, and point the user at the Edit mode of the assistant on a board page.
  """

  @tools [
    %{
      type: "function",
      function: %{
        name: "search_cards",
        description:
          "Search every card, comment and status update the user can see, by meaning. " <>
            "Returns matching cards with the snippets that matched.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{
              type: "string",
              description:
                "What to look for, in natural language. Describe the thing, not keywords."
            },
            board: %{
              type: "string",
              description:
                "Optional board name or code to restrict the search to. Leave out to search everything."
            },
            include_archived: %{
              type: "boolean",
              description: "Include archived cards. Defaults to false."
            }
          },
          required: ["query"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "search_pages",
        description:
          "Search the wiki — the Markdown pages kept on each board — by meaning. Use it for " <>
            "\"how does X work\", \"what did we decide about X\", \"is there a runbook for X\". " <>
            "Returns matching pages with the sections that matched.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{
              type: "string",
              description: "What to look for, in the user's own words."
            },
            board: %{
              type: "string",
              description: "Optional board name or code, to search one board's wiki only."
            }
          },
          required: ["query"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "read_page",
        description:
          "Read one wiki page in full, with its live queries and card references resolved.",
        parameters: %{
          type: "object",
          properties: %{
            page: %{
              type: "string",
              description: "The page's code (like W-31), its id, or board-code/slug."
            }
          },
          required: ["page"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "list_pages",
        description:
          "List a board's wiki as a tree of page titles, so you can see what has been " <>
            "written down at all.",
        parameters: %{
          type: "object",
          properties: %{
            board: %{type: "string", description: "Board name or code."}
          },
          required: ["board"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "read_card",
        description:
          "Read one card in full: description, checklist, comments, status updates, subcards and dependencies.",
        parameters: %{
          type: "object",
          properties: %{
            card_id: %{type: "integer", description: "The card's id, as given by search_cards."}
          },
          required: ["card_id"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "list_cards",
        description:
          "List the cards on a board in list (column) order, with an exact count for every " <>
            "list, filtered the way the board's own views filter. Use this for counting, for " <>
            "\"what is in this list\", for overdue or blocked or one person's cards, and for " <>
            "any question needing everything rather than the best matches. Counts the board's " <>
            "own cards unless you pass depth, and always says which it counted.",
        parameters: %{
          type: "object",
          properties: %{
            board: %{
              type: "string",
              description: "Board name or code. Leave out to cover every board the user can see."
            },
            column: %{
              type: "string",
              description: "Optional list (column) name to restrict to, such as \"To do\"."
            },
            priority: %{
              type: "string",
              description: "Optional: none, low, medium, high or critical."
            },
            tag: %{type: "string", description: "Optional tag name."},
            flag: %{
              type: "string",
              description: "Optional flag: flagged, blocked, review, waiting or starred."
            },
            completed: %{
              type: "boolean",
              description: "Optional: true for finished cards only, false for unfinished only."
            },
            q: %{
              type: "string",
              description: "Optional words that must appear in the title or description."
            },
            archived: %{
              type: "boolean",
              description:
                "List the archived cards instead of the active ones. Defaults to false."
            },
            due: %{
              type: "string",
              enum: ["overdue", "today", "week", "month", "has", "none"],
              description:
                "Optional date filter: overdue, today, week (next 7 days), month (next 30), " <>
                  "has (any due date) or none (no due date). Completed cards are in none of " <>
                  "the date buckets, so \"overdue\" means still outstanding."
            },
            deps: %{
              type: "string",
              enum: ["blocked", "ready", "blocking", "violated", "free"],
              description:
                "Optional dependency filter: blocked (waiting on an unfinished card), ready, " <>
                  "blocking (others wait on it), violated (its dates conflict with a " <>
                  "blocker's) or free."
            },
            assignee: %{
              type: "string",
              description:
                "Optional: a person's name or email, or \"none\" for the cards nobody owns. " <>
                  "For everything one person owns across all boards, use assigned_cards."
            },
            depth: %{
              type: "string",
              description:
                "How far down the sub-boards to count: \"1\" (the default) is the board's own " <>
                  "cards, \"2\" adds the subcards beneath them, \"all\" walks the whole tree. " <>
                  "Use \"all\" for totals."
            }
          }
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "read_board",
        description:
          "Describe one board: its lists in order, the tags and people available on it, its " <>
            "milestones and its custom fields. Read this before using a tag name, a list " <>
            "name or a person you have not seen. It does not list cards — list_cards does.",
        parameters: %{
          type: "object",
          properties: %{
            board: %{type: "string", description: "Board name or code."}
          },
          required: ["board"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "assigned_cards",
        description:
          "One person's work: every card assigned to them across every board and every " <>
            "level, grouped by when it is due (overdue, today, next 7 days, later, no date). " <>
            "Use it for what someone is meant to be doing.",
        parameters: %{
          type: "object",
          properties: %{
            person: %{
              type: "string",
              description: "A name or email, or \"me\" for the person asking. Defaults to them."
            },
            board: %{
              type: "string",
              description: "Optional board name or code, to keep to one board's tree."
            },
            include_done: %{
              type: "boolean",
              description: "Include finished cards. Defaults to false."
            }
          }
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "recent_activity",
        description:
          "What happened, newest first: cards created, moved, completed, dated and archived, " <>
            "with the comments and status updates written in the period. This is the only " <>
            "way to answer questions about when something happened or what changed — the " <>
            "search index has no sense of time.",
        parameters: %{
          type: "object",
          properties: %{
            board: %{
              type: "string",
              description:
                "Optional board name or code (its sub-boards included). Leave out for every " <>
                  "board the user can see."
            },
            since: %{
              type: "string",
              description: "Start date, YYYY-MM-DD. Defaults to 7 days ago."
            },
            until: %{type: "string", description: "End date, YYYY-MM-DD. Defaults to today."},
            limit: %{
              type: "integer",
              description: "How many entries at most, newest first. Defaults to 40."
            }
          }
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "alerts",
        description:
          "The alerts the boards' own automation rules have raised for this person and they " <>
            "have not dismissed, most urgent first.",
        parameters: %{type: "object", properties: %{}}
      }
    },
    %{
      type: "function",
      function: %{
        name: "list_boards",
        description: "List the boards the user can see, with their codes and card counts.",
        parameters: %{type: "object", properties: %{}}
      }
    }
  ]

  @doc """
  Answers `message` for `user`, searching as needed.

  `history` is the conversation so far as maps with `:role` and `:content`.
  Returns `{:ok, %{reply: markdown, sources: [%{card:, board:, why:}], searches: [query]}}`
  or `{:error, message}`.
  """
  @spec ask(User.t(), [map], String.t(), keyword) :: {:ok, map} | {:error, String.t()}
  def ask(%User{} = user, history, message, opts \\ []) do
    system = String.replace(@prompt, "%{today}", Date.to_string(Date.utc_today()))
    # The key is the asker's own (see `Slipdock.AI.api_key/1`).
    opts = Keyword.put_new(opts, :user, user)

    messages =
      [%{"role" => "system", "content" => system}] ++
        recent(history) ++ [%{"role" => "user", "content" => message}]

    loop(
      user,
      messages,
      %{sources: %{}, searches: [], retries: @empty_retries},
      @max_rounds,
      opts
    )
  end

  defp loop(_user, _messages, state, 0, _opts) do
    {:ok,
     %{
       reply:
         "I searched several times without settling on an answer. Try asking in a narrower way — naming the board, or the period you mean.",
       sources: sources(state),
       searches: Enum.reverse(state.searches)
     }}
  end

  defp loop(user, messages, state, rounds, opts) do
    case AI.complete_tools(messages, @tools, opts) do
      {:ok, %{"tool_calls" => calls} = message} when is_list(calls) and calls != [] ->
        {results, state} = Enum.map_reduce(calls, state, &run_tool(user, &1, &2))

        loop(user, messages ++ [message] ++ results, state, rounds - 1, opts)

      {:ok, %{"content" => content}} when is_binary(content) and content != "" ->
        {:ok, %{reply: content, sources: sources(state), searches: Enum.reverse(state.searches)}}

      {:ok, message} ->
        if state.retries > 0 do
          Logger.info("Researcher got an empty turn; asking again")
          loop(user, messages, %{state | retries: state.retries - 1}, rounds - 1, opts)
        else
          Logger.warning("Researcher gave up on empty turns: #{inspect(message)}")
          {:error, "The model returned an empty answer; please try again."}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Tools --------------------------------------------------------------------

  defp run_tool(user, %{"id" => id, "function" => %{"name" => name} = fun}, state) do
    args = decode_args(fun["arguments"])
    {text, state} = call(user, name, args, state)

    {%{"role" => "tool", "tool_call_id" => id, "name" => name, "content" => text}, state}
  end

  defp run_tool(_user, call, state) do
    Logger.warning("Ignoring malformed tool call: #{inspect(call)}")
    {%{"role" => "tool", "tool_call_id" => "unknown", "content" => "Malformed tool call."}, state}
  end

  defp call(user, "search_cards", args, state) do
    query = to_string(args["query"] || "")

    opts =
      [limit: @search_limit, archived: args["include_archived"] == true, kind: :card]
      |> put_board(user, args["board"])

    case Search.search(user, query, opts) do
      {:ok, []} ->
        {"No cards matched “#{query}”.", %{state | searches: [query | state.searches]}}

      {:ok, results} ->
        state = %{
          state
          | searches: [query | state.searches],
            sources: remember(state.sources, results, query)
        }

        {render_results(results), state}

      {:error, reason} ->
        {"The search failed: #{reason}", state}
    end
  end

  defp call(user, "read_card", args, state) do
    case card_id(args["card_id"]) do
      nil ->
        {"read_card needs a numeric card_id.", state}

      id ->
        case readable_card(user, id) do
          nil ->
            {"There is no card ##{id} you can see.", state}

          card ->
            board = Repo.preload(card.board, [:columns, :fields])
            {Context.card_text(card, board), state}
        end
    end
  end

  defp call(user, "list_boards", _args, state) do
    boards = Access.list_boards(user, archived: :all)

    text =
      case boards do
        [] ->
          "You have no boards."

        boards ->
          Enum.map_join(boards, "\n", fn b ->
            cards = if is_list(b.cards), do: length(b.cards), else: 0
            archived = if b.archived_at, do: " (archived)", else: ""
            lists = Enum.map_join(board_columns(b), ", ", & &1.name)

            "- #{b.name} [#{b.code}] — #{cards} active cards#{archived}" <>
              if(lists == "", do: "", else: "; lists: #{lists}")
          end)
      end

    {text, state}
  end

  defp call(user, "list_cards", args, state) do
    board_ref = trimmed(args["board"])
    column_ref = trimmed(args["column"])

    roots =
      case board_ref do
        nil -> Access.list_boards(user, archived: :all)
        ref -> List.wrap(find_board(user, ref))
      end

    cond do
      roots == [] and is_binary(board_ref) ->
        {"There is no board called “#{board_ref}” that you can see. " <> board_hint(user), state}

      roots == [] ->
        {"You have no boards.", state}

      true ->
        case depth_arg(args["depth"]) do
          {:error, text} ->
            {text, state}

          {:ok, depth} ->
            listings =
              roots
              |> Enum.flat_map(&tree(&1, depth))
              |> Enum.map(fn {board, path} ->
                listing(board, path, list_filters(args), column_ref)
              end)

            if column_ref && Enum.all?(listings, &(&1.columns == [])) do
              {"No list called “#{column_ref}” on " <>
                 Enum.map_join(roots, ", ", & &1.name) <> ". " <> lists_hint(listings), state}
            else
              listings = allocate(listings, @list_limit)
              why = list_label(board_ref, column_ref)

              {render_listings(listings, args, depth),
               %{state | sources: remember_cards(state.sources, listings, why)}}
            end
        end
    end
  end

  defp call(user, "read_board", args, state) do
    ref = trimmed(args["board"])

    case ref && find_board(user, ref) do
      nil ->
        {"There is no board called “#{ref || ""}” that you can see. " <> board_hint(user), state}

      board ->
        {board_text(Boards.get_board!(board.id)), state}
    end
  end

  defp call(user, "assigned_cards", args, state) do
    with {:ok, person} <- find_person(user, args["person"]),
         {:ok, board} <- optional_board(user, trimmed(args["board"])) do
      all = Work.assigned(person, user, board_id: board && board.id)
      done? = args["include_done"] == true
      items = if done?, do: all, else: Enum.reject(all, &(&1.section == :done))
      shown = Enum.take(items, @list_limit)
      why = "assigned to #{User.display_name(person)}"

      {render_work(
         person,
         board,
         items,
         shown,
         if(done?, do: nil, else: length(all) - length(items))
       ), %{state | sources: remember_plain(state.sources, Enum.map(shown, & &1.card), why)}}
    else
      {:error, text} -> {text, state}
    end
  end

  defp call(user, "recent_activity", args, state) do
    today = Date.utc_today()

    with {:ok, from} <- date_arg(args["since"], Date.add(today, -@activity_days)),
         {:ok, to} <- date_arg(args["until"], today),
         {:ok, board} <- optional_board(user, trimmed(args["board"])) do
      board_ids =
        case board do
          nil -> Access.readable_board_ids(user)
          board -> board |> tree(@max_depth) |> Enum.map(fn {b, _path} -> b.id end)
        end

      limit = limit_arg(args["limit"], @activity_limit)
      {entries, total} = activity(board_ids, from, to, limit)

      {render_activity(entries, total, board, from, to), state}
    else
      {:error, text} -> {text, state}
    end
  end

  defp call(user, "alerts", _args, state) do
    case Automations.list_alerts(user) do
      [] ->
        {"No alerts: the boards' automation rules have raised nothing you haven't dismissed.",
         state}

      alerts ->
        text =
          Enum.map_join(alerts, "\n", fn a ->
            "- [#{a.severity}] #{a.title}" <>
              if(a.body in [nil, ""], do: "", else: " — #{snippet(a.body)}") <>
              " (#{a.board && a.board.name}" <>
              if(a.card, do: ", on “#{a.card.title}”", else: "") <>
              ", raised #{fmt_at(a.inserted_at)})"
          end)

        {"#{length(alerts)} alert(s), most urgent first:\n" <> text, state}
    end
  end

  ## The wiki ----------------------------------------------------------------

  defp call(user, "search_pages", args, state) do
    query = to_string(args["query"] || "")
    opts = [limit: @search_limit, kind: :page] |> put_board(user, args["board"])

    case Search.search(user, query, opts) do
      {:ok, []} ->
        {"No wiki pages matched “#{query}”. The board may simply have nothing written about it.",
         %{state | searches: [query | state.searches]}}

      {:ok, results} ->
        state = %{
          state
          | searches: [query | state.searches],
            sources: remember_pages(state.sources, results, query)
        }

        {render_page_results(results), state}

      {:error, reason} ->
        {"The search failed: #{reason}", state}
    end
  end

  defp call(user, "read_page", args, state) do
    case Slipdock.Wiki.find_page(to_string(args["page"] || "")) do
      {:ok, page} ->
        if Slipdock.Wiki.visible?(page, Slipdock.Access.page_permission(user, page)) do
          board = Slipdock.Wiki.board_of(page)

          text =
            SlipdockWeb.Wiki.Renderer.to_markdown(page.body, page: page, board: board, as: user)

          body = """
          #{page.code} “#{page.title}” — #{board.name} › wiki#{if page.summary, do: "\n#{page.summary}"}
          Last edited #{Date.to_iso8601(DateTime.to_date(page.updated_at))}.

          #{text}
          """

          {body,
           %{
             state
             | sources: remember_plain_pages(state.sources, [%{page | board: board}], "read_page")
           }}
        else
          {"There is no page you can read called #{inspect(args["page"])}.", state}
        end

      _ ->
        {"There is no page called #{inspect(args["page"])}.", state}
    end
  end

  defp call(user, "list_pages", args, state) do
    case find_board(user, to_string(args["board"] || "")) do
      {:ok, board} ->
        case Slipdock.Wiki.tree(board, status: "published") do
          [] ->
            {"#{board.name} has no wiki pages yet.", state}

          tree ->
            {"The wiki of #{board.name}:\n" <> render_page_tree(tree, 0), state}
        end

      _ ->
        {"There is no board called #{inspect(args["board"])}.", state}
    end
  end

  defp call(_user, name, _args, state), do: {"There is no tool called #{name}.", state}

  ## Rendering ----------------------------------------------------------------

  # What the model reads back from a search: enough to decide which card to
  # open, and no more. Snippets are cut hard — the whole point of `read_card`
  # is that the model asks for the full text when it needs it.
  defp render_results(results) do
    Enum.map_join(results, "\n\n", fn %{card: card, matches: matches} ->
      header =
        "##{card.id} “#{card.title}” — #{board_name(card)} › #{column_name(card)}" <>
          facets(card)

      snippets =
        matches
        |> Enum.take(3)
        |> Enum.map_join("\n", fn m ->
          "  · [#{Slipdock.Search.Embedding.label(m.kind)}] #{snippet(m.body)}"
        end)

      header <> "\n" <> snippets
    end)
  end

  # A page result names the page and the sections that matched, so the model
  # can decide whether to read the whole thing.
  defp render_page_results(results) do
    Enum.map_join(results, "\n\n", fn %{page: page, matches: matches} ->
      header =
        "#{page.code} “#{page.title}” — #{page.board.name} › wiki" <>
          if(page.summary, do: " — #{page.summary}", else: "")

      snippets =
        matches
        |> Enum.take(3)
        |> Enum.map_join("\n", fn m ->
          label = if m.section == "", do: "page", else: m.section
          "  · [#{label}] #{snippet(m.body)}"
        end)

      header <> "\n" <> snippets
    end)
  end

  defp render_page_tree(nodes, depth) do
    Enum.map_join(nodes, "\n", fn %{page: page, children: children} ->
      line =
        String.duplicate("  ", depth) <>
          "- #{page.code} #{page.title}" <> if(page.summary, do: " — #{page.summary}", else: "")

      case children do
        [] -> line
        _ -> line <> "\n" <> render_page_tree(children, depth + 1)
      end
    end)
  end

  # One block per board: the board, then each of its lists with an exact
  # count, then the cards themselves until the budget runs out.
  # The header has to be honest about what was counted: a board's own cards,
  # or those plus everything on the sub-boards beneath them.
  defp render_listings(listings, args, depth) do
    {own, beneath} = Enum.split_with(listings, &(&1.level == 1))
    own_count = count(own)
    beneath_count = count(beneath)
    total = own_count + beneath_count
    filters = filters_line(args)
    matching = if filters == "", do: "", else: " matching #{filters}"

    header =
      if depth == 1 do
        "#{own_count} top-level #{cards_word(own_count)}#{matching} " <>
          "(the cards on the boards themselves)." <> subcard_note(own)
      else
        "#{total} #{cards_word(total)}#{matching} to depth #{depth}: " <>
          "#{own_count} on the boards themselves, #{beneath_count} on the sub-boards beneath."
      end

    Enum.join([header | Enum.map(listings, &render_listing/1)], "\n\n")
  end

  defp count(listings), do: Enum.sum(Enum.map(listings, &length(&1.cards)))

  # Said once, and only when there is something down there to miss.
  defp subcard_note(listings) do
    beneath =
      listings
      |> Enum.flat_map(& &1.cards)
      |> Enum.map(&Card.progress/1)
      |> Enum.filter(&is_tuple/1)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    if beneath > 0,
      do:
        " Not counted: #{beneath} subcards beneath them — pass depth (a number, or \"all\") to include those.",
      else: ""
  end

  defp render_listing(%{board: board, path: path, columns: columns, cards: cards, shown: shown}) do
    shown_ids = MapSet.new(shown, & &1.id)
    by_column = Enum.group_by(cards, & &1.column_id)

    lines =
      Enum.map(columns, fn column ->
        in_column = Map.get(by_column, column.id, [])
        {listed, hidden} = Enum.split_with(in_column, &MapSet.member?(shown_ids, &1.id))

        [
          "  #{column.name} — #{length(in_column)} #{cards_word(length(in_column))}",
          Enum.map(listed, &("    - " <> Context.card_line(&1, board))),
          hidden != [] && "    … and #{length(hidden)} more not listed"
        ]
        |> List.flatten()
        |> Enum.filter(&is_binary/1)
      end)

    ["#{board_label(board, path)} — #{length(cards)} #{cards_word(length(cards))}" | lines]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp board_label(board, path) do
    code = if board.code in [nil, ""], do: "", else: " [#{board.code}]"
    archived = if board.archived_at, do: " (archived board)", else: ""

    if board.parent_card_id,
      do: "#{path} (sub-board)",
      else: "#{path}#{code}#{archived}"
  end

  defp cards_word(1), do: "card"
  defp cards_word(_), do: "cards"

  # Dates are written the way a person writes them, in the model's own
  # answer as much as here: "22 Sep 2026", never a bare ISO string.
  defp fmt(%Date{} = date), do: Calendar.strftime(date, "%a %-d %b %Y")
  defp fmt(other), do: to_string(other)
  defp fmt_at(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y")
  defp fmt_at(other), do: to_string(other)

  defp facets(%Card{} = card) do
    [
      card.completed && "done",
      card.priority not in [nil, "none"] && "priority #{card.priority}",
      card.due_date && "due #{card.due_date}",
      card.archived_at && "archived"
    ]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> ""
      parts -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end

  @snippet_cap 400
  defp snippet(body) do
    body
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @snippet_cap)
  end

  defp board_name(%Card{board: %{name: name}}), do: name
  defp board_name(_), do: "unknown board"

  defp column_name(%Card{column: %{name: name}}), do: name
  defp column_name(_), do: "unknown list"

  ## Work, activity and boards -----------------------------------------------

  # One person's cards, in the sections the My work page uses, each with the
  # path of the board and cards above it.
  defp render_work(person, board, items, shown, finished) do
    shown_ids = MapSet.new(shown, & &1.card.id)
    where = if board, do: " on #{board.name}", else: " across every board"

    # `finished` is nil when completed cards were asked for, and otherwise
    # how many were left out — which is a different sentence.
    kind =
      if is_nil(finished),
        do: cards_word(length(items)),
        else: "unfinished #{cards_word(length(items))}"

    # Saying "0 cards" when the truth is "0 unfinished, 74 done" invites
    # exactly the wrong answer: that nothing is assigned to them at all.
    note =
      if is_integer(finished) and finished > 0,
        do:
          " #{finished} completed #{cards_word(finished)} #{if finished == 1, do: "is", else: "are"} " <>
            "assigned to them as well, not listed here — pass include_done for those.",
        else: ""

    header =
      "#{length(items)} #{kind} assigned to " <>
        "#{User.display_name(person)} <#{person.email}>#{where}, by when they are due." <> note

    if items == [] do
      header
    else
      sections =
        items
        |> Work.group()
        |> Enum.map(fn section ->
          {listed, hidden} =
            Enum.split_with(section.items, &MapSet.member?(shown_ids, &1.card.id))

          [
            "#{section.label} (#{length(section.items)})",
            Enum.map(listed, fn %{card: card, path: path} ->
              "  - " <> Context.card_line(card, nil) <> " — on: #{Enum.join(path, " › ")}"
            end),
            hidden != [] && "  … and #{length(hidden)} more not listed"
          ]
          |> List.flatten()
          |> Enum.filter(&is_binary/1)
          |> Enum.join("\n")
        end)

      Enum.join([header | sections], "\n\n")
    end
  end

  # What happened, from the activity log, with the comments and status
  # updates of the period written out in full: the log records that someone
  # commented, not what they said, and what they said is the answer.
  defp activity(board_ids, from, to, limit) do
    activities = Boards.list_activities_between(board_ids, from, to)
    card_ids = Repo.all(from(c in Card, where: c.board_id in ^board_ids, select: c.id))
    comments = Boards.list_comments_between(card_ids, from, to)
    updates = Boards.list_status_updates_between(card_ids, from, to)

    cards =
      card_map(
        Enum.map(activities, & &1.card_id) ++
          Enum.map(comments, & &1.card_id) ++ Enum.map(updates, & &1.card_id)
      )

    # The log's own "commented on X" and "reported X at risk" lines say that
    # it happened; the comment and status rows say what was actually said,
    # which is the part worth reading. Keep those, drop these.
    logged =
      activities
      |> Enum.reject(&(&1.kind in ["comment", "status"]))
      |> Enum.map(
        &%{at: &1.inserted_at, card_id: &1.card_id, board_id: &1.board_id, text: &1.message}
      )

    said =
      Enum.map(comments, fn c ->
        %{
          at: c.inserted_at,
          card_id: c.card_id,
          board_id: board_of(cards, c.card_id),
          text: "comment on “#{title_of(cards, c.card_id)}”: #{snippet(c.body)}"
        }
      end) ++
        Enum.map(updates, fn u ->
          note = if u.body in [nil, ""], do: "", else: ": #{snippet(u.body)}"

          %{
            at: u.inserted_at,
            card_id: u.card_id,
            board_id: board_of(cards, u.card_id),
            text:
              "reported “#{title_of(cards, u.card_id)}” " <>
                String.downcase(StatusUpdate.health_label(u.health)) <> note
          }
        end)

    entries = Enum.sort_by(logged ++ said, & &1.at, {:desc, DateTime})

    {Enum.take(entries, limit), length(entries)}
  end

  defp render_activity(entries, total, board, from, to) do
    where =
      if board, do: "on #{board.name} and its sub-boards", else: "on every board you can see"

    range = "#{fmt(from)} – #{fmt(to)}"

    if entries == [] do
      "Nothing happened #{where} between #{fmt(from)} and #{fmt(to)}."
    else
      shown =
        if total > length(entries),
          do: "the #{length(entries)} most recent of #{total} entries",
          else: "#{total} #{if total == 1, do: "entry", else: "entries"}"

      boards = board_names(Enum.map(entries, & &1.board_id))

      days =
        entries
        |> Enum.chunk_by(&DateTime.to_date(&1.at))
        |> Enum.map(fn [first | _] = group ->
          [
            fmt(DateTime.to_date(first.at)),
            Enum.map(group, fn e ->
              "  - #{Map.get(boards, e.board_id, "a board")}: #{e.text}"
            end)
          ]
          |> List.flatten()
          |> Enum.join("\n")
        end)

      Enum.join(
        ["What happened #{where}, #{range} (#{shown}, newest first):" | days],
        "\n\n"
      )
    end
  end

  # A board on its own terms: what a person sees in the furniture of the page
  # before they look at a single card.
  defp board_text(board) do
    rollup = Map.get(board, :rollup)
    own = Enum.flat_map(board.columns, & &1.cards)
    done = Enum.count(own, & &1.completed)

    tree =
      if match?(%Rollup{}, rollup),
        do:
          "In the whole tree: #{map_size(rollup.cards)} active cards on " <>
            "#{map_size(rollup.boards)} boards (this one and #{map_size(rollup.boards) - 1} sub-boards).",
        else: nil

    [
      "# Board: #{board.name}" <> if(board.code in [nil, ""], do: "", else: " [#{board.code}]"),
      board.archived_at && "This board is archived.",
      board.description && board.description != "" && "Description: #{board.description}",
      Context.board_facts(board, Access.visible_users_for(board)),
      "Lists and how many top-level cards are in each: " <>
        Enum.map_join(board.columns, ", ", fn c ->
          "#{c.name} #{length(c.cards)}" <> if(c.wip_limit, do: "/#{c.wip_limit} WIP", else: "")
        end),
      "Top-level cards: #{length(own)} (#{done} done).",
      tree,
      fields_line(board),
      views_line(board)
    ]
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp fields_line(%{fields: fields}) when is_list(fields) and fields != [],
    do:
      "Custom fields: " <>
        Enum.map_join(fields, ", ", &"#{&1.name} (#{&1.kind})")

  defp fields_line(_), do: nil

  defp views_line(%{saved_views: views}) when is_list(views) and views != [],
    do: "Saved views: " <> Enum.map_join(views, ", ", & &1.name)

  defp views_line(_), do: nil

  defp card_map(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(from(c in Card, where: c.id in ^ids, select: {c.id, {c.title, c.board_id}}))
    |> Map.new()
  end

  defp title_of(cards, id) do
    case Map.get(cards, id) do
      {title, _board_id} -> title
      _ -> "a card"
    end
  end

  defp board_of(cards, id) do
    case Map.get(cards, id) do
      {_title, board_id} -> board_id
      _ -> nil
    end
  end

  # Board names for the ids in play, sub-boards shown under their root so
  # "Broker integrations" doesn't float free of the programme it belongs to.
  defp board_names(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    rows =
      Repo.all(
        from(b in Board,
          where:
            b.id in ^ids or
              b.id in subquery(from(x in Board, where: x.id in ^ids, select: x.root_id)),
          select: {b.id, b.name, b.root_id}
        )
      )

    names = Map.new(rows, fn {id, name, _root} -> {id, name} end)

    Map.new(rows, fn {id, name, root_id} ->
      case root_id && Map.get(names, root_id) do
        nil -> {id, name}
        ^name -> {id, name}
        root -> {id, "#{root} › #{name}"}
      end
    end)
  end

  ## Bookkeeping --------------------------------------------------------------

  # Which cards the answer could have drawn on, in the order they were first
  # found, with the search that surfaced them.
  defp remember(sources, results, query) do
    Enum.reduce(results, sources, fn %{card: card, score: score}, acc ->
      Map.put_new(acc, card.id, %{card: card, score: score, why: query, at: map_size(acc)})
    end)
  end

  # Cards a listing actually wrote out, in the order they were listed.
  defp remember_cards(sources, listings, why) do
    Enum.reduce(listings, sources, fn %{board: board, shown: shown}, acc ->
      Enum.reduce(shown, acc, fn card, acc ->
        Map.put_new(acc, card.id, %{
          card: %{card | board: board},
          score: nil,
          why: why,
          at: map_size(acc)
        })
      end)
    end)
  end

  # Pages, keyed apart from cards so a page and a card with the same id do
  # not collide in the source list.
  defp remember_pages(sources, results, query) do
    Enum.reduce(sources_of(results), sources, fn {page, score}, acc ->
      Map.put_new(acc, {:page, page.id}, %{
        page: page,
        score: score,
        why: query,
        at: map_size(acc)
      })
    end)
  end

  defp sources_of(results), do: Enum.map(results, &{&1.page, &1.score})

  defp remember_plain_pages(sources, pages, why) do
    Enum.reduce(pages, sources, fn page, acc ->
      Map.put_new(acc, {:page, page.id}, %{page: page, score: nil, why: why, at: map_size(acc)})
    end)
  end

  # Cards a tool other than search or listing put in front of the model.
  defp remember_plain(sources, cards, why) do
    Enum.reduce(cards, sources, fn card, acc ->
      Map.put_new(acc, card.id, %{card: card, score: nil, why: why, at: map_size(acc)})
    end)
  end

  defp sources(%{sources: sources}) do
    sources |> Map.values() |> Enum.sort_by(& &1.at) |> Enum.map(&Map.delete(&1, :at))
  end

  defp put_board(opts, user, name) when is_binary(name) and name != "" do
    case find_board(user, name) do
      nil -> opts
      board -> Keyword.put(opts, :board_id, board.id)
    end
  end

  defp put_board(opts, _user, _), do: opts

  ## Listing ------------------------------------------------------------------

  # The lists (columns) on a board, in board order. Cheaper than loading the
  # board, and it is the only thing `Access.list_boards` leaves out.
  defp board_columns(board) do
    Repo.all(
      from(c in Column,
        where: c.board_id == ^board.id,
        order_by: [asc: c.position, asc: c.id],
        select: %{id: c.id, name: c.name}
      )
    )
  end

  # A board's cards, restricted to the lists the question asked about. The
  # filters go to `Boards.list_cards`; the column match happens here so that
  # an ambiguous name can hit more than one list, and so an empty list still
  # gets counted (as zero) rather than vanishing.
  defp listing(board, path, filters, column_ref) do
    columns = board_columns(board)

    wanted =
      if column_ref, do: Enum.filter(columns, &column_matches?(&1, column_ref)), else: columns

    ids = MapSet.new(wanted, & &1.id)

    cards =
      if wanted == [],
        do: [],
        else:
          board |> Boards.list_cards(filters) |> Enum.filter(&MapSet.member?(ids, &1.column_id))

    %{
      board: board,
      path: path,
      level: length(String.split(path, " › ")),
      columns: wanted,
      cards: cards,
      shown: []
    }
  end

  # A board and, to `depth` levels, the sub-boards hanging beneath its cards,
  # each with the path of names above it. One query per level, whatever the
  # width: "QVM V1 Remediation › Broker integrations" is what tells a reader
  # (and the model) where a card actually lives.
  defp tree(board, depth) do
    root = {board, board.name}
    [root | descend([root], depth - 1)]
  end

  defp descend(pairs, left) when left > 0 and pairs != [] do
    paths = Map.new(pairs, fn {board, path} -> {board.id, path} end)
    ids = Map.keys(paths)

    children =
      Repo.all(
        from(b in Board,
          join: c in Card,
          on: c.id == b.parent_card_id,
          where: c.board_id in ^ids,
          order_by: [asc: c.board_id, asc: c.position, asc: c.id],
          select: {b, c.title, c.board_id}
        )
      )
      |> Enum.map(fn {board, title, parent_board_id} ->
        {board, Map.fetch!(paths, parent_board_id) <> " › " <> title}
      end)

    children ++ descend(children, left - 1)
  end

  defp descend(_pairs, _left), do: []

  defp depth_arg(nil), do: {:ok, 1}
  defp depth_arg(value) when is_integer(value), do: {:ok, min(max(value, 1), @max_depth)}

  defp depth_arg(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "" ->
        {:ok, 1}

      all when all in ~w(all every deep everything) ->
        {:ok, @max_depth}

      other ->
        case Integer.parse(other) do
          {n, _} -> depth_arg(n)
          :error -> {:error, ~s(depth must be a number or "all".)}
        end
    end
  end

  defp depth_arg(_), do: {:ok, 1}

  # Detail goes to the first boards and lists asked about; the rest are still
  # counted exactly, just not written out.
  defp allocate(listings, budget) do
    {listings, _left} =
      Enum.map_reduce(listings, budget, fn listing, left ->
        shown = Enum.take(listing.cards, left)
        {%{listing | shown: shown}, left - length(shown)}
      end)

    listings
  end

  defp column_matches?(column, ref) do
    name = String.downcase(column.name)
    ref = String.downcase(ref)

    name == ref or String.starts_with?(name, ref) or String.contains?(name, ref) or
      to_string(column.id) == ref
  end

  # `Boards.list_cards/2` takes the same string-keyed filters the board page
  # uses; anything the model left out is left out here too. `completed: false`
  # is a filter in its own right, so only nil is dropped.
  defp list_filters(args) do
    [
      {"priority", trimmed(args["priority"])},
      {"tag", trimmed(args["tag"])},
      {"flag", trimmed(args["flag"])},
      {"q", trimmed(args["q"])},
      {"due", trimmed(args["due"])},
      {"deps", trimmed(args["deps"])},
      {"assignee", trimmed(args["assignee"])},
      {"completed", if(is_boolean(args["completed"]), do: args["completed"])},
      {"archived", if(args["archived"] == true, do: true)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp filters_line(args) do
    [
      trimmed(args["column"]) && "list “#{trimmed(args["column"])}”",
      trimmed(args["priority"]) && "priority #{trimmed(args["priority"])}",
      trimmed(args["tag"]) && "tag #{trimmed(args["tag"])}",
      trimmed(args["flag"]) && "flag #{trimmed(args["flag"])}",
      trimmed(args["q"]) && "text “#{trimmed(args["q"])}”",
      trimmed(args["due"]) && "due #{trimmed(args["due"])}",
      trimmed(args["deps"]) && trimmed(args["deps"]),
      trimmed(args["assignee"]) && "assignee #{trimmed(args["assignee"])}",
      args["completed"] == true && "done",
      args["completed"] == false && "not done",
      args["archived"] == true && "archived"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
  end

  defp list_label(board_ref, column_ref) do
    ["cards", column_ref && "in “#{column_ref}”", board_ref && "on #{board_ref}"]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp lists_hint(listings) do
    case listings do
      [%{board: board}] ->
        "Its lists are: " <> Enum.map_join(board_columns(board), ", ", & &1.name)

      _ ->
        "Use list_boards to see what lists each board has."
    end
  end

  defp board_hint(user) do
    case Access.list_boards(user, archived: :all) do
      [] -> "You have no boards."
      boards -> "The boards you can see are: " <> Enum.map_join(boards, ", ", & &1.name) <> "."
    end
  end

  defp find_board(user, name) when is_binary(name) do
    wanted = String.downcase(String.trim(name))

    user
    |> Access.list_boards(archived: :all)
    |> Enum.find(
      &(String.downcase(&1.name) == wanted or String.downcase(&1.code || "") == wanted)
    )
    |> case do
      nil -> loose_board(user, wanted)
      board -> board
    end
  end

  defp find_board(_user, _name), do: nil

  # "the personal board" is how people talk; match on a contained name before
  # telling someone their board doesn't exist.
  defp loose_board(user, wanted) do
    user
    |> Access.list_boards(archived: :all)
    |> Enum.find(fn b ->
      name = String.downcase(b.name)
      String.contains?(name, wanted) or String.contains?(wanted, name)
    end)
  end

  # "me" is the asker; anyone else has to be someone the app knows about.
  # Whose permissions apply is never in question: the asker's.
  defp find_person(user, ref) do
    case trimmed(ref) do
      nil -> {:ok, user}
      me when me in ~w(me myself mine i) -> {:ok, user}
      ref -> match_person(user, ref)
    end
  end

  # The reader was always passed here and never used, so every name and address
  # on the server went into the answer — and into the prompt that produced it.
  defp match_person(user, ref) do
    wanted = String.downcase(ref)
    people = Access.visible_users(user)

    case Enum.filter(people, &person_matches?(&1, wanted)) do
      [person] ->
        {:ok, person}

      [] ->
        {:error,
         "Nobody here is called “#{ref}”. The people are: " <>
           Enum.map_join(people, ", ", &"#{User.display_name(&1)} <#{&1.email}>") <>
           "."}

      several ->
        {:error,
         "“#{ref}” could be any of: " <>
           Enum.map_join(several, ", ", &"#{User.display_name(&1)} <#{&1.email}>") <>
           ". Ask again with the email."}
    end
  end

  defp person_matches?(person, wanted) do
    String.downcase(person.email) == wanted or
      String.contains?(String.downcase(person.name || ""), wanted) or
      String.contains?(String.downcase(person.email), wanted)
  end

  defp optional_board(_user, nil), do: {:ok, nil}

  defp optional_board(user, ref) do
    case find_board(user, ref) do
      nil -> {:error, "There is no board called “#{ref}” that you can see. " <> board_hint(user)}
      board -> {:ok, board}
    end
  end

  defp date_arg(nil, default), do: {:ok, default}

  defp date_arg(value, default) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, default}

      trimmed ->
        case Date.from_iso8601(trimmed) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, "“#{trimmed}” is not a date I can read; use YYYY-MM-DD."}
        end
    end
  end

  defp date_arg(_value, default), do: {:ok, default}

  defp limit_arg(value, default) when is_integer(value) and value > 0,
    do: min(value, default * 5)

  defp limit_arg(_value, default), do: default

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_), do: nil

  defp card_id(id) when is_integer(id), do: id

  defp card_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp card_id(_), do: nil

  # The same permission check the card page makes, not a cheaper one.
  defp readable_card(user, id) do
    case Repo.get(Card, id) do
      nil ->
        nil

      card ->
        if Access.can_read?(Access.card_permission(user, card)) do
          Repo.preload(card, [
            :board,
            :column,
            :tags,
            :assignee,
            :assignees,
            :checklist_items,
            :comments,
            :status_updates,
            :attachments,
            :blocked_by,
            :blocks,
            :votes,
            [sub_board: :cards],
            [links_out: :to],
            [links_in: :from],
            [field_values: []]
          ])
        end
    end
  end

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode_args(%{} = args), do: args
  defp decode_args(_), do: %{}

  defp recent(history) do
    history
    |> Enum.filter(&(&1.role in ["user", "assistant", :user, :assistant]))
    |> Enum.map(&%{"role" => to_string(&1.role), "content" => &1.content})
    |> Enum.reject(&(&1["content"] in [nil, ""]))
    |> Enum.take(-@history_limit)
  end
end
