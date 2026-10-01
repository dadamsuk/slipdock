defmodule Slipdock.Demo do
  @moduledoc """
  Builds a demo workspace: two boards with people, tags, an epic with
  subcards, dependencies, a scoring scheme, a wiki and an automation, so a
  fresh install has something true to show and the screenshots in the README
  can be reproduced by anybody.

  `mix slipdock.demo` is the way in; `priv/repo/seeds.exs` calls the same code
  on first boot. Nothing here is specific to one machine or one person — the
  addresses are all `example.com`.
  """

  alias Slipdock.{Accounts, Automations, Boards, Fields, Wiki}
  alias Slipdock.Boards.Board
  alias Slipdock.Repo

  @owner "sam@example.com"

  @people [
    {@owner, "Sam Okonkwo"},
    {"ash@example.com", "Ash Delacroix"},
    {"ren@example.com", "Ren Tanaka"}
  ]

  @doc "The email the demo boards belong to. Sign in as this to see them."
  def owner_email, do: @owner

  @doc """
  Builds the workspace. Returns `{:ok, board}` with the main board, or
  `{:error, :not_empty}` if there are boards already and `force: true` was
  not given.
  """
  def build(opts \\ []) do
    cond do
      Repo.aggregate(Board, :count) == 0 -> {:ok, build!(opts)}
      opts[:force] -> {:ok, build!(opts)}
      true -> {:error, :not_empty}
    end
  end

  @doc "Builds the workspace whether or not one is there already."
  def build!(_opts \\ []) do
    people = Enum.map(@people, &person/1)
    [sam, ash, ren] = people
    today = Date.utc_today()

    template = breakdown_template()
    launch = launch_board(sam, ash, ren, today, template)
    personal_board(sam, today)
    launch
  end

  defp person({email, name}) do
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, user} = Accounts.update_profile(user, %{"name" => name})
    user
  end

  # A template for the subcards of an epic, so `create_sub_board/2` has lists
  # to take and the sub-board arrives with a page to write on.
  defp breakdown_template do
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
            ],
            "pages" => [
              %{
                "title" => "{{board.name}} — notes",
                "summary" => "Decisions and open questions for this piece of work.",
                "body" => "## Decisions\n\n## Open questions\n"
              }
            ]
          })

        template
    end
  end

  defp launch_board(sam, ash, ren, today, template) do
    {:ok, board} =
      Boards.create_board(
        %{
          "name" => "Product Launch",
          "description" => "Everything needed to ship v2.0 to customers.",
          "color" => "indigo"
        },
        owner_id: sam.id
      )

    board = Boards.get_board!(board.id)
    [backlog, todo, doing, done] = board.columns
    Boards.update_column(doing, %{"wip_limit" => 3, "color" => "amber"})
    Boards.update_column(done, %{"color" => "emerald"})

    tags = tags(board)

    add = fn column, attrs, tag_names ->
      {:ok, card} = Boards.create_card(column, attrs)
      Enum.each(tag_names, &Boards.toggle_card_tag(card, tags[&1]))
      card
    end

    pricing =
      add.(
        doing,
        %{
          "title" => "Finalise pricing page copy",
          "description" =>
            "Three tiers. Keep the comparison table under 12 rows and make the CTA the obvious next step.",
          "priority" => "high",
          "flags" => ["flagged"],
          "start_date" => Date.add(today, -4),
          "due_date" => Date.add(today, 1),
          "percent_complete" => 60,
          "assignee_id" => ash.id,
          "color" => "orange"
        },
        ["marketing", "frontend"]
      )

    Boards.add_checklist_item(pricing, "Draft headline options")
    Boards.add_checklist_item(pricing, "Review with sales")
    {:ok, item} = Boards.add_checklist_item(pricing, "Legal sign-off on claims")
    Boards.toggle_checklist_item(item.id)
    Boards.add_comment(pricing, "Sales wants the annual discount called out more prominently.")

    billing =
      add.(
        doing,
        %{
          "title" => "Migrate billing webhooks to new queue",
          "description" =>
            "Stripe events currently hit the legacy worker. Move them to Oban and add retries.",
          "priority" => "critical",
          "flags" => ["blocked"],
          "start_date" => Date.add(today, -8),
          "due_date" => Date.add(today, -2),
          "assignee_id" => ren.id
        },
        ["backend"]
      )

    onboarding =
      add.(
        doing,
        %{
          "title" => "Onboarding flow redesign",
          "priority" => "medium",
          "flags" => ["review"],
          "start_date" => Date.add(today, -2),
          "due_date" => Date.add(today, 11),
          "percent_complete" => 40,
          "assignee_id" => ash.id,
          "color" => "fuchsia"
        },
        ["design", "frontend"]
      )

    Boards.add_checklist_item(onboarding, "Wireframes")
    Boards.add_checklist_item(onboarding, "Hi-fi mockups")
    Boards.add_checklist_item(onboarding, "Usability test with 5 users")

    notes =
      add.(
        todo,
        %{
          "title" => "Write release notes",
          "priority" => "medium",
          "start_date" => Date.add(today, 2),
          "due_date" => Date.add(today, 5),
          "assignee_id" => sam.id
        },
        ["docs", "marketing"]
      )

    # Release notes can't be written until the queue migration lands.
    Boards.add_dependency(notes, billing)

    add.(
      todo,
      %{
        "title" => "Fix flaky checkout test on CI",
        "priority" => "high",
        "flags" => ["starred"],
        "due_date" => Date.add(today, 3),
        "assignee_id" => sam.id
      },
      ["bug", "backend"]
    )

    add.(
      todo,
      %{
        "title" => "Record product demo video",
        "priority" => "low",
        "flags" => ["waiting"],
        "start_date" => Date.add(today, 6),
        "due_date" => Date.add(today, 9),
        "assignee_id" => ren.id
      },
      ["marketing"]
    )

    epic(todo, template, sam, ash, ren, today, tags)

    add.(backlog, %{"title" => "Dark mode for the dashboard", "assignee_id" => sam.id}, [
      "frontend",
      "design"
    ])

    add.(backlog, %{"title" => "Public API rate limiting", "priority" => "low"}, ["backend"])
    add.(backlog, %{"title" => "Localise emails into German and French"}, ["docs"])
    add.(backlog, %{"title" => "Investigate slow search on large workspaces"}, ["bug"])

    add.(
      done,
      %{"title" => "Set up staging environment", "completed" => true, "assignee_id" => ren.id},
      ["backend"]
    )

    add.(done, %{"title" => "Choose launch date", "completed" => true, "priority" => "high"}, [
      "marketing"
    ])

    add.(done, %{"title" => "Logo refresh", "completed" => true, "color" => "violet"}, ["design"])

    scoring(board, sam, ash, ren)
    pages(board, sam)
    automation(board, sam)

    Boards.get_board!(board.id)
  end

  defp tags(board) do
    for {name, color} <- [
          {"design", "fuchsia"},
          {"backend", "sky"},
          {"frontend", "violet"},
          {"marketing", "orange"},
          {"bug", "red"},
          {"docs", "teal"}
        ],
        into: %{} do
      {:ok, tag} = Boards.create_tag(board, %{"name" => name, "color" => color})
      {name, tag}
    end
  end

  # One epic with a board of its own, so the roll-up, the outline and the
  # subcard breadcrumb all have something to show.
  defp epic(column, template, sam, ash, ren, today, tags) do
    {:ok, card} =
      Boards.create_card(column, %{
        "title" => "Self-serve trial sign-up",
        "description" =>
          "Let people start a 14-day trial without talking to sales. Broken down into subcards.",
        "priority" => "high",
        "start_date" => Date.add(today, 1),
        "due_date" => Date.add(today, 14),
        "assignee_id" => sam.id
      })

    Enum.each(["frontend", "backend"], &Boards.toggle_card_tag(card, tags[&1]))

    {:ok, sub} = Boards.create_sub_board(card, template)
    sub = Boards.get_board!(sub.id)
    [sub_todo, sub_doing, sub_done] = sub.columns

    {:ok, _} =
      Boards.create_card(sub_doing, %{
        "title" => "Trial provisioning endpoint",
        "priority" => "high",
        "percent_complete" => 70,
        "assignee_id" => ren.id
      })

    {:ok, _} =
      Boards.create_card(sub_todo, %{
        "title" => "Sign-up form and validation",
        "assignee_id" => ash.id
      })

    {:ok, _} =
      Boards.create_card(sub_todo, %{
        "title" => "Trial expiry emails",
        "due_date" => Date.add(today, 12),
        "assignee_id" => sam.id
      })

    {:ok, _} =
      Boards.create_card(sub_done, %{
        "title" => "Decide trial length and limits",
        "completed" => true
      })

    card
  end

  # RICE on the backlog, with values on a few cards so Prioritise and the
  # table have numbers to sort by.
  defp scoring(board, sam, ash, ren) do
    {:ok, _} = Fields.install_preset(board, "rice")
    fields = Map.new(Fields.list_fields(Board.root_id(board)), &{&1.key, &1})
    cards = Map.new(Boards.list_cards(board), &{&1.title, &1})

    values = [
      {"Dark mode for the dashboard",
       %{"reach" => 4000, "impact" => 3, "confidence" => 80, "effort" => 3}},
      {"Public API rate limiting",
       %{"reach" => 600, "impact" => 2, "confidence" => 90, "effort" => 1}},
      {"Localise emails into German and French",
       %{"reach" => 2500, "impact" => 2, "confidence" => 60, "effort" => 4}},
      {"Investigate slow search on large workspaces",
       %{"reach" => 1200, "impact" => 4, "confidence" => 70, "effort" => 2}}
    ]

    for {title, by_key} <- values,
        card = cards[title],
        {key, value} <- by_key,
        field = fields[key] do
      Fields.set_value(card, field, value)
    end

    # A few votes, so the Prioritise view shows the budget being spent.
    for {title, {user, count}} <- [
          {"Dark mode for the dashboard", {sam, 3}},
          {"Investigate slow search on large workspaces", {ash, 2}},
          {"Public API rate limiting", {ren, 1}}
        ],
        card = cards[title] do
      Slipdock.Votes.set(card, user, count)
    end
  end

  defp pages(board, user) do
    {:ok, _} =
      Wiki.create_page(
        board,
        %{
          "title" => "Launch runbook",
          "summary" => "What happens on the day, in order, and who does it.",
          "body" => """
          ## The day

          1. Freeze `main` at 09:00 and cut the release tag.
          2. Run the migration on staging, then production.
          3. Flip the feature flag for 10% of accounts and watch error rates
             for an hour.
          4. Ramp to 100% or roll the flag back — one person decides, and
             says so in the launch channel.

          ## Rolling back

          The flag is the rollback. The migration is additive on purpose, so
          nothing needs undoing at the database level.

          ## Who to wake

          Whoever is on call, then the engineer whose name is on the card in
          *In Progress*.
          """
        },
        user: user
      )

    {:ok, _} =
      Wiki.create_page(
        board,
        %{
          "title" => "Pricing decision",
          "summary" => "Why three tiers, and why the middle one is the default.",
          "body" => """
          ## Decision

          Three tiers — Starter, Team, Scale — with Team pre-selected.

          ## Why

          Two tiers made Scale look like the only serious option and pushed
          small teams away. Four tested worse than three: people stopped
          reading at the third column.

          ## What we gave up

          Usage-based pricing. It fits the cost model better but nobody could
          explain it in one sentence, so it waits for a later release.
          """
        },
        user: user
      )
  end

  defp automation(board, user) do
    {:ok, _} =
      Automations.create_rule(
        %{
          "name" => "Chase stale cards in progress",
          "source" => "when a card sits in In Progress for 3 days, flag it and tell the assignee",
          "board_id" => board.id,
          "spec" => %{
            "trigger" => %{"type" => "card_stale", "days" => 3, "column" => "In Progress"},
            "conditions" => [%{"field" => "completed", "op" => "is", "value" => false}],
            "actions" => [
              %{"type" => "add_flags", "flags" => ["flagged"]},
              %{
                "type" => "notify_assignee",
                "subject" => "This card has gone quiet",
                "body" => "It has been three days since anything happened on this card."
              }
            ]
          }
        },
        created_by: user
      )
  end

  defp personal_board(sam, today) do
    {:ok, board} =
      Boards.create_board(
        %{
          "name" => "Personal",
          "description" => "Life admin and side projects.",
          "color" => "emerald"
        },
        owner_id: sam.id
      )

    board = Boards.get_board!(board.id)
    [_backlog, todo, _doing, _done] = board.columns
    {:ok, home} = Boards.create_tag(board, %{"name" => "home", "color" => "lime"})

    {:ok, card} =
      Boards.create_card(todo, %{
        "title" => "Renew passport",
        "due_date" => Date.add(today, 20),
        "priority" => "medium",
        "assignee_id" => sam.id
      })

    Boards.toggle_card_tag(card, home)
    Boards.create_card(todo, %{"title" => "Plan weekend hike", "flags" => ["starred"]})
    board
  end
end
