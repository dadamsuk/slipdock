defmodule Slipdock.Onboarding do
  @moduledoc """
  The “Getting Started” board every new account arrives to.

  Two jobs, which turn out to be the same job. A board index with nothing on
  it teaches nobody anything and reads like a broken install, so the first
  sign-in makes a board; and since something has to be *on* that board, what
  is on it is the tour — one card per part of the app, in the order a person
  meets them, each card saying what to try and where it is.

  The tour is made of the thing it describes. The cards have priorities,
  flags, tags, dates, a checklist, a comment and an epic with subcards of its
  own because that is what the cards are explaining; the wiki pages use
  `[[links]]` and a live query block because that is what the wiki page about
  the wiki is for. Nothing here is a screenshot of a feature — it is the
  feature, with the explanation written on it.

  `ensure_for/1` is what sign-in calls, and it is deliberately hard to fire
  twice: it only builds for somebody who has never signed in and owns no
  boards. `build!/1` is the unconditional version, behind
  `mix slipdock.welcome`, `POST /api/boards/welcome` and `slipdock welcome`,
  for an account that archived the board and wants the tour back.

  Set `SLIPDOCK_WELCOME_BOARD=0` to turn the automatic half off; the manual
  half keeps working.
  """

  require Logger

  alias Slipdock.{Automations, Boards, Repo, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board

  import Ecto.Query, warn: false

  @board_name "Getting Started"

  @doc "The name of the board this module builds."
  def board_name, do: @board_name

  @doc """
  Builds the board for somebody signing in for the first time, if they should
  have one. Returns `{:ok, board}` when one was made, `:skipped` otherwise.

  Never raises and never returns an error: this runs inside signing in, and a
  tutorial that fails is not a reason to keep somebody out of their account.
  """
  @spec ensure_for(User.t()) :: {:ok, Board.t()} | :skipped
  def ensure_for(%User{} = user) do
    if wanted?(user) do
      try do
        {:ok, build!(user)}
      rescue
        error ->
          Logger.error("""
          Could not build the #{@board_name} board for #{user.email}: \
          #{Exception.message(error)}
          """)

          :skipped
      end
    else
      :skipped
    end
  end

  @doc "Whether this account is due the board — see the module note."
  def wanted?(%User{} = user) do
    enabled?() and is_nil(user.last_signed_in_at) and not owns_a_board?(user)
  end

  @doc "Whether the automatic half is switched on for this server."
  def enabled?, do: Application.get_env(:slipdock, :welcome_board, true) == true

  @doc "Whether this account already has a board of this name, archived or not."
  def exists_for?(%User{id: id}) do
    Repo.exists?(
      from(b in Board,
        where: b.owner_id == ^id and is_nil(b.parent_card_id) and b.name == @board_name
      )
    )
  end

  defp owns_a_board?(%User{id: id}),
    do: Repo.exists?(from(b in Board, where: b.owner_id == ^id and is_nil(b.parent_card_id)))

  @doc """
  Builds the board whether or not it is wanted, and returns it. Raises if
  anything will not build — the callers that use this have somebody waiting
  on an answer rather than a half-finished tour.
  """
  @spec build!(User.t()) :: Board.t()
  def build!(%User{} = user) do
    {:ok, board} =
      Boards.create_board(
        %{
          "name" => @board_name,
          "description" =>
            "A tour of Slipdock, one card at a time. Work down the To Do list, " <>
              "then archive this board — you will not need it twice.",
          "color" => "sky"
        },
        owner_id: user.id
      )

    board = Boards.get_board!(board.id)
    [backlog, todo, doing, done] = board.columns

    # A WIP limit on one list and a colour on Done, so the two list settings
    # the tour mentions are already visible on it.
    Boards.update_column(doing, %{"wip_limit" => 3})
    Boards.update_column(done, %{"color" => "emerald"})

    tags = tags(board)
    welcome_page = pages(board, user)

    done_card(done, tags)
    first = in_progress_card(doing, tags)
    wiki_card = tour(todo, board, user, tags)
    backlog_cards(backlog, tags)
    automation(board, user)

    # The page about the wiki is pinned to the card about the wiki: the Docs
    # section of that card is then not an empty box with an explanation of
    # boxes in it.
    {:ok, _} = Wiki.pin(welcome_page, {:card, wiki_card})

    Boards.add_comment(
      first,
      "Comments are the running conversation on a card — this one was left " <>
        "by the tour. Yours go in the same place."
    )

    Boards.get_board!(board.id)
  end

  defp tags(board) do
    for {name, color} <- [
          {"tour", "sky"},
          {"wiki", "violet"},
          {"keyboard", "amber"},
          {"agents", "teal"}
        ],
        into: %{} do
      {:ok, tag} = Boards.create_tag(board, %{"name" => name, "color" => color})
      {name, tag}
    end
  end

  # One card already in Done, because a Done list with nothing in it is the
  # one part of a board that looks broken when it is simply new.
  defp done_card(column, tags) do
    add(
      column,
      %{
        "title" => "Sign in without a password",
        "description" => """
        Done — that was the magic link. There is no password on this account to
        forget, reuse or leak: you ask for a link, the link signs you in, and the
        session lasts 30 days.

        If mail is slow, the sign-in page will also take the six-character code
        from the same email.
        """,
        "completed" => true
      },
      tags,
      ["tour"]
    )
  end

  # The one card that is about the board itself rather than a feature, so it
  # carries the checklist, the flag and the dates.
  defp in_progress_card(column, tags) do
    today = Date.utc_today()

    card =
      add(
        column,
        %{
          "title" => "Move this card to Done",
          "description" => """
          Three ways, all of them worth knowing:

          * **Drag it.** Pick the card up and drop it in Done.
          * **Keyboard.** Press `J`, type the letter that appears on this card,
            then `→` and `Enter`. (`j` opens a card instead of picking it up.)
          * **Tick it.** Open the card and use the checkbox by the title. That
            marks it complete without moving it, which is a different thing —
            a list called Done and a card that *is* done are tracked
            separately on purpose.

          This list has a WIP limit of 3, set in its own menu: the count goes
          red when a fourth card lands here. The checklist below is the other
          thing to try.
          """,
          "priority" => "medium",
          "flags" => ["starred"],
          "start_date" => Date.add(today, -1),
          "due_date" => Date.add(today, 2),
          "percent_complete" => 25
        },
        tags,
        ["tour", "keyboard"]
      )

    Boards.add_checklist_item(card, "Drag this card into Done, then back again")
    Boards.add_checklist_item(card, "Press ? and read the keyboard sheet")
    {:ok, ticked} = Boards.add_checklist_item(card, "Tick a checklist item")
    Boards.toggle_checklist_item(ticked.id)
    card
  end

  # The tour proper: the To Do list, read top to bottom. Returns the card
  # about the wiki, which has a page to be pinned to it.
  defp tour(column, board, user, tags) do
    today = Date.utc_today()

    add(
      column,
      %{
        "title" => "Open a card and look down the side",
        "description" => """
        Click a card — or press `Ctrl-O` and type a title — and everything a card
        can carry is down the right-hand side: a Markdown description, a
        checklist, tags, five flags (flagged, blocked, needs review, waiting,
        starred), a priority, start and due dates, an assignee, dependencies on
        other cards, typed links, web links, file attachments up to 25 MB, docs
        and comments.

        Each heading has one letter underlined: that letter jumps to the
        section. `f` flags, `t` tags, `d` description, `a` attachments,
        `e` checklist, `s` subcards, `c` comments. `Esc` closes it.

        You will not want all of that on most cards. It is there for the one
        card a month that needs it.
        """,
        "priority" => "high"
      },
      tags,
      ["tour", "keyboard"]
    )

    add(
      column,
      %{
        "title" => "Add a card of your own",
        "description" => """
        Four doors to the same thing:

        * **`q`, anywhere.** One line of plain English — "call the printers
          about the banners friday, urgent" — read by a cheap model into a card
          on the board and list you nominate on your account page.
        * **At the foot of a list.** The ordinary way: type a title, press
          Enter, keep typing for the next one.
        * **In the table or outline view**, a line of shorthand:
          `Write the post due: tomorrow #high #tour @#{short_name(user)}`.
        * **`Ctrl-P`**, the command palette, for this and everywhere else you
          might be going.

        Quick add needs an AI key for the plain-English half — see the card
        about the assistant. The other three work with no key at all.
        """
      },
      tags,
      ["tour"]
    )

    add(
      column,
      %{
        "title" => "Flag it, tag it, prioritise it",
        "description" => """
        The three things that make a hundred cards findable.

        **Tags** belong to the board and are made on its Tags screen; this one
        has four. **Flags** are a fixed five, the same on every board, so
        *blocked* means blocked everywhere. **Priority** runs none → low →
        medium → high → critical and colours the card's edge.

        Set a few on this card and watch the filter bar at the top of the
        board: every one of them is a filter, and a filter you keep can be
        saved as a view with a name.
        """,
        "priority" => "low",
        "flags" => ["review"]
      },
      tags,
      ["tour"]
    )

    add(
      column,
      %{
        "title" => "Give this a date, then look at the board eight ways",
        "description" => """
        Put a due date on this card — Friday will do — and then press `v` and
        step through the views. Same cards, eight questions:

        * **Board** — what is where.
        * **Table** — one row per card, sortable, editable in place, with a
          column chooser and CSV export.
        * **Timeline** — Gantt bars by start and due date, draggable, with
          subcards nested beneath their parent.
        * **Calendar** — the month, cards on their due dates, drag between days.
        * **Swimlanes** — a grid with any attribute on each axis.
        * **Outline** — the board as a collapsible tree.
        * **Narrative** — what actually happened over a date range, in prose.
        * **Prioritise** — a ranked table where priority, votes and scores are
          edited in place.

        A view with its filters, grouping and sort is savable, shareable and
        publishable to a read-only link.
        """,
        "due_date" => Date.add(today, 7)
      },
      tags,
      ["tour"]
    )

    epic(column, tags, today)

    wiki_card =
      add(
        column,
        %{
          "title" => "Write something down in the wiki",
          "description" => """
          This board has a wiki with three pages on it already — the tab is at
          the top, beside the views. The page pinned to this card,
          **Welcome to your wiki**, explains the rest: `[[links]]` between
          pages, live card chips, query blocks that answer themselves when
          somebody reads them, folders, revisions with a reason for every save,
          and publishing a page to a public link.

          Open it, press Edit, and add a line. Then look at History.
          """,
          "priority" => "medium"
        },
        tags,
        ["tour", "wiki"]
      )

    add(
      column,
      %{
        "title" => "Find anything: filter, search, ask",
        "description" => """
        Three different tools, and the difference matters.

        **The filter bar** on a board matches text and attributes on that
        board. Fast, exact, and the thing you want nine times in ten.

        **Search** (`/search`, or `/` on a board) matches by *meaning* across
        every board you can see. "The thing that was blocked on legal" finds
        the card whose comment said "waiting on the contract review".

        **Ask** (`/ask`) hands that same search to a model as one tool among
        several — it can count a list, describe a board, read the activity log
        — so a question in prose gets an answer in prose, naming the cards it
        read. Both are scoped to what you are allowed to see.
        """
      },
      tags,
      ["tour"]
    )

    add(
      column,
      %{
        "title" => "Let the board chase things for you",
        "description" => """
        Open this board's **Automations** tab. There is a rule on it already,
        written as a sentence: *when a card lands in Done, comment on it.*
        Move a card into Done and watch it happen.

        Rules are written in plain English, parsed once by a model into
        something the app runs by itself — so the model is not in the loop
        every time it fires. They can email, move cards, set priorities, add
        tags or flags, assign, comment, set due dates, archive, start a wiki
        page, call a webhook, or raise a **dismissable alert** in the header
        bar of every page.

        "Move anything untouched for a week back to Backlog" is one line and
        then it is somebody else's problem.
        """,
        "priority" => "medium"
      },
      tags,
      ["tour"]
    )

    add(
      column,
      %{
        "title" => "Point the assistant at this page",
        "description" => """
        Press `a` on any board or card to chat about what is on screen. Three
        things live here:

        * **Chat** — questions about this board, this card, this page.
        * **Edit** — "set this due next Tuesday and pick a suitable priority"
          becomes a set of changes you approve before they apply. Nothing is
          written without your say-so.
        * **Narrative** — prose about what happened, at five levels of detail.

        All of it runs on your own OpenRouter key, which goes on your account
        page. No key, no AI features — and the rest of the app does not care.
        """
      },
      tags,
      ["tour"]
    )

    add(
      column,
      %{
        "title" => "Share a board, publish a view",
        "description" => """
        Board settings → sharing. A board, a single card or a saved view can be
        shared with a person or a **group** of people, read-only or editable.
        Invited people get an account by magic link like you did.

        A saved view can also be **published**: a read-only public link for
        someone who should see the plan and nothing else.

        Everything you do appears on every open browser immediately — two
        people on one board is the normal case, not a feature to switch on.
        """
      },
      tags,
      ["tour"]
    )

    add(
      column,
      %{
        "title" => "Drive it from a terminal, or hand it to an agent",
        "description" => """
        Everything on this board is in the JSON API, and the `slipdock` CLI is
        a thin layer over it:

            slipdock boards
            slipdock cards --board #{board.code} --list "To Do"
            slipdock add "Ring the printers" --board #{board.code} --due friday
            slipdock page write "Retry policy" --board #{board.code} --file notes.md

        Make a token on your account page, or run `slipdock login` and approve
        the device from the browser.

        For an agent, `GET /api/guide` is a written brief on how to work a
        board properly — claim a card, comment as you go, finish it — and
        `GET /api/skills` hands over the skills this server ships. Point a
        coding agent at either and it will know what to do with this board
        without being told twice.
        """
      },
      tags,
      ["tour", "agents"]
    )

    add(
      column,
      %{
        "title" => "Make this yours, then archive this board",
        "description" => """
        The tour is over; this board is now just a board. Rename the lists,
        delete them, add your own, give them colours, WIP limits, categories
        (to do / in progress / done / dropped) and date horizons for
        roadmapping. Board settings holds the name, colour, description and the
        short code that addresses it in the API.

        Then **archive it** from the board index. Archiving puts the whole
        thing away without deleting anything on it, it comes back from the
        Archived section whenever you want, and on a metered server it hands
        the card allowance back.

        You can rebuild this tour any time: `slipdock welcome`.
        """,
        "flags" => ["waiting"]
      },
      tags,
      ["tour"]
    )

    wiki_card
  end

  # An epic: a card with a board of its own. It is the hardest idea in the app
  # to explain in a paragraph, so this card is the explanation.
  defp epic(column, tags, today) do
    {:ok, card} =
      Boards.create_card(column, %{
        "title" => "Break a big job into subcards",
        "description" => """
        This card has a board of its own — open it and look at **Subcards**.

        Any card can become one, with lists taken from a template, and they
        nest as deep as the work does. The point is the **roll-up**: this card
        summarises everything beneath it, however deep. How many leaves are
        done, the real start and due dates (its own, or its subcards'), whether
        anything below it is blocked or overdue, and a health state — drawn on
        the card, in the table, and as one bar on the timeline.

        So the top level of a board is the roadmap and the level below it is
        the task list, and nobody has to keep the two in step by hand. The
        Outline view is the whole tree at a chosen depth.
        """,
        "priority" => "high",
        "start_date" => Date.add(today, 1),
        "due_date" => Date.add(today, 10)
      })

    Enum.each(["tour"], &Boards.toggle_card_tag(card, tags[&1]))

    {:ok, sub} = Boards.create_sub_board(card, subcard_template())
    sub = Boards.get_board!(sub.id)
    [sub_todo, sub_doing, sub_done] = sub.columns

    {:ok, _} =
      Boards.create_card(sub_done, %{
        "title" => "Decide what “done” means here",
        "completed" => true
      })

    {:ok, _} =
      Boards.create_card(sub_doing, %{
        "title" => "Do the first piece",
        "percent_complete" => 50
      })

    {:ok, blocker} =
      Boards.create_card(sub_todo, %{
        "title" => "Then the next piece",
        "due_date" => Date.add(today, 8)
      })

    {:ok, blocked} =
      Boards.create_card(sub_todo, %{
        "title" => "This one cannot start until the one above is finished"
      })

    # A real dependency, not a flag that says so: this is what puts the blocked
    # badge on the card and draws the line on the timeline, red if the dates
    # contradict it.
    {:ok, _} = Boards.add_dependency(blocked, blocker)
    card
  end

  # The same lists the demo workspace uses, by the same name, so a server with
  # both does not end up with two templates that say the same thing.
  defp subcard_template do
    case Boards.find_template("Task breakdown") do
      {:ok, template} ->
        template

      {:error, :not_found} ->
        {:ok, template} =
          Boards.create_template(%{
            "name" => "Task breakdown",
            "description" => "Lists for the subcards of one epic.",
            "columns" => [
              %{"name" => "To Do", "category" => "todo"},
              %{"name" => "In Progress", "category" => "doing", "wip_limit" => 2},
              %{"name" => "Done", "category" => "done", "color" => "emerald"}
            ]
          })

        template
    end
  end

  defp backlog_cards(column, tags) do
    add(
      column,
      %{
        "title" => "Ideas live here until you are ready for them",
        "description" => """
        Backlog is not a special list — it is a list called Backlog. Rename it,
        move it, delete it, add three more. The only thing a list carries
        beyond its name is a colour, a WIP limit, and optionally a roadmap
        category and a date range that schedules whatever is dropped into it.
        """
      },
      tags,
      ["tour"]
    )

    add(
      column,
      %{
        "title" => "Light, dark, or whatever the laptop says",
        "description" => """
        The theme switch is in the header, with a system option. On a phone the
        whole thing re-lays itself out below 640px: a bottom bar with quick add
        under your thumb, the board as a one-list pager, and the calendar,
        table and timeline drawn for a narrow screen rather than scrolled
        sideways.
        """
      },
      tags,
      ["tour"]
    )
  end

  defp add(column, attrs, tags, tag_names) do
    {:ok, card} = Boards.create_card(column, attrs)
    Enum.each(tag_names, &Boards.toggle_card_tag(card, tags[&1]))
    card
  end

  ## The wiki -----------------------------------------------------------------

  # Three pages, nested: the one about the wiki, and two beneath it that are
  # the kind of page a wiki is actually for — a decision and a runbook.
  defp pages(board, user) do
    {:ok, welcome} =
      Wiki.create_page(
        board,
        %{
          "title" => "Welcome to your wiki",
          "summary" => "What the wiki is for, and what it can do that a card cannot.",
          "body" => """
          Every board has one of these: a tree of Markdown pages beside the
          cards, for the things a card is a bad home for. A card is a unit of
          work and it gets archived when the work is done. *How the billing
          retries work* is not a unit of work, and it should still be here in
          a year.

          Rule of thumb: **if you would be annoyed to lose it when the card is
          archived, it belongs on a page.**

          ## What is written here already

          [[!children]]

          ## Links, which are the point

          A page can point at anything:

          | Written | What it draws |
          | --- | --- |
          | `[[A decision, written down]]` | a page on this board — [[A decision, written down]] |
          | `[[page\\|other words]]` | the same, with your own link text |
          | `[[#1]]` | card 1, as a live chip with its list and state |
          | `[[Something nobody has written]]` | a *wanted* page: a link that offers to create it |
          | `[[!toc]]` `[[!children]]` `[[!backlinks]]` | contents, child pages, everything linking here |

          A wanted link is how a wiki grows. Write the link while you are
          thinking about it; fill the page in when you have the answer.

          ## A list that is never out of date

          This block is answered when the page is *read*, with your
          permissions, not the writer's:

          ```slipdock
          view: list
          board: this
          done: hide
          limit: 5
          empty: "Nothing left on the tour. Archive the board."
          ```

          Anything the board views can do — filters, grouping, sorting, a
          table, a count, a progress bar — a page can do, which means a
          hand-written list of blocked cards is never the right answer.

          ## Writing

          Raw Markdown in a box. Every save keeps a revision with who made it
          and why, so History will show you this page as it started. A page can
          be filed in a **folder**, pinned to a card (this one is pinned to the
          card about the wiki), published to a public read-only link, or
          exported as a folder of Markdown files. `/wiki` is every board's
          pages in one tree.

          Agents write pages through the same API you are using now — a
          section at a time, with a message saying why — which is how a day of
          work by something that is not you leaves documentation behind.
          """
        },
        user: user
      )

    {:ok, _decision} =
      Wiki.create_page(
        board,
        %{
          "title" => "A decision, written down",
          "summary" => "The shape to copy when something has been decided.",
          "parent_id" => welcome.id,
          "body" => """
          An example of the most valuable page a wiki holds: not what the plan
          is, but why it is this plan. Delete it, or keep the shape.

          ## Decision

          Documentation lives on the board it is about, not in a separate wiki
          nobody opens.

          ## Why

          A doc beside the work gets read while the work is happening. A doc in
          another system gets read once, by its author, on the day it is
          written.

          ## What we gave up

          One tidy place for everything. Pages are scattered across boards now,
          which is why [[Welcome to your wiki]] has search, folders and `/wiki`
          over the lot.

          ## Log

          Dated notes go here, newest last, appended rather than rewritten —
          agents are told to work this way, and it is a good habit for people.
          """
        },
        user: user
      )

    {:ok, _runbook} =
      Wiki.create_page(
        board,
        %{
          "title" => "A runbook, written down",
          "summary" => "The other shape: what to do, in order, when it is three in the morning.",
          "parent_id" => welcome.id,
          "body" => """
          The second shape worth having. A runbook is written for somebody
          tired, so it is numbered, it is short, and it says who decides.

          ## When this happens

          1. Check the board's alerts in the header bar.
          2. Look at the Blocked filter: anything flagged *blocked* has a
             reason on it, in a comment.
          3. If it is still unclear, read the board's Activity log — every
             change, with who made it.

          ## Who decides

          Whoever the card is assigned to. If nobody is assigned, that is the
          problem to fix first.

          ## Rolling back

          Nothing here is destructive: archive rather than delete, and
          archived boards, cards and pages all come back.
          """
        },
        user: user
      )

    welcome
  end

  ## Automations --------------------------------------------------------------

  # One rule, chosen to be harmless and immediately visible: no email, no
  # schedule, nothing that touches anything but the card that moved.
  defp automation(board, user) do
    {:ok, rule} =
      Automations.create_rule(
        %{
          "name" => "Say something when a card reaches Done",
          "source" => "when a card lands in Done, comment on it",
          "board_id" => board.id,
          "spec" => %{
            "trigger" => %{"type" => "card_moved", "to" => "Done"},
            "conditions" => [],
            "actions" => [
              %{
                "type" => "comment",
                "body" =>
                  "An automation wrote this when “{{card.title}}” reached Done. " <>
                    "The rule is on the Automations tab — switch it off there, or " <>
                    "make it do something useful."
              }
            ]
          }
        },
        created_by: user
      )

    rule
  end

  # The name a quick-add example can use without looking like a form field.
  defp short_name(%User{} = user) do
    user
    |> User.display_name()
    |> String.split(~r/[\s@]/, parts: 2)
    |> hd()
    |> String.downcase()
  end
end
