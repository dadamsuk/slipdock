defmodule SlipdockWeb.APIGuide do
  @moduledoc """
  The document `GET /api/guide` serves: how an agent should use these boards to
  track its own work — the model, the epic/subcard convention, how to choose
  what to do next, and what to write back as it goes.

  Anything that could drift from the code — the vocabularies, the endpoint
  list, the reader's own boards — is generated at request time; the rest is
  prose. Keep it that way: a guide that lies is worse than no guide.
  """

  alias Slipdock.Access
  alias Slipdock.Boards
  alias Slipdock.Boards.{Card, CardLink, Column, StatusUpdate}

  @doc """
  The guide as markdown. Options:

    * `:base_url` — the API's base URL, as the reader reached it
    * `:user` — the signed-in `%Slipdock.Accounts.User{}`, if a token was passed;
      with one, the guide ends with the reader's own boards and lists
  """
  def markdown(opts \\ []) do
    base = Keyword.get(opts, :base_url, "")
    user = Keyword.get(opts, :user)

    [
      intro(base),
      getting_in(base, user),
      model(),
      epics(),
      choosing(base),
      finding(base),
      working(),
      recipes(base),
      automations(),
      runners(),
      wiki(),
      portable(),
      vocabulary_section(),
      endpoints_section(),
      this_server(user),
      boards_section(user, Keyword.get(opts, :token))
    ]
    |> Enum.join("\n")
  end

  # What is true of *this* server rather than of Slipdock in general: how much
  # of the card allowance is left, and whether the people list is scoped.
  # Generated per request, so it is current rather than aspirational.
  defp this_server(nil), do: ""

  defp this_server(user) do
    notes =
      [
        cards_note(user),
        boards_note(user),
        storage_note(user),
        trial_note(user),
        directory_note(),
        invites_note()
      ]
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case notes do
      [] -> ""
      notes -> "\n## This server's limits\n\n" <> Enum.join(notes, "\n\n") <> "\n"
    end
  end

  defp cards_note(user) do
    case Slipdock.Quota.status(user, :items) do
      %{limited?: false} ->
        "There is no limit on how many cards, pages or files this account may have."

      %{used: used, limit: limit, remaining: remaining} ->
        %{cards: cards, pages: pages, files: files} = Slipdock.Quota.breakdown(user)

        """
        **Items: #{used} of #{limit} used, #{remaining} left** — #{cards} cards,
        #{pages} pages, #{files} files. A card, a wiki page and an uploaded file each
        count as one item. The count is everything non-archived on boards you own;
        things on boards other people shared with you cost you nothing, archiving a
        card or a page frees it up, and a file counts until it is deleted.

        Creating one past the limit answers `402` with `"error": "card_limit_reached"`
        and `"retryable": false`. That is not a fault in the request — fixing the title
        and trying again will fail identically, forever. Stop, tell the person, and
        suggest archiving something finished with. `GET /api/me` carries the same
        figures under `cards`, and every limit under `limits`, so you can check before
        you start rather than discovering it halfway through a batch.
        """
    end
  end

  defp boards_note(user) do
    case Slipdock.Quota.status(user, :boards) do
      %{limited?: false} ->
        ""

      %{used: used, limit: limit, remaining: remaining} ->
        """
        **Boards: #{used} of #{limit} used, #{remaining} left.** Boards you own, not
        boards shared with you, and sub-boards (the ones behind subcards) do not count.
        Creating one past the limit answers `402` with `"error": "board_limit_reached"`.
        """
    end
  end

  defp storage_note(user) do
    case Slipdock.Quota.status(user, :storage) do
      %{limited?: false} ->
        ""

      %{used: used, limit: limit, remaining: remaining} ->
        human = &Slipdock.Quota.humanise_bytes/1

        """
        **Files: #{human.(used)} of #{human.(limit)} used, #{human.(remaining)} left.**
        Uploading past it answers `402` with `"error": "storage_limit_reached"`.
        """
    end
  end

  defp trial_note(user) do
    case Slipdock.Quota.trial(user) do
      %{applies?: false} ->
        ""

      %{expired?: true, days: days} ->
        """
        **This account's #{days}-day free trial has ended.** Everything already here is
        readable and editable, but nothing new can be added: creating anything answers
        `402` with `"error": "trial_expired"` and `"retryable": false`. Do not retry.
        Tell the person they need to subscribe.
        """

      %{days_left: left, ends_at: ends_at} ->
        """
        **Free trial: #{left} day(s) left**, ending #{DateTime.to_date(ends_at)}. After
        that nothing new can be added — creating anything answers `402` with
        `"error": "trial_expired"` — though everything already here stays editable.
        """
    end
  end

  defp directory_note do
    case Slipdock.Settings.user_directory() do
      :shared_only ->
        """
        **The people you can see are only the people you share something with** —
        a board, a card, a page or a group. Somebody you expect to be here and cannot
        find has probably not been shared anything with you; they have not been
        deleted. Assigning a card to them will not work until something is shared.
        """

      _ ->
        ""
    end
  end

  defp invites_note do
    if Slipdock.Settings.invites_create_accounts?() do
      ""
    else
      """
      **Sharing with an address that has no account here will be refused.** This
      server does not make accounts for the people you share things with, so an
      unknown address is an error rather than an invitation. Sharing is not in this
      API anyway; it is mentioned so that you can say why rather than guessing.
      """
    end
  end

  # Each top-level heading's handle, for asking for one section at a time
  # (the MCP `get_guide` tool). A heading missing here gets a slug of itself.
  @section_keys %{
    "Getting in" => "getting-in",
    "The model" => "model",
    "Epics and subcards" => "epics",
    "Choosing what to do next" => "choosing",
    "Finding something nobody can name" => "finding",
    "Working a card" => "working",
    "Recipes" => "recipes",
    "Automations and alerts" => "automations",
    "Runners" => "runners",
    "The wiki: writing things down" => "wiki",
    "Skills" => "skills",
    "Moving boards between servers" => "moving",
    "Vocabulary" => "vocabulary",
    "Every endpoint" => "endpoints",
    "This server's limits" => "limits",
    "Your boards" => "boards",
    "Your boards right now" => "boards"
  }

  # What a short guide is made of: enough to work a board, in this order.
  # *The model* is field-by-field reference, and with it the short guide no
  # longer fits in a tool result, so it is one of the sections to ask for.
  @core ~w(mcp epics choosing working boards)

  @doc """
  The guide cut at its `##` headings: `{key, title, markdown}` in document
  order, the text before the first heading under the key `"intro"`. The
  `### Over MCP` part of *Getting in* is offered on its own as well, as `"mcp"`.
  Takes the same options as `markdown/1`.
  """
  def sections(opts \\ []) do
    [{_, _, intro} | rest] =
      opts
      |> markdown()
      |> String.split(~r/^(?=## )/m)
      |> Enum.map(&cut/1)

    mcp =
      Enum.find_value(rest, fn {key, _, text} -> key == "getting-in" && over_mcp(text) end)

    [{"intro", nil, intro} | rest] ++ if(mcp, do: [mcp], else: [])
  end

  defp cut("## " <> _ = text) do
    [heading | _] = String.split(text, "\n", parts: 2)
    title = heading |> String.trim_leading("## ") |> String.trim()
    {Map.get(@section_keys, title, slug(title)), title, text}
  end

  defp cut(text), do: {"intro", nil, text}

  defp over_mcp(text) do
    case Regex.run(~r/^### Over MCP\n.*?(?=^###? |\z)/ms, text) do
      [part] -> {"mcp", "Over MCP", String.replace_prefix(part, "###", "##")}
      nil -> nil
    end
  end

  defp slug(title) do
    title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
  end

  @doc """
  The short guide: the opening, then the sections an agent needs to work a
  board (`#{Enum.join(@core, ", ")}`), then the names of the rest, each one
  for the asking with `section/2`.
  """
  def short(opts \\ []) do
    all = sections(opts)
    by_key = Map.new(all, fn {key, _, text} -> {key, text} end)
    {_, _, intro} = hd(all)

    others =
      all
      |> Enum.reject(fn {key, _, _} -> key == "intro" or key in @core end)
      |> Enum.uniq_by(fn {key, _, _} -> key end)
      |> Enum.map_join("\n", fn {key, title, _} -> "- `#{key}` — #{title}" end)

    Enum.join([intro | Enum.flat_map(@core, &List.wrap(by_key[&1]))], "\n") <>
      """

      ## The rest of the guide

      This is the short guide. Each section below is one `get_guide` call
      away, with `section` set to its name (`section: "all"` gives the whole
      guide, as `GET /api/guide` does):

      #{others}
      """
  end

  @doc """
  One section of the guide by key (see `sections/1`), `"all"` for the whole
  thing. `{:error, message}` names the keys there are when `key` is not one.
  """
  def section("all", opts), do: {:ok, markdown(opts)}

  def section(key, opts) do
    all = sections(opts)

    case Enum.find_value(all, fn {k, _, text} -> k == key && text end) do
      nil ->
        keys = all |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Kernel.++(["all"])
        {:error, "no section #{inspect(key)} in the guide; there are: #{Enum.join(keys, ", ")}"}

      text ->
        {:ok, text}
    end
  end

  @doc "The same thing for programs: the markdown plus the generated parts on their own."
  def json(opts \\ []) do
    %{
      guide: markdown(opts),
      vocabulary: vocabulary(),
      endpoints: Enum.map(endpoints(), fn {verb, path} -> %{method: verb, path: path} end)
    }
  end

  @doc "The vocabularies the API validates against, as data."
  def vocabulary do
    %{
      priorities: Card.priorities(),
      priority_order: ~w(critical high medium low none),
      flags: Card.flags(),
      list_categories:
        Enum.map(Column.categories(), fn {k, label} -> %{key: k, label: label} end),
      link_kinds:
        Enum.map(CardLink.kinds(), fn {k, out, in_} -> %{key: k, from: out, to: in_} end),
      health: StatusUpdate.health_keys(),
      date_precisions: Slipdock.Dates.precision_keys(),
      colors: Slipdock.Palette.names(),
      automations: Slipdock.Automations.Spec.vocabulary()
    }
  end

  ## Sections -----------------------------------------------------------------

  defp intro(base) do
    """
    # Slipdock for agents

    This is how to drive `#{base}` as your work tracker: the model, the
    conventions these boards expect, how to decide what to do next, and what to
    write back while you do it. Read it at the start of a session. The board is
    what the person who owns it reads afterwards to find out what happened, so
    treat keeping it true as part of the work, not as reporting overhead.

    Three things, if you remember nothing else:

    1. **Top-level cards are epics; the work is in their subcards.** Finish an
       epic's subcards before starting the next epic.
    2. **Take work from the top.** The *To Do* list first, the *Backlog* only
       when To Do has nothing eligible; highest priority first, position in the
       list breaking ties; skip anything blocked.
    3. **Write as you go.** Move a card to *In Progress* when you start it,
       comment at every decision or surprise, flag it when you are stuck, and on
       finishing set `completed: true` *and* move it to *Done*. A board that
       lags behind the work is worse than no board.
    """
  end

  defp getting_in(base, user) do
    who =
      case user do
        nil ->
          """
          You are reading this without a token, so the guide has no idea which
          boards you can see. Get one and re-read it: the last section then
          lists your boards, their lists and what each list means.
          """

        user ->
          """
          Your token works: you are **#{user.email}**#{if user.name, do: " (#{user.name})"}.
          That email is what you pass as `assignee` to put a card in your own name.
          """
      end

    """

    ## Getting in

    Every endpoint but this one needs an API token:

        curl -s -H "Authorization: Bearer $SLIPDOCK_TOKEN" #{base}/api/me

    #{String.trim(who)}

    **If you have no token, ask for one — you do not need access to this
    server.** `slipdock auth` does the whole thing; by hand it is two calls:

        curl -s -X POST #{base}/api/auth/device \\
          -H 'content-type: application/json' \\
          -d '{"label": "what you are", "scope": "write"}'

    `scope` is `read` or `write`. Asking for `admin` this way is refused with
    `invalid_scope`: an admin token is made by an admin on the account page.

    That answers with a `user_code` and a `verification_uri`. Show both to the
    person and ask them to approve it in a browser. Then poll, no faster than
    the `interval` it gave you:

        curl -s -X POST #{base}/api/auth/device/token \\
          -H 'content-type: application/json' \\
          -d '{"device_code": "..."}'

    `authorization_pending` means keep waiting; `slow_down` means you are
    polling too fast and should wait longer, not retry harder; `access_denied`
    means they said no; `expired_token` means start again. Success hands back a
    `token`. The code lasts ten minutes and works once.

    **Save what you are given**, so the next session does not have to ask the
    person again: the token in `~/.config/slipdock/token` (mode 600), and this
    server's address in `~/.config/slipdock/url`. Both files are where the CLI
    and the skills look. `$SLIPDOCK_TOKEN` and `$SLIPDOCK_URL` override them.
    The CLI also keeps one token per server under `~/.config/slipdock/tokens/`
    and sends each only to the server that issued it; `slipdock auth` writes
    both. Never send a token to an address other than the one it came from.

    If you have none of the skills installed and would like them —
    the wiki, documents, working a backlog unattended — one line fetches them
    into `~/.claude/skills` and needs nothing but `curl` and `tar`:

        curl -fsSL #{base}/install.sh | sh

    On Windows, in PowerShell (into `%USERPROFILE%\\.claude\\skills`, which
    WSL's `install.sh` would miss):

        irm #{base}/install.ps1 | iex

    `401` means no token or a dead one — ask for a new one rather than guessing.
    `403` means the token is good but that board or card is not yours to
    change; say so rather than working around it. A board you cannot read at
    all is a `404`, the same as one that does not exist — and a board's name or
    code only ever means one of yours (or one shared with you), never somebody
    else's that happens to be called the same. Two `403`s name the **token**
    instead, and mean it is deliberately limited rather than anything being
    broken — report them, do not retry:

    - `this API token is read-only` — granted read access only.
    - `this API token's scope doesn't allow it` — confined to certain boards.

    `402` is a limit, and always carries `"retryable": false` because it is not
    a fault in your request: fixing the title and trying again will fail
    identically, forever. Tell the person and stop. `GET /api/me` says where
    they stand before you start — `cards` for the item count, `limits` for all
    of it.

    - `card_limit_reached` — the board's owner has used up the **items** their
      account allows. A card, a wiki page and an uploaded file each count as
      one, so writing it up as a page instead will not get round it. Suggest
      archiving something finished with.
    - `board_limit_reached` — they own as many boards as this server allows one
      person. Sub-boards, the ones behind subcards, do not count.
    - `storage_limit_reached` — their uploaded files fill the space allowed.
      Only deleting attachments frees it; archiving the card does not.
    - `trial_expired` — a free trial has run out. Nothing new can be added
      anywhere on their boards; everything already there stays editable. They
      have to subscribe.

    Not only creating meets these. Restoring something archived asks for it
    back into the count; moving a card onto a board somebody else owns counts
    it, its subcards, their pages and their files against *that* owner; an
    import counts its archived rows too; and `POST /api/boards/welcome` needs
    room for the whole tour.

    Reads are `GET`, writes are `POST` or `PATCH`, and bodies are JSON with
    `Content-Type: application/json`. Boards, lists, tags, templates and saved
    views can be addressed by name as well as by id — `/api/boards/3` and
    `/api/boards/Roadmap` both work, case-insensitively — but names are
    ambiguous and get renamed, so use the id once a response has told you one.
    A board also has a `code`: a short, unique handle of its own (“QVM V1
    Remediation” is `qvm-v1-rem`) that addresses it too — `/api/boards/qvm-v1-rem`.
    It is generated from the name and can be edited, so it is stabler than a
    name but still not the id.
    Every write appears instantly in anyone's open browser and is recorded in
    the board's activity log, so there is no need to announce changes twice.

    A `slipdock` CLI wraps all of this (`slipdock --help`) if the machine you are on
    has it. The API is the contract; the CLI is a convenience.

    ### Over MCP

    A client that speaks the Model Context Protocol can use this server as an
    MCP server at `#{base}/mcp`: stateless Streamable HTTP, authenticated with
    the same bearer token as the API, or by signing in through the browser
    (OAuth 2.1 with dynamic client registration and PKCE — the way claude.ai
    and the Claude apps connect; discovery starts from the `401` that `/mcp`
    answers without a token). It offers a small set of tools rather
    than the whole API: `whoami`, `get_guide` (this text: a short
    form by default, ending with the names of the other sections, and one of
    them with `section`), `list_boards`,
    `get_board`, `list_cards` (`full: true` gives every card as `get_card`
    does, comments, checklist and docs included, so a whole board reads in
    one call), `get_card`, `search`, `read_page`, `list_pages` (a
    board's wiki, flat or with `tree` nested), `page_info` (by
    `what`: a page's `links` or `sections` — the heading paths
    `write_page` takes — a board's `wanted` pages, or `resolve` a
    title), `page_history` (a page's revisions, or with `rev` or
    `diff` the change one save made, and with `against` the
    change between any two), `activity` (the
    board's log, or with `card` one card's), and for
    writing `create_card`, `update_card` (fields, flags, tags, assignees,
    dependencies and the checklist), `move_card` (to another board too),
    `comment`, `complete_card`, `archive_card` (and restore), `delete_card`,
    `create_list`, `delete_list`, `create_board`, `archive_board` (and
    restore), `delete_board`, `write_page`, `update_page` (a page's
    title, summary, parent, position and folder, archiving and restoring it,
    and pinning it to a card) and `revert_page` (a page
    back to a revision, as a new one, against `base_hash`), and `claim_job`,
    `job_progress` and `finish_job` to take runner jobs from a board's
    queue (see "Runners" below). Archiving is the undoable way
    to put something away; the deletes are not undoable, so `delete_card`
    needs `confirm: true`, `delete_board` needs `confirm` set to the board's
    code, and `delete_list` refuses a list holding cards unless
    `with_cards: true`. A read-only
    token, or a connection the person approved read-only, can call the read
    tools, and a write tool answers it with an error saying so. The conventions in this guide apply the same way through
    either door.

    ### The AI key, and which model answers

    Anything that asks a language model — the written answer from
    `POST /api/ask`, writing an automation rule in English, the chat and edit
    panels, the narrative — runs on the **account holder's own** key or
    endpoint, kept on the server and never shared between people.

    **Search is the exception.** `GET /api/search` (the MCP `search` tool,
    `slipdock search`), the index behind it and scheduled automations run on
    the **server's** AI: one admin's settings, chosen by an admin under
    Configuration → AI for search and automations. One index can only be
    searched with the model that built it, so it cannot be yours. Your own key,
    endpoint and `embed_model` change nothing about search (`embed_model` is
    read only for the admin chosen there), and `/api/ask` needs both: the
    server's AI to find the cards, yours to write the answer. A search that
    answers `Semantic search isn't set up on this server` is for an admin to
    fix — tell the user that, and do not retry or ask them for a key.

    `GET /api/me` says what yours is:

        "ai_key": {"configured": true, "masked": "sk-or-v1…10d8",
                   "set_at": "2026-10-01T15:56:49Z", "ai_available": true},
        "ai": {"base_url": "https://openrouter.ai/api/v1", "own_endpoint": null,
               "model": "google/gemini-2.5-flash-lite", "own_model": null,
               "embed_model": null}

    `configured: false` with `ai_available: false` means those endpoints will
    answer `AI features need a model to talk to` and nothing you do to the
    request will change it — say so rather than retrying.

    There are two ways to give them one:

    * **A key**, for the server's endpoint (OpenRouter by default):
      `PUT /api/me/ai-key {"api_key": "sk-or-…"}` (`slipdock ai-key <key>`),
      removed with `DELETE /api/me/ai-key`. Billed to its owner's OpenRouter
      account, so never put somebody else's key on your account, and never
      read a key back out of a file and quote it anywhere.
    * **An endpoint of your own** — any OpenAI-compatible chat completions API,
      typically a model server on the same network, which usually wants no key
      at all and sends nothing off it:

          PUT /api/me/ai-provider {"base_url": "http://llm.local:1234/v1",
                                   "model": "qwen/qwen3.5-9b"}

      (`slipdock ai-endpoint <url>`, then `slipdock ai-model <id>`.) Only the
      fields you send change; `""` clears one, so `{"base_url": ""}` goes back
      to the server's default. `GET /api/me/ai-models` (`slipdock ai-models`)
      lists what that endpoint can run, which is where a `model` id comes
      from — an id from OpenRouter means nothing to a local server, and the
      other way round. Both are also in the web UI under
      **Account → AI model**.
    """
  end

  defp model do
    """

    ## The model

    - **Board** — the root of a tree. `GET /api/boards` lists root boards only.
      Every board has a `code` as well as a name: a short, unique, URL-safe
      handle of at most 10 characters, taken from the name ("QVM V1
      Remediation" is `qvm-v1-rem`) and editable in board settings. It
      addresses the board anywhere `:board` appears, and unlike a name it is
      unambiguous — use it when you have no id, and say it back to the user as
      the short name of the board. A `shortcut` sits alongside it: one or two
      characters that jump to the board in the web app (the user presses `b`,
      then that key). It is settable, but it does not address anything — do
      not use it in a URL. A board belongs to one person: `owner` names them
      (`{"id", "email", "name"}`; it is fixed when the board is made and no
      request changes it), and `shared` is true when that person is somebody other than
      you — a board you reach through a grant rather than your own. Say whose
      board it is when you name one that is not theirs.
    - **List** (a column) — ordered, and carrying a `category`: `todo`,
      `doing`, `done`, `dropped`, or null for "no particular meaning". The
      *names* differ from board to board (To Do / Now / Ready; Done / Shipped);
      the categories do not. **Decide what a list means from its category, not
      its name.** A list with none can be given one:
      `PATCH /api/boards/:board/columns/:id {"category": "todo"}`
      (`slipdock set-column B "To Do" --category todo`). A list may also carry a `horizon` (the date range it stands
      for) and a `wip_limit`. Deleting a list never takes its cards unless asked to
      outright (see *What not to do*). How the web app draws a list's cards is
      the list's own setting: `sort_by` (null for the order they were dragged
      into, or `created`, `updated`, `start_date`, `due_date`, `priority`),
      `sort_dir` (`asc`, `desc`) and `group_by` (null, `flag`, `tag`,
      `start_date`, `due_date`) — `slipdock set-column B "To Do" --sort due_date
      --group flag`. It only changes the drawing: a card's `position` is still
      where it was put, and *top of the list* still means lowest `position`.
    - **Card** — one unit of work: title, description, `priority`, `flags`,
      `tags`, `start_date`, `due_date`, `completed`, `percent_complete` (0–100,
      or null when nobody has said), `assignees` (everybody it is assigned to,
      lead first) and `assignee` (the lead alone), `position` within its list.
      `archived_at` is set on archived cards.
    - **Time** — a card's `time` says how long has gone on it against its
      estimate: `unit` (`minutes`, `hours`, `days`, `weeks`, `months`), `spent`
      and `estimate` in that unit, the same as `spent_minutes` and
      `estimate_minutes`, `percent` of the estimate (past 100 when it has
      overrun; null without one) and `timer_running` / `timer_started_at`.
      `spent` includes a running timer. Write `time_spent`, `time_estimate`
      and `time_unit` on the card — a bare number is in the card's unit,
      `"90m"`, `"1.5h"`, `"2d"`, `"1w"`, `"1mo"` say their own, and a day is 8
      hours, a week 5 days, a month 4 weeks — or `log_time` to add to what is
      spent (`"-30m"` takes off). `POST /api/cards/57/timer
      {"action": "start"}` runs the card's timer and `"stop"` adds what it ran.
      Log the time your own work took when the person asks you to; do not
      leave a timer running across sessions.
    - **Subcards** — any card can own a board of its own. On the card that is
      `sub_board`; the subcards are that board's cards. Sub-boards nest to any
      depth. This is the hierarchy you will do most of your thinking in.
    - **Checklist** — ticked steps inside a card. No dates, no comments, no
      status: the cheapest possible unit.
    - **Comments** — the card's narrative, and where you explain yourself.
      `@handle` (the part of someone's email before the "@") in a comment or
      a description mentions a person who can see the board, and emails them
      a link to the card — so mention somebody when you need their attention,
      not as a signature, and never yourself.
    - **Flags** — `flagged`, `blocked`, `review`, `waiting`, `starred`. Hand-set
      labels, independent of the computed `blocked`.
    - **Dependencies** — `blocked_by` / `blocks` between cards, with cycle
      detection. `blocked: true` is computed: something it waits on is still
      open. The two cards may be on different boards — a subcard waiting on
      another epic's subcard, or on a card on another board altogether —
      which needs write access to the blocked card and read access to the
      blocker. A stub on another board carries that board's `board` code; one
      on a board you can't read says `"hidden": true` and "A card you can't
      see" in place of its title, but still counts towards `blocked`.
      Distinct from **links** (`relates`, `contributes`, `duplicates`),
      which are cross-references and carry no scheduling meaning.
    - **Rollup** — a read-only summary of everything beneath a card: `done` and
      `total` leaves, effective `start`/`due` (its own or its subcards'),
      `start_slip_days` and `due_slip_days` (how far the subcards begin and end
       past the card's *own* start and due dates — `slip_days` is the old name
       for the due one), `blocked`, `overdue`, `health`, `depth`. Trust it instead of
      walking the tree to count.
    - **Web links** (`urls`) — references out of the system: a page, a shared
      drive, a file elsewhere. Each is datestamped with `added_at`. Add one
      with `POST /api/cards/:id/urls {"url": "…", "title": "…"}`, remove it
      with `DELETE /api/cards/:id/urls/:url_id`. Use these for anything that
      lives outside the board; `attachments` are files the board itself holds.
    - **Moving a card to another board** —
      `POST /api/cards/:id/move {"board": "errands", "column": "To Do"}`. The
      card's subcards, comments, history and links go with it, its tags travel
      by name (made on the destination where they are new), and its custom
      field values survive only where that board has a field with the same key
      and kind. The reply's `moved` says what that cost:
      `{"tags_created": 1, "fields_dropped": 0, "milestones_unpinned": 0}` —
      repeat it back to the user rather than letting them find out later. Write
      access is needed on both sides, a card cannot be moved into its own
      subcards, and an archived card must be restored first. Leave `board` out
      and this is the ordinary within-board move, where `index` still applies.
    - **Favourites** — the handful of things the person keeps going back to: a
      board, a list, a card or a saved view. They are *personal*, so
      `GET /api/favourites` is the token holder's own set and nobody else's,
      and it is worth reading at the start of a session: it says where this
      person actually works, which a list of boards does not. Each entry gives
      a `kind`, a `name`, its `board` and the `url` that opens it. Add one with
      `POST /api/favourites {"kind": "card", "id": 42}` (`kind` is `board`,
      `column`, `card` or `view`) and remove it with
      `DELETE /api/favourites/:kind/:id`. Favouriting changes nothing about the
      thing itself, so read access is enough — and never favourite on someone's
      behalf unless they asked.
    - Also on a card, and safe to ignore until you need them: `status_updates`
      (a stated `on_track` / `at_risk` / `off_track` with a note), custom
      `fields` and formula `scores`, `votes`, `attachments`, `milestones` on the
      board, and saved views.

    The parts of a card's JSON that matter while you are working:

    ```json
    {
      "id": 42, "board_id": 1, "column_id": 4, "column": "To Do", "position": 0,
      "title": "Query parser", "description": "…",
      "priority": "high", "flags": ["review"], "tags": ["api"],
      "start_date": null, "due_date": "2026-10-03", "completed": false,
      "percent_complete": 40,
      "archived_at": null, "assignee": {"id": 1, "email": "you@example.com"},
      "blocked": true,
      "blocked_by": [{"id": 7, "title": "Schema", "completed": false, "archived": false,
                      "board_id": 3, "board": "platform", "hidden": false}],
      "blocks": [],
      "sub_board": {"id": 9, "name": "Query parser", "completed": 2, "total": 5},
      "rollup": {"done": 2, "total": 5, "due": "2026-10-10", "start_slip_days": 0, "due_slip_days": 0,
                 "blocked": true, "overdue": false, "health": "at_risk", "depth": 2},
      "checklist": {"done": 1, "total": 3,
                    "items": [{"id": 11, "text": "empty state", "done": false}]},
      "comments": [{"id": 5, "body": "…", "inserted_at": "…"}]
    }
    ```

    `sub_board` and `rollup` are `null` on a leaf card — that is how you tell a
    task from an epic.
    """
  end

  defp epics do
    """

    ## Epics and subcards

    The shape these boards want:

    ```
    Board "Slipdock app"                        a project, or a stream of work
    └── Card "Search"                         EPIC: an outcome, top level
        └── sub-board "Search"                the epic's own lists
            ├── Card "Index cards on write"   TASK: one sitting, one agent
            ├── Card "Query parser"
            └── Card "Search box in the header"
                └── checklist: empty state, keyboard shortcut   trivia
    ```

    - An **epic** is a top-level card on a root board. It names an outcome, not
      an action — "Search", not "add an index". It holds the priority, the due
      date, the tags and the discussion for everything under it, and it is never
      worked directly: its job is to hold subcards.
    - A **task** is a subcard: something one agent can finish in one go and
      describe in a sentence. Tasks carry their own position, priority, flags,
      comments and completion. This is what you actually do.
    - A **checklist item** is a step inside a task that is not worth a card of
      its own. If it needs a date, a comment or a status, promote it to a
      subcard instead.
    - Two levels (epic → task) is the norm. Three means the epic is really a
      programme, which is fine — sub-boards nest as deep as you like. Four
      usually means the tree is being used as a to-do list and wants flattening.

    Give an epic its subcards, then fill them:

        POST /api/cards/42/subboard        {"template": "Simple"}
        POST /api/boards/9/cards           {"title": "Query parser", "column": "To Do"}

    A new board takes its lists from `template`, or sets its own out with
    `POST /api/boards {"name": "Hiring", "columns": ["Applied", "Interview",
    "Done"], "save_template": "Hiring"}` — names like To Do, In Progress and
    Done get those roles, and `save_template` (a name, or `true` for the
    board's) keeps the lists as a new template in the same request.

    `GET /api/templates` lists the named sets of lists a new sub-board can be
    built from; the response to `POST …/subboard` includes the new board, whose
    `id` is what you add cards to. `DELETE /api/cards/42/subboard` removes the
    sub-board **and every card on it**, so treat it as a delete.

    **Sprints.** A board whose `kind` is `"sprints"` (made from the "Sprint
    planning" template, or `PATCH /api/boards/:board {"kind": "sprints"}`) has
    a sprint on every card, and the sprint's work as its subcards. `POST
    /api/boards/:board/sprints` makes the next one — `name`, `start`, `days`
    and `goal` all optional; it counts on from the last "Sprint N" and starts
    the day after it ends — with its sub-board already there.
    `POST /api/cards/:sprint/sprint {"cards": [41, 42]}` moves cards from any
    board you can write to into it, subcards and all, and answers what it
    `added` and what it `skipped` and why. Only plan a sprint when asked to:
    moving cards out of their epics is the person's call.
    Each card added leaves a **stand-in** where it was: a card whose
    `stand_in_for` is `{"id", "title", "board_id", "status"}` — the real card,
    and `status` from its list's category (`todo`, `doing`, `done`,
    `dropped`, or `archived` / `deleted`). It is not work: do not pick it up,
    edit it (a `PATCH` is refused) or count it — act on the card it names.
    It goes by itself when that card is moved back to its board.
    A sprint board keeps the boards and lists its sprints are planned from:
    `PUT /api/boards/:board/sprints/sources {"sources": [{"board": "work",
    "lists": ["To Do", "Backlog"]}]}` (no `lists` means every list that is
    not done or dropped; `[]` clears them), read back with `GET` on the same
    path and as the board's `sprint_sources`. `GET
    /api/cards/:sprint/sprint/plan` is the planning view over them: every
    source list's open cards with `priority`, the board's formula `scores`
    (RICE and the like), `votes`, `estimate_minutes` (the card's own, else its
    open subcards' — `estimate_from_subcards`) and `subcards` done/total,
    plus what the sprint holds already under `committed`; `?sort=` is
    `position`, `score`, `priority` or `estimate`. Read it before proposing
    what goes in a sprint, and add the estimates up from it rather than
    guessing.
    `GET /api/cards/:sprint/burndown` is how much of a sprint's work was open
    at the end of each day against the ideal line, and `GET
    /api/boards/:board/sprints/velocity` is committed and completed per sprint
    with the average of the finished ones — read them when asked how a sprint
    is going rather than counting cards yourself. Every card carries
    `completed_at`, the moment it was last completed.

    **Simple boards.** A board with `"simple": true` is a plain to-do list
    (`PATCH /api/boards/:board {"simple": true}`, `slipdock set-board B
    --simple`; a new sub-board takes it from its parent). The web app hides
    % complete, start dates, health, time tracking, votes and dependencies
    on its cards, and leaves Timeline and Prioritise out of its views; a
    board's JSON lists the hidden card fields as `hidden_facets`. The API
    still reads and writes all of them — nothing is deleted — but on a
    simple board, keep to what the person can see: do not set `--percent`,
    start dates, estimates or dependencies there unless asked to.

    Tags live on the root board and are shared by the whole tree, so a tag made
    anywhere below it is available everywhere — but a tag must exist before a
    card can wear it (`POST /api/boards/:board/tags`). Renaming an epic renames
    its sub-board (a board name is at most 80 characters, so a longer title is
    cut short with an ellipsis).

    **Where new work goes.** Work you discover mid-task belongs under the epic
    it serves, as a subcard — not as a new top-level card, and not silently
    folded into the card you are on. Open a new epic only for a genuinely new
    outcome, and give it a sub-board immediately so it cannot become a task in
    disguise. If the new work blocks what you are doing, add the dependency
    (`POST /api/cards/:id/dependencies {"blocked_by": <new id>}`) rather than
    just leaving a comment about it.
    """
  end

  defp choosing(base) do
    """

    ## Choosing what to do next

    Depth first, from the top. Unless the person told you which card to work
    on, this is how to pick one.

    **1. Pick the board.** `GET /api/boards`. If more than one could plausibly
    be meant, ask instead of guessing.

    **2. Read it whole.** `GET /api/boards/<id>` returns every list, in order,
    with its `category` and its cards in list order — one call, everything you
    need to choose.

    **3. Pick the list to draw from,** in this order:

    a. a `doing` list that already holds an unfinished card — work in progress
       is finished before new work is started;
    b. the **ready** list: the `todo` list that means "ready now" (*To Do*,
       *Now*, *Ready*, *Selected*, *Next*);
    c. the **backlog**: any other `todo` list (*Backlog*, *Later*, *Icebox*),
       and only when (b) has nothing eligible.

    Ignore `done` and `dropped` lists. A board with one `todo` list makes this
    trivial. Older boards often carry no categories at all — then go by name and
    position, left to right; the last section of this guide has already worked
    that out for each of your boards. Ask if it is genuinely unclear.

    **4. Drop the ineligible.** From that list's cards, discard any where:

    - `completed` is true, or `archived_at` is set;
    - `blocked` is true, or any `blocked_by` entry is neither `completed` nor
      `archived` — the thing it waits for is still open;
    - `flags` contain `blocked` or `waiting` — somebody has said by hand that
      this is not ready;
    - `assignees` has someone else on it, unless you were asked to pick their
      work up — or to pair on it.

    **5. Order what is left.** Highest priority first
    (`#{Enum.join(~w(critical high medium low none), " > ")}`), then `position`
    ascending — the top of the list wins a tie, because that is where the person
    who owns the board put the next thing. Two exceptions worth respecting: a
    card already overdue (`due_date` today or past) outranks priority, and a
    card that `blocks` several others is worth doing before its peers.

    **6. Descend before you move on.** If the card you picked has a `sub_board`,
    it is an epic: `GET /api/boards/<sub_board.id>` and run steps 3–6 again
    inside it. Keep descending until you reach a card with `sub_board: null` —
    that leaf is the task you actually do. Then work *that epic's* remaining
    subcards to done before going back up for the next top-level card. An epic
    with no sub-board and no obvious single action is a sign it needs breaking
    up (see above), not a sign to improvise.

    **7. Nothing eligible?** Say so, and say why — everything done, everything
    blocked on X, the backlog is empty — and stop. Do not invent work, and do
    not take a card you ruled out in step 4 because it was the only one left.

    A first pass in one call, with the obvious exclusions applied:

    ```sh
    curl -s -H "Authorization: Bearer $SLIPDOCK_TOKEN" #{base}/api/boards/1 | jq '
      [ .board.columns[]
        | select(.category == "doing" or .category == "todo")
        | {list: .name, category, position,
           cards: [ .cards[]
             | select(.completed == false and .blocked == false
                      and (.flags | index("blocked")) == null
                      and (.flags | index("waiting")) == null)
             | {id, title, priority, position, due: .due_date,
                epic: (.sub_board.id // null)} ] } ]'
    ```

    Order the handful that come back yourself — it is a short list and the
    tie-breaks above need judgement.
    """
  end

  defp working do
    """

    ## Working a card

    ### Claim it, before the first edit anywhere else

        POST  /api/cards/57/move        {"column": "In Progress"}
        PATCH /api/cards/57             {"assignee": "you@example.com"}
        POST  /api/cards/57/comments    {"body": "Starting. Plan: …"}

    A card can have several people on it. `assignee` (or `assignees`, a list)
    replaces whoever is there; to join a card somebody else already holds
    without taking it off them, send `{"add_assignees": ["me"]}`, and
    `remove_assignees` to step off. `"me"` is whoever the token belongs to.
    Only somebody who can open the card can be put on it: share the board
    with them first. Anybody else — no account, or an account you have no
    board in common with — is the same `404 user …`, so the answer says
    nothing about who has an account here.

    Move the epic above it into its own `doing` list too, so the top of the
    board reads true while you are inside the tree. `move` takes an optional
    `index`: `"top"`, `"bottom"` (the default) or a number.

    ### While you work

    - **Every decision, surprise or dead end → a comment.** Short, specific,
      and written for someone who will read it in a month: what you chose, what
      you rejected, the commit or file it landed in. This is the part people
      actually value, and the part agents skip.
    - **A long job → say so while it is still running.** Anything that will
      take more than a short sitting — a big refactor, a migration, a build you
      are babysitting — gets interim comments at its milestones, not one
      write-up at the end: what has landed, what is left, whether the shape of
      it has changed. Move the number with it, so the board reads true without
      anyone opening the card:

          PATCH /api/cards/57             {"percent_complete": 40}
          POST  /api/cards/57/comments    {"body": "Parser done, codegen next; …"}

      A card sitting in `doing` for hours with nothing newer than the move on
      it looks abandoned, and someone will come and ask.
    - **A step done → tick it.** `POST /api/checklist/<item_id>/toggle`
      (item ids come from `GET /api/cards/<id>`). Add items as you discover
      them: `POST /api/cards/57/checklist {"text": "…"}`.
    - **Stuck on another card:** add the dependency and the flag, and say what
      you are waiting for.

          POST  /api/cards/57/dependencies   {"blocked_by": 7}
          PATCH /api/cards/57                {"add_flags": ["blocked"]}
          POST  /api/cards/57/comments       {"body": "Waiting on #7: …"}

      Leave it in the `doing` list only if you are coming back to it this
      session; otherwise move it back to the ready list so it is not pretending
      to be in flight.
    - **Stuck on a person** — a decision, a credential, an approval:
      `{"add_flags": ["waiting"]}`, plus a comment naming exactly what you need.
    - **Needs a human eye before it counts as done:** `{"add_flags": ["review"]}`
      and leave it in `doing`.
    - **The task turns out to be several:** give it a sub-board and split it
      (`POST /api/cards/57/subboard {"template": "Simple"}`), rather than
      quietly doing three things under one title.
    - **The estimate is slipping:** `POST /api/cards/57/status`
      `{"health": "at_risk", "body": "…"}`, and fix the `due_date` if you know
      the new one. Silence plus a late card is the worst outcome.
    - `PATCH` takes `add_flags` / `remove_flags` and `add_tags` / `remove_tags`
      to adjust in place; plain `flags` or `tags` *replace* the whole set, which
      is how you accidentally drop someone else's flag.

    ### Finish it

    If the work lives in a git repository, commit it before you close the
    card — one commit (or a PR) per card, its message naming the card
    (`#57`). Put a link to the commit, or to the PR if you opened one, in the
    closing comment, so whoever reads the card can go straight from it to the
    change. No remote to link to? Give the short hash and branch instead.

        POST  /api/cards/57/comments   {"body": "Done: <what changed, where, tests>\\n\\nCommit: <commit or PR URL>"}
        PATCH /api/cards/57            {"completed": true,
                                        "remove_flags": ["blocked", "waiting", "review"]}
        POST  /api/cards/57/move       {"column": "Done"}

    Tick or remove any checklist items left over — a card marked done over an
    unticked list is a lie someone has to investigate. `completed` and the
    `done` list are two separate facts and you set both: the list is where
    people look, the flag is what filters, rollups and reports count.

    ### Finish the epic

    An epic spanning several sittings gets its own progress comment as each
    subcard closes — one line on what that subcard delivered and what is next —
    so the outcome has a readable history without anyone reading every subcard.

    Only when its subcards really are all done. Re-read it and check the
    rollup — `rollup.done == rollup.total` and `rollup.blocked == false` — then
    comment what the epic delivered, mark it `completed` and move it to `done`.
    If some subcards remain, leave the epic in `doing` and move on to the next
    subcard: an epic closed over open children hides work.

    ### Ending a session mid-card

    Comment where you got to, what you would do next, and anything you learned
    that is not in the code; set `at_risk` if it is at risk. Then either leave
    it in `doing` because you are coming straight back, or move it back to the
    ready list. Never leave a card in `doing` with no comment newer than the
    move — nobody can tell whether it is alive.

    ### What not to do

    - **Do not `DELETE` cards.** `POST /api/cards/<id>/archive` is reversible
      (`/restore`); delete is not. Delete only what you created by mistake in
      the same session, or what you were explicitly asked to delete. The same
      goes for `DELETE …/subboard`, which takes every subcard with it.
    - **Do not delete a list to tidy a board.** `DELETE /api/boards/:board/columns/:id`
      only removes an empty list: one that still holds cards, archived ones
      included, is refused with 409 `list_not_empty` and a count. Move the cards
      elsewhere first. `DELETE /api/boards/:board/columns/:id/recursive`
      deletes the list and every card in it, subcards too, and cannot be
      undone: use it only when the person asked for exactly that.
    - **Do not complete an epic with open subcards**, or move a card to `done`
      without `completed: true` (or the reverse).
    - **Do not rewrite a card's title or description to match what you actually
      did.** If the scope changed, say so in a comment and let the person
      decide; the title is their record of what they asked for.
    - **Do not tidy.** Reordering lists, renaming things, re-prioritising other
      people's cards, archiving stale cards — all reasonable, none of it yours
      to do unasked. Archiving or reordering a whole *board* is further still
      from your business: do it only when you were asked to, by name.
    - **Do not touch boards you were not asked about**, even when a search turns
      them up.
    - **Do not work the “Getting Started” board.** It is the tour this server
      builds for a new account, and its cards are instructions for a person —
      "drag this card to Done", "open a card and look down the side". Doing
      them teaches nobody anything and finishing them is a lie about what you
      did. If you were pointed at it by mistake, say so and ask which board was
      meant. `POST /api/boards/welcome` builds a fresh one for the token's
      owner, if they want the tour back after archiving it.
    """
  end

  # Semantic search is the one thing here an agent cannot work out from the
  # endpoint list, because the endpoint list doesn't say *when* to reach for it.
  defp finding(base) do
    """

    ## Finding something nobody can name

    `GET /api/boards/<id>/cards?q=…` filters by substring: the right tool when
    you know a word that is in the title. Its other filters answer the
    questions that are about state rather than words — `due=overdue`,
    `due=week`, `deps=blocked`, `assignee=me`, `priority=high`, `flag=review`,
    `completed=false`, `kind=document` — and they mean exactly what the same
    words mean in a swimlane or a table, because they are the same filters. A
    value that is not one of the listed buckets is a `400`, never a silent
    everything.

    `kind` is the one filter that asks what a thing *is* rather than how it is
    doing: `kind=card` or `kind=document`, a document being a card whose whole
    content is the file on it — no description, nothing to tick off, no
    subcards (comments are allowed) — which is
    what "Add a document…" leaves in a list. Every card's JSON says which it
    is in `kind`. Wiki pages are the third kind of thing a list holds and are
    not cards: ask `GET /api/boards/<id>/pages` for those, or filter a view
    with `kinds=page` (below), which is the one place all three are counted
    together.

    `GET /api/search?q=…` is different. It searches by **meaning**, across every
    card, comment and status update on every board you can see, so the words in
    the query need not appear anywhere in the result. Reach for it when:

    - the person describes a thing rather than naming it — "the card about the
      refund rounding problem", "whatever we said about the vendor contract";
    - the answer is likely in a **comment** or a status update rather than a
      title, which is where most of what a team actually decided ends up;
    - you do not know which board to look on. Substring search is per board;
      this is across all of them at once.

    Each result is a card, with `matches`: the chunks that matched, each with
    its `kind` (`card`, `comment`, `status_update`) and the text. Read the
    match, not just the title — it is why the card came back. Then
    `GET /api/cards/<id>` for the whole thing before acting on it.

    ```sh
    curl -sH "$H" --get --data-urlencode 'q=what did we decide about refunds' \
      #{base}/search
    curl -sH "$H" --get --data-urlencode 'q=flaky tests' -d board=qvm-v1-rem -d limit=5 \
      #{base}/search
    ```

    `POST /api/ask` is the same search with a model in front of it: ask a
    question in prose and it answers from the tools it is given — the same
    search, one card in full, a board's cards list by list to any depth (so
    it can count), a board's lists and tags, one person's work across every
    board, the activity log for a date range, and this person's alerts. It
    returns `answer`, the `searches` it ran and the `sources` it read. Use
    `/search`
    when you want to pick the card yourself — which is most of the time, and
    always when you are about to change something. Use `/ask` when the person
    asked a question in words and wants an answer rather than a list.

    `GET /api/saved-queries` is what this person has chosen to keep asking —
    their own, and not derivable from the boards. Worth a look alongside
    `/api/favourites` at the start of a session: favourites say where they
    work, saved queries say what they keep wanting to know.

    Both search endpoints are scoped to your token's owner: they can return
    nothing you could not open directly. A token confined to some boards
    searches only those, and `/ask` refuses it with a 403, because the
    assistant reads across every board. If `/api/search/status` says `available: false`, the index
    has not been built — say so rather than concluding there is nothing there.

    """
  end

  defp recipes(base) do
    """

    ## Recipes

    With `H='Authorization: Bearer '$SLIPDOCK_TOKEN` and `#{base}` as the base:

    ```sh
    # who am I, what can I see
    curl -s -H "$H" B/api/me
    curl -s -H "$H" B/api/boards
    curl -s -H "$H" "B/api/boards?archived=all"   # archived boards too (see below)

    # a whole board: lists, categories, cards in order
    curl -s -H "$H" B/api/boards/1

    # one card in full (checklist item ids, comments, deps, rollup)
    curl -s -H "$H" B/api/cards/57

    # filtered cards: open work in one list, by priority, by flag, by text
    curl -s -H "$H" "B/api/boards/1/cards?completed=false&column=To%20Do"
    curl -s -H "$H" "B/api/boards/1/cards?priority=high&flag=blocked&q=search"

    # by date, by dependency, by person: due=overdue|today|week|month|has|none,
    # deps=blocked|ready|blocking|violated|free, assignee=EMAIL|NAME|me|none
    curl -s -H "$H" "B/api/boards/1/cards?due=overdue"
    curl -s -H "$H" "B/api/boards/1/cards?deps=blocked&assignee=me"

    # by what it is: kind=card|document (a card that is just the file on it)
    curl -s -H "$H" "B/api/boards/1/cards?kind=document"

    # archived cards are left out: archived=true for them alone, archived=all for both
    curl -s -H "$H" "B/api/boards/1/cards?archived=all"

    # create an epic, give it subcards, add a task
    curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/cards \\
         -d '{"title": "Search", "column": "To Do", "priority": "high", "tags": ["api"]}'
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/42/subboard \\
         -d '{"template": "Simple"}'
    curl -s -H "$H" -H 'content-type: application/json' B/api/boards/9/cards \\
         -d '{"title": "Query parser", "column": "To Do", "due_date": "2026-10-03"}'

    # claim, comment, tick, finish
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/move \\
         -d '{"column": "In Progress"}'
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/comments \\
         -d '{"body": "Parser handles quoted phrases; see lib/slipdock/search.ex"}'
    curl -s -X POST -H "$H" B/api/checklist/11/toggle
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/cards/57 \\
         -d '{"completed": true, "remove_flags": ["blocked"]}'

    # what happened on this board lately
    curl -s -H "$H" "B/api/boards/1/activity?limit=20"

    # the boards themselves (owner only; ask before doing either)
    curl -s -X POST -H "$H" B/api/boards/1/archive    # put a board away, keeping everything on it
    curl -s -X POST -H "$H" B/api/boards/1/restore    # and bring it back
    curl -s -X POST -H "$H" B/api/boards/welcome      # the Getting Started tour board, again
    curl -s -X POST -H "$H" -H 'content-type: application/json' B/api/boards/order \
         -d '{"boards": ["roadmap", "qvm-v1-rem", 3]}'   # your own order for the index
    ```

    An **archived board** is put away, not deleted: it comes off the board
    index, the board switcher and quick add, but every card, tag, comment and
    automation on it stays, and its link and its API endpoints go on working.
    `GET /api/boards` leaves archived boards out; `?archived=true` lists those
    alone and `?archived=all` lists both, and every board carries
    `archived_at`. Treat an archived board as work the person has deliberately
    set aside.

    The **order** is per person, not per board: `POST /api/boards/order` sets
    the order *you* list boards in and moves nobody else's index. Boards you
    leave out of the list fall to the end, oldest first. `GET /api/boards`
    comes back in your order unless you ask for another with `?sort=` —
    `manual` (yours), `name`, `active`, `newest`, `oldest` or `cards`.

    Errors come back as `{"error": "…"}`, and a failed validation as
    `{"error": "validation failed", "details": {"field": ["…"]}}`. Read the
    message: "column not found" and "tag not found" mean you passed a name that
    does not exist on that board, not that the API is broken.
    """
  end

  # Automations: the one part of the API that goes on working after the agent
  # has gone, so it needs saying plainly what a rule will and won't do.
  defp automations do
    v = Slipdock.Automations.Spec.vocabulary()

    """

    ## Automations and alerts

    A board can carry **rules** that the server runs by itself: when something
    happens to a card (or when enough time passes), do something about it.
    They keep running after you have gone, so treat adding one as a change to
    how the board behaves, not as a way of doing this task — for a one-off,
    just make the change yourself.

    A rule is `{"trigger": …, "conditions": […], "actions": […]}`. Write it
    out and POST it as `spec` and it is stored exactly as given; POST `text`
    instead and the server's model turns a sentence into one for you (which
    needs an API key configured there, and can misread you). **Prefer
    `spec`** — you know the vocabulary, and a spec cannot be misunderstood.
    `GET /api/automations/vocabulary` is that vocabulary as data, with an
    example; it is also under `automations` in the vocabulary below.

    For the common cases there is a shorter way still: POST `preset` and
    `params` — one of the ready-made rules listed at
    `GET /api/automations/presets` (follow a board, a list or a card, hear
    about comments or a field changing, reminders when work is due or has
    gone quiet, tidying Done), filled in with the few fields it asks for.
    No model is involved, and what it stores is an ordinary rule.

    Only a board's owner may list or change its rules. Every rule is checked
    before it is stored: an unknown trigger, action or condition is a 422 with
    the reason, so a rule that saves is a rule that runs.

    An `email` action may only go to people who can read the board — its
    owner and those it is shared with — at most
    #{Slipdock.Automations.Spec.max_recipients()} of them per action, and
    anyone else is a 422 naming them; access taken away later stops the
    email at send time. A rule has at most #{Slipdock.Automations.Spec.max_actions()}
    actions and a board at most #{Slipdock.Automations.max_rules()} rules.
    What rules send is metered: #{Slipdock.Automations.Runner.allowances().emails_per_hour}
    automation emails an hour across everything one person owns, and
    #{Slipdock.Automations.Runner.allowances().callbacks_per_minute} callbacks
    a minute per board; past that the action fails with "held back" in the
    rule's last error, and the next window carries on.

    - **triggers** — #{Enum.map_join(v.triggers, " · ", & &1.type)}
      (the last five are checked on a timer, the rest fire on the event)
    - **conditions** — any number, all must hold; fields
      #{Enum.join(v.condition_fields, ", ")}; ops #{Enum.join(v.condition_ops, ", ")}
    - **actions** — #{Enum.map_join(v.actions, " · ", & &1.type)}
    - text in an action may use #{Enum.join(v.placeholders, " ")}

    ```sh
    # the grammar, with an example you can adapt
    curl -s -H "$H" B/api/automations/vocabulary

    # a rule, written out: move stale work back and say so
    curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/automations \\
         -d '{"name": "Return stale work",
              "spec": {"trigger": {"type": "card_stale", "days": 7, "column": "In Progress"},
                       "conditions": [{"field": "completed", "op": "is", "value": false}],
                       "actions": [{"type": "move_card", "column": "Backlog"},
                                   {"type": "comment", "body": "Untouched for a week, back to the backlog."}]}}'

    # the same thing described in words, for the server's model to write
    curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/automations \\
         -d '{"text": "move anything in In Progress untouched for a week back to Backlog"}'

    # a ready-made rule: hear about every card that arrives in Doing, by email
    curl -s -H "$H" B/api/automations/presets
    curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/automations \\
         -d '{"preset": "follow_list", "params": {"column": "Doing", "notify": "email"}}'

    # list, inspect, switch off, run now, remove
    curl -s -H "$H" B/api/boards/1/automations
    curl -s -H "$H" "B/api/boards/1/automations/Return%20stale%20work"
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' \\
         B/api/boards/1/automations/3 -d '{"enabled": false}'
    curl -s -X POST -H "$H" B/api/boards/1/automations/3/run
    curl -s -X DELETE -H "$H" B/api/boards/1/automations/3
    ```

    Running a rule by hand is how you check it: a timed rule first forgets
    what it has already acted on, then looks again, and the reply says how
    often it fired (`{"fired": 2, …}`) and carries `last_error` if an action
    could not be resolved.

    **Callbacks** are the `webhook` action: when the rule fires, the server
    calls a URL of yours with the card. A `post` (the default), `put` or
    `patch` sends JSON —

    ```json
    {"rule": "Tell the robot", "event": "card_updated", "at": "2026-10-03T12:00:00Z",
     "board": {"id": 1, "name": "Launch", "code": "launch", "url": "B/boards/1"},
     "card": {"id": 42, "title": "Ship it", "url": "B/boards/1/cards/42",
              "column": "In Progress", "priority": "high", "assignee": "David",
              "start_date": "2026-10-20", "due_date": "2026-11-01",
              "completed": false, "status": "open", "health": "at_risk",
              "percent_complete": 40, "blocked": false,
              "flags": ["review"], "tags": ["backend"]}}
    ```

    — and `{"type": "webhook", "url": "…", "method": "get"}` sends the same
    fields as query parameters instead, flattened to `card.title`,
    `card.url`, `card.due_date` and so on (lists comma-separated, anything
    unset left out). `status` is `open`, `done` or `archived`. The URL may
    itself carry placeholders, so `https://example.com/hooks/{{card.id}}`
    works — in the path and query only, never the host, and each value is
    percent-encoded. Only `http`/`https` URLs to public addresses are called:
    loopback, private, link-local and CGNAT/tailnet addresses are refused
    (when the rule is saved if the URL names one outright, and on every call
    after resolving it) unless the server's admin has opened them with
    `SLIPDOCK_EGRESS_ALLOW`. Redirects are not followed, nothing is retried,
    and a non-2xx answer never stops the rule's other actions. A call that
    never got an answer is logged as `unreachable` or `timed out`.

    Every call is logged once it finishes — and since calls go out in the
    background, the log is where a failed one shows up:

    ```sh
    curl -s -H "$H" "B/api/boards/1/automations/callbacks?limit=20"
    ```

    ```json
    {"callbacks": [{"id": 9, "at": "2026-10-04T11:00:00Z", "rule": "Tell the robot",
                    "rule_id": 3, "card": "Ship it", "card_id": 42, "method": "POST",
                    "url": "https://example.com/hooks/kanban", "ok": false,
                    "status": 503, "error": "HTTP 503", "duration_ms": 140}]}
    ```

    Newest first, `limit` up to 200 (default 50); the board keeps its newest
    200. `status` is null when nothing answered — `error` then says why.
    `slipdock callbacks <board>` is the same on a shell.

    **Alerts** are the `alert` action: a line in the header bar of the web UI
    that stays until the reader dismisses it. They are how a rule tells a
    person something without emailing them, and they are worth reading before
    you start work — they are the board saying what it thinks is wrong.

    ```sh
    curl -s -H "$H" B/api/alerts            # what is waiting for you
    curl -s -X DELETE -H "$H" B/api/alerts/7   # dismiss one (yours only)
    curl -s -X DELETE -H "$H" B/api/alerts     # dismiss the lot
    ```

    Dismissing is per person: yours going does not take anyone else's.
    """
  end

  defp runners do
    """

    ## Runners

    A rule's `runner` action sends a card to a coding agent on somebody's own
    machine — a laptop, a dev server, a Windows box — instead of to a URL.
    The action queues a **job**; a **runner** on that machine takes it, runs
    the agent on the card, and reports back. The shape of the action:

    ```json
    {"type": "runner", "pool": "default", "kind": "claude",
     "prompt": "optional; the card's title, link and description by default"}
    ```

    - **Pull, not push.** Runners dial out to this server and ask for work.
      Nothing ever calls the machine, so it needs no open port or tunnel.
    - **The server never decides what runs.** A job is data: its id, its
      `kind`, the card and the prompt. Which command a kind means is written
      in the runner's own config on its own machine; a kind it has no
      definition for is refused there and nothing runs.
    - **One queue.** Every runner of a pool on a board tree takes jobs from
      the same queue, one at a time, so two of them never work one card. A
      rule has at most one open job per card.

    A job goes `queued → claimed → running → done | failed | cancelled |
    timeout`. A claim holds a lease (90 seconds) that each heartbeat renews;
    a lease that runs out puts the job back in the queue, and after three
    tries the job fails and its card is flagged.

    **Taking jobs from a Claude session** (`/loop`, a scheduled task) uses the
    token you already have — over MCP the `claim_job`, `job_progress` and
    `finish_job` tools, over HTTP:

    ```sh
    curl -s -X POST -H "$H" -H 'content-type: application/json' \
      B/api/boards/1/jobs/claim -d '{"pool": "default"}'
    # {"job": null}, or {"job": {"id": 7, "card_id": 42, "card_url": "…", "kind": "claude",
    #   "prompt": "…", …}, "lease_seconds": 1200}
    curl -s -X POST -H "$H" -H 'content-type: application/json' \
      B/api/jobs/7/progress -d '{"note": "tests written, fixing the parser"}'
    # {"status": "ok"} — or "cancel": somebody stopped it; finish as cancelled
    curl -s -X POST -H "$H" -H 'content-type: application/json' \
      B/api/jobs/7/finish -d '{"outcome": "done", "summary": "fixed in abc1234"}'
    ```

    A session holds its job on a 20-minute lease (a runner on a machine, 90
    seconds): report between steps, and never let 20 minutes pass without a
    `progress`, or the lease runs out and somebody else gets the card. `note` also goes on the card as a
    comment; finishing the job does not close the card, so close it as usual.
    The session shows in the board's runner list as `<token label> (session)`.

    **Seeing and stopping jobs** needs read access to the card, and
    cancelling one write: `GET /api/cards/:id/jobs`, `GET
    /api/boards/:board/jobs?status=open`, `GET /api/jobs/:id`, `POST
    /api/jobs/:id/cancel`. A queued job is cancelled at once; a running one
    is asked to stop, and its runner hears so on its next heartbeat.

    **Connecting one** is easiest with the wizard, which the board's
    Automations panel shows as *Connect a runner*: `POST
    /api/boards/:board/runners/setup` with `scenario` (`server`, `windows`,
    `loop`, `cloud`), `pool`, `agent`, `cwd`, `permission_mode`, `timeout`,
    `service`, `where` and `repo`, and `column` to add a rule sending that
    list's cards. It answers with `setup.steps` — exactly what to paste — and
    for a runner of its own the `runner` and its `token`, once. `GET
    …/runners/:id/setup` gives the steps again, `POST …/runners/:id/token` a
    new token, and `PUT …/runners/:id/setup` saves new answers and answers
    with a `diff` of what changes. Standing `instructions` (and a
    `verbosity`) and `before_job`/`after_job` hooks are answers too: they
    are written into the generated config or prompt and kept on the
    machine, never sent with a job. For a Claude runner, `slipdock_tools`
    (default true) and `mcp_servers` (default `claude_ai_Slipdock, slipdock`)
    let it use those MCP servers' tools without asking — in `-p` nobody can
    approve one; `slipdock_tools: false` leaves it no access to the board.
    Every job's prompt ends by telling the agent nobody will answer questions.
    `slipdock runner new` prints the same. What a job does to its card and
    repository is seven booleans, all false unless given, in every scenario:
    `in_progress`, `assign`, `commit` (only in a git repository), `push`
    (refused without `commit`), `move_done`, `complete` and `percent_100`.
    Each is said in the prompt, or a runner's standing instructions, on or
    off. `verbosity` is `nothing` (the default: no comments, `job_progress`
    with no note), `quiet`, `normal`, `verbose`, or `""` for whatever the
    skill says. Answers saved as #511's `commit` and `close` carry over. A
    session with no job tools (a connector added before they existed keeps its
    old tool list) is told to stop and say so rather than work the lists.

    **Runners themselves** are the board owner's to make and revoke: `GET`,
    `POST` (`{"name", "pool"}`, answering with the runner's token, once) and
    `DELETE /api/boards/:board/runners[/:id]`. A runner's token (`sdr_…`)
    works only on the runner protocol, which is plain text so a machine with
    nothing but `sh` and `curl` can speak it:

    ```
    POST /api/runner/claim?wait=25             204, or 200 with X-Job-Id, X-Job-Kind, X-Card-Id,
                                               X-Card-Ref, X-Card-Url, X-Lease-Seconds; prompt as body
    POST /api/runner/jobs/:id/heartbeat        body = log tail  → ok | cancel
    POST /api/runner/jobs/:id/finish?exit=N&status=S   body = last output → ok
    ```

    The shell runner that speaks it, `slipdock-runner` (`sh` and `curl`
    only), installs with `curl -fsSL B/runner/install.sh | sh -s -- --url B
    --token sdr_… --pool default`; on Windows, `slipdock-runner.ps1` from
    `B/runner/install.ps1`. `B/runner/SHA256SUMS` has the checksums.

    `slipdock runner ls|new|rm`, `slipdock jobs`, `slipdock job`,
    `slipdock cancel-job`, `slipdock claim-job`, `slipdock job-progress` and
    `slipdock finish-job` are the same on a shell.
    """
  end

  defp wiki do
    """

    ## The wiki: writing things down

    The board answers *what are we doing*. It cannot answer *how does this
    work*, *what did we decide and why*, or *what shape is the thing* — and
    those are the answers that stop being rediscovered every month. Each board
    has a wiki for them: Markdown pages in a tree of their own, with the
    board's permissions and the board's API.

    A page answers to three names, and they are not interchangeable:

    - its **code** — `W-31` — stable across renames, and what belongs in a
      commit message or a link;
    - its **slug** — taken from the title, and what the URL reads as;
    - `board-code/slug`, for naming a page on another board.

    All three work wherever `:id` appears below (URL-encode the slash in
    `board-code/slug`, so `apiwiki%2Frunbook`).

    ```sh
    curl -s -H "$H" B/api/boards/1/pages            # the board's pages
    curl -s -H "$H" "B/api/boards/1/pages?tree=true"   # nested, as the sidebar shows them
    curl -s -H "$H" "B/api/boards/1/pages?q=refund"    # by substring
    curl -s -H "$H" B/api/pages/W-31                # one page: Markdown source, not HTML

    # write one
    curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/pages \\
         -d '{"title": "Retry policy", "body": "# Retry policy\\n\\nThree times, then stop.",
              "summary": "How retries work", "message": "first draft"}'

    # change one, safely (see below)
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/pages/W-31 \\
         -d '{"body": "…", "base_hash": "<the content_hash you read>", "message": "why"}'

    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/move -d '{"parent": "W-30", "position": "top"}'
    curl -s -X DELETE -H "$H" B/api/pages/W-31       # archive (?purge=true, owner only)
    curl -s -X POST -H "$H" B/api/pages/W-31/restore
    curl -s -H "$H" B/api/pages/W-31/revisions
    curl -s -H "$H" "B/api/pages/W-31/revisions/12?diff=previous"
    curl -s -H "$H" "B/api/pages/W-31/revisions/12?diff=7"   # from version 7 to 12
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/revert -d '{"revision_id": 12}'
    ```

    **`base_hash` is the thing to get right.** Every page carries a
    `content_hash`. Send back the one you read and a save that would land on
    top of someone else's is refused — HTTP 409, with the page as it now
    stands in `current`, to merge against. Omit it and the last write wins,
    which is recoverable from history but is still someone's paragraph gone.
    Two agents and a person may all be writing the same runbook; send the
    hash.

    **Every write is recorded.** A revision carries who wrote it, why
    (`message` — write one every time), and how: `via` is the client and
    `agent` is the name on the API token, so a page's history says which robot
    changed which paragraph without anyone keeping a separate log. Nothing is
    ever deleted by a save, and reverting is itself a save.

    ### Folders: where a page is kept

    Two axes, and they answer different questions. `parent_id` says what a
    page is **part of** — the rollback half of the runbook. A **folder** says
    where it is **kept** — "Design", "Contracts", "Meetings" — and holds pages
    that have nothing to do with one another except that somebody files them
    together. Both are optional and neither implies the other.

    A folder answers to its id, its slug, its name, or a path of names.
    Deleting one never deletes writing *unless you say so*: by default its
    subfolders move up to its parent and its pages go back to the board's
    root. `?purge=true` is the other answer — the folders beneath it and every
    page filed in any of them, deleted for good — and it is the board owner's
    to give, as purging a page is.

    ```sh
    curl -s -H "$H" B/api/boards/1/folders          # the filing, nested, pages and all
    curl -s -H "$H" B/api/wiki                      # every board you can open, folders and all

    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/boards/1/folders -d '{"name": "Design/Decisions"}'   # makes both

    # file a page — the folder is made if it is new, so this is one call
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/folder -d '{"folder": "Design/Decisions"}'
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/folder -d '{}'            # take it out of its folder

    # or write it straight into one
    curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/pages \\
         -d '{"title": "Why Postgres", "folder": "Design/Decisions"}'

    curl -s -H "$H" "B/api/boards/1/pages?folder=decisions"   # and list what is in it
    curl -s -H "$H" "B/api/boards/1/pages?folder=none"        # the pages filed nowhere

    curl -s -X PATCH -H "$H" -H 'content-type: application/json' \\
         "B/api/boards/1/folders/Design/Decisions" -d '{"name": "Choices", "parent": "root"}'
    curl -s -X DELETE -H "$H" "B/api/boards/1/folders/Choices"   # the folder only
    curl -s -X DELETE -H "$H" "B/api/boards/1/folders/Choices?purge=true"
    # → {"deleted": {...}, "purged": {"pages": 4, "folders": 1}}
    ```

    **File it, don't nest it.** Making a parent page called "Design" that
    exists only to hold other pages is the mistake folders are for: the page
    is about nothing, and it has to be read to be got past. A folder is a
    place, and a place costs nothing.

    On a shell: `slipdock wiki`, `slipdock folder ls|new|mv|rm [--purge]`, and
    `slipdock page file <page> --folder F | --no-folder`.

    In the app a folder is a place you can be: `/boards/1/wiki?folder=4` shows
    one folder — what is filed in it, the folders beneath it, and the actions
    that belong to it. Anywhere a folder is asked for, the tree is shown and
    filters as you type, so "where does this go" never means reading a flat
    list of forty paths. The sidebar's pencil turns the tree into a
    drag-and-drop one: a page dropped in a folder is filed there, a page
    dropped on a page becomes part of it, and a folder dropped in a folder
    moves under it — the same three calls as `/folder`, `/move` and
    `PATCH /folders/:id`, which is what you have.

    The wiki's own search box matches names — a page's title and summary, a
    folder's — and says so; the words *inside* the pages are the search above,
    one click away at `/search?q=…&board=N` (which is a link worth handing
    somebody when the name they tried is not what the page is called).

    ### Writing one section at a time

    A page is addressed by heading: `Deploy/Rollback` is the `## Rollback`
    under the `# Deploy`. This is the write to prefer, and by some distance.

    ```sh
    curl -s -H "$H" B/api/pages/W-31/sections              # the paths you may name
    curl -s -H "$H" B/api/pages/W-31/section/Deploy/Log    # read one
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/section/Log -d '{"body": "- 2026-09-29 rolled back at 14:05"}'
    curl -s -X PUT -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/section/Deploy/Rollback -d '{"body": "## Rollback\\n\\nNew words."}'
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/append -d '{"body": "## Findings\\n\\n…"}'
    ```

    Two writers touching different sections never collide, and an **append
    cannot clobber anything at all** — so it takes no `base_hash` and never
    refuses. An agent keeping a running record should append to `## Log` and
    send nothing else; it costs one small request instead of the whole
    document, and it is the difference between collaborating on a page and
    overwriting it.

    ### Writing links

    Inside a body:

    ```
    [[Retry policy]]                  a page on this board (title, then slug)
    [[retry-policy|how it works]]     the same, with the text to show
    [[QVM/Retry policy]]              a page on another board
    [[W-31]]  or bare  W-31           a page by its code
    [[#412]]  or bare  #412           card 412 — drawn live, never stale
    [[board:QVM]]  [[view:QVM/Blocked work]]
    [[!toc]]  [[!children]]  [[!backlinks]]
    @name                             someone on the board
    ```

    A reference inside a code span or a fenced block is not a reference. A
    card chip is resolved when the page is *read*, so writing `#412` rather
    than "the card about retries" is what keeps a document true after the
    card is renamed.

    **Link to pages that do not exist yet.** `[[Rollback procedure]]` written
    before anyone writes it is not a broken link: it renders as an invitation
    and turns up in `GET /api/boards/:board/pages/wanted`, which is the
    wiki's own backlog and a good queue to work from.

    ```sh
    curl -s -H "$H" B/api/pages/W-31/links                 # out, in, and wanted
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/links -d '{"card": 412}'         # this page is *the* spec for that card
    curl -s -H "$H" B/api/boards/1/pages/wanted
    curl -s -H "$H" "B/api/pages/resolve?board=1&title=Retry+policy"
    ```

    `GET /api/pages/:id/render` is the other half of this: it returns the page
    with every reference followed, so an agent answering a question reads the
    answers rather than the syntax. Read a page to change it; render a page
    to learn from it.

    ### Finding what has been written

    Pages are in the same semantic index as cards, and ranked against them:
    "what did we decide about refunds" should find the decision record *and*
    the card that argued about it, in one list.

    ```sh
    curl -s -H "$H" "B/api/search?q=how+do+retries+work"              # both
    curl -s -H "$H" "B/api/search?q=how+do+retries+work&kind=pages"   # documents only
    curl -s -H "$H" "B/api/search?q=...&kind=cards"                   # the work only
    ```

    Each result carries `kind` (`"card"` or `"page"`), a `subject` with its
    title and URL, and the chunks that matched. A page's matches name the
    `section` they came from, so a result can be followed to the heading
    rather than the top of a long document.

    **Search before you write.** `kind=pages` is the difference between
    extending the page that exists and leaving a fourth page about deployment
    behind you. A page is chunked by heading, so a match is a section and
    reading it is cheap.

    Drafts are not indexed at all, and a page the reader cannot open never
    comes back — checked against the reader on the way out, not merely at
    index time.

    ### Live queries

    A fenced ```` ```slipdock ```` block in a page is a question, answered when
    the page is **read** — with the reader's own permissions, never the
    author's. A hand-typed list of blocked cards is wrong by Tuesday; this
    never is.

    ````
    ```slipdock
    view: table
    board: this
    filter: flag=blocked, due < +7d, priority in high|critical
    group: assignee
    sort: due_date asc
    fields: title, assignee, due_date, status
    limit: 20
    empty: "Nothing blocked and due this week."
    ```
    ````

    ```sh
    curl -s -H "$H" B/api/pages/query-vocabulary    # views, settings, operators, fields
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/query -d '{"board": 1, "body": "view: count\\nfilter: flag=blocked"}'
    ```

    **Read the vocabulary and try the block before writing it into a page.**
    It comes from the parser, so it cannot be out of date, and a block that
    cannot be answered is a red note on somebody's document.

    `board:` is `this` (the page's own), `tree` (it and everything beneath
    it), or another board's code — cross-board is allowed and filtered by
    access. `saved_view: "Blocked work"` embeds a view you already made
    rather than spelling its filters out again; the web app will write the
    whole block for you from any board view.

    In a sentence, `{{count: flag=blocked}}`, `{{progress:412}}`,
    `{{card:412.due_date}}`, `{{board.name}}` and `{{today}}` answer inline.
    An expression this does not understand is left exactly as written, which
    is what keeps a template page readable before it is used.

    ### A page on the board

    A page can sit in one of its board's lists and be dragged about like a
    card — the spec in "In Progress" beside the work it describes.

    ```sh
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/place -d '{"column": "In Progress"}'
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/place -d '{"column": "Backlog", "before": 412}'
    curl -s -X DELETE -H "$H" B/api/pages/W-31/place
    ```

    A page carries the **card's facets** — `priority`, `flags`, `tags`,
    `assignee`, `start_date`, `due_date`, `date_precision`, `completed`,
    `percent_complete`, `color` — under the same names and with the same
    vocabularies as a card's, settable on create or update like any other
    field. `add_flags` / `remove_flags` work as they do on a card, and
    `assignee` takes an email.

    ```sh
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/pages/W-31 \
         -d '{"priority": "high", "add_flags": ["review"], "due_date": "2026-10-09",
              "assignee": "sam@example.com", "percent_complete": 40, "color": "amber"}'
    ```

    That is what lets a placed page stand beside the cards in *every* view —
    board, swimlanes, table, timeline, calendar — and be grouped, filtered
    and sorted with them. A view's `kinds` filter is what separates them again
    when you want one sort of thing: `kinds=card`, `kinds=document`,
    `kinds=page`, or a comma-separated mix.

    ```sh
    curl -s -H "$H" "B/api/boards/1/swimlanes?kinds=page&rows=none&cols=column"
    ```

    ### A page's comments, checklist, status and the rest

    A page holds most of the card's **contents** too, in the same tables and
    through endpoints that mirror the card's one for one. `GET /api/pages/:id`
    returns them alongside the body: `comments`, `checklist`, `urls`,
    `status_updates`, `stated_health`, `votes` and `fields`.

    ```sh
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/comments -d '{"body": "Needs a worked example."}'
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/checklist -d '{"text": "worked example for backoff"}'
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/status -d '{"health": "at_risk", "body": "stalled on review"}'
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/urls -d '{"url": "example.com/rfc", "title": "the RFC"}'
    curl -s -X DELETE -H "$H" B/api/pages/W-31/urls/7
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/vote -d '{"count": 2}'
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/pages/W-31 \\
         -d '{"fields": {"effort": 3}}'
    ```

    Checklist items and comments are removed through the routes they share
    with cards — `POST /api/checklist/:id/toggle`, `DELETE /api/checklist/:id`,
    `DELETE /api/comments/:id` — which authorise against whichever the row
    hangs off. Votes come out of the board tree's one budget, so a page
    competes with the cards for it.

    **A comment on a page is writing too.** `[[Retry policy]]` in one turns
    up in that page's backlinks, naming the page it was written on, exactly
    as a comment on a card names the card. In `GET /api/pages/:id/links`,
    an `incoming` link written on a card carries `card` where a page's
    carries `page`.

    What a page does **not** take is the work-shaped pair: blocking
    dependencies and typed card links, both card-to-card joins carrying
    scheduling meaning, and sub-cards. A page has `[[wikilinks]]`, backlinks
    and pins for saying what it is *about*, and child pages for a subtree.
    Asking a page for the rest gives an empty list rather than an error.

    `before` counts cards as well as pages — a card's number, or `page-7` —
    because the two share one position sequence and a document that had to
    sit after every card would not really be on the board. A board's JSON
    carries each list's `pages` alongside its `cards`, both with the position
    that orders them together.

    The web app offers this at the foot of every list — a document icon
    beside **Add** and a paperclip (a file, landing as a card of its own with
    the file attached). All three are shortcuts to putting one more item in a
    list, and each can be turned off per board:

    ```sh
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/boards/1 \\
         -d '{"add_document": false}'
    ```

    A board's JSON carries `add: {card, page, document}`, so a client that
    draws a list draws the same three.

    Placement is a **second, optional axis**: the page keeps its place in the
    wiki tree either way, and taking it off the board changes nothing about
    the page. Most pages are never placed. The ones worth placing are the
    documents somebody is working *through* — a spec being written, a retro
    waiting to be held — not the reference material.

    ### The board and the wiki, both ways

    The point of a wiki inside a work tracker is that neither side has to
    remember the other exists.

    ```sh
    curl -s -H "$H" B/api/cards/412/pages          # what has been written about this card
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/cards/412/pages -d '{}'             # "write it up": a page for it, pinned
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/cards/412/pages -d '{"template": "Spec template"}'
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/cards -d '{"text": "Retries are wrong\\nThey never stop."}'
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/boards/1/pages/from-template \\
         -d '{"template": "Decision record", "title": "Dropping the queue", "values": {"owner": "ops"}}'
    ```

    **Pin the page to the card it explains.** A page nobody can find from the
    work is a page nobody reads, and pinning is what puts it at the top of the
    card's Docs. It is a person's judgement rather than something the prose
    says, so it survives whoever next edits the page.

    **A comment can link a page too** — "blocked on [[Retry policy]]" on a
    card shows up in that page's backlinks. Writing on cards is writing.

    **Templates** are ordinary pages with `"template": true`, not read as
    content but copied. Bodies may use the same `{{…}}` placeholders an
    automation action does — `{{card.title}}`, `{{board.name}}`, `{{today}}` —
    plus anything passed in `values`.

    **Conventions worth keeping to**, because they are what make a wiki
    readable a year later rather than a pile of near-duplicates:

    - **Search before you write.** A fourth page about deployment is the most
      common mistake here. Extend the page that exists unless the subject is
      genuinely new.
    - **A page or a comment?** Durable and re-read → a page. About one card
      and about *now* → a comment or a status update on the card. Not both.
    - **One `## Log` section** for dated notes, appended to, newest last.
    - **Write the `message`** on every edit: history is the audit trail.
    - **Don't rewrite a section you did not author** without saying so in the
      message.
    - **A page per durable thing**, not per conversation.
    - **Query, don't list.** A hand-typed list of blocked cards is stale by
      Tuesday; a `slipdock` block never is.

    Drafts (`"status": "draft"`) are visible only to people who could edit the
    board, so a half-written page is not a half-answer to someone else's
    question. A page can also be shared on its own, without its board.

    On a shell, the same thing is `slipdock page ls|tree|read|render|new|edit|
    section|append|file|mv|rm|restore|links|pin|wanted|history|diff|revert` —
    `slipdock page read` prints the Markdown, and `--body -` takes the body on
    stdin.

    ### Out, and on the open web

    ```sh
    curl -s -H "$H" B/api/boards/1/pages/export          # every page as {path, body}
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/boards/1/pages/import -d '{"files": [{"path": "Charter.md", "body": "…"}]}'
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/publish -d '{}'                # read-only at /w/:token
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/publish -d '{"published": false}'
    ```

    Export is one Markdown file per page, front matter and all, in the
    directory its wiki folder names and nested as the page tree is — a
    directory plus an `index.md` for a page with children. Import reads a
    directory by the same one rule: **with an `index.md` it is a page with
    children; without one it is a folder.** So a wiki moves between boards by
    handing one answer to the other, and a folder of hand-written notes comes
    in as filing rather than as pages about nothing. A title already on the
    board is skipped and reported rather than duplicated.
    `/boards/:id/wiki.zip` is the same thing zipped.

    **Publishing freezes the answers.** A published page's live queries show
    what they said when it was published, and its references are plain text:
    there is nobody behind an anonymous request to have permissions, so a
    live query there would be a way to read private cards from the open web.
    Publishing again refreshes them. A draft cannot be published.

    An automation can write a page too — the `create_page` action starts one
    for the triggering card, pinned to it — and `has_doc` is a condition, so
    "when a card lands in Ready and nothing has been written about it, alert
    me" is a rule rather than a habit.

    ## Skills

    This server ships the instructions for using it, versioned with the code
    they describe, so a copy in somebody's agent directory can be checked
    against the API that actually answers:

    ```sh
    curl -s B/api/skills                      # name, description, version, files
    curl -s B/api/skills/slipdock-wiki          # one of them
    curl -s B/api/skills/slipdock-wiki/references/markup.md

    slipdock skills install                     # writes them to ~/.claude/skills
    slipdock skills check                       # says whether a local copy is behind
    slipdock skills chatgpt                     # zips for ChatGPT, one per skill
    ```

    ChatGPT can't run the CLI, so every skill but `slipdock-loop` also comes
    as a zip for its skill upload, `B/api/skills/<name>/chatgpt.zip`, with
    each `slipdock` command mapped onto the tool of this server's MCP
    connector that does the same. The listing's `chatgpt_zip` says which.

    They need no token, because they say how to call this API and nothing
    about what is on it. Board codes, list names and tag vocabularies stay out
    of them deliberately and come from this guide instead — a skill that
    hardcodes them rots, and one that sends you here does not.
    """
  end

  # Moving a whole board somewhere else. Distinct from the wiki's Markdown
  # export above, and the guide says which is which, because an agent asked to
  # "export the board" could reasonably reach for either.
  defp portable do
    """

    ## Moving boards between servers

    ```sh
    curl -s -H "$H" B/api/export                         # every tree you own
    curl -s -H "$H" "B/api/export?boards=del,ops"        # just these
    curl -s -H "$H" "B/api/export?archived=all"          # and what is put away
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/import -d @boards.json
    ```

    One JSON document holding whole board trees: lists, cards, subcards, tags,
    checklists, comments, status updates, web links, custom fields and their
    values, what waits on what, and the wiki. `slipdock export [<board>...]
    [--out FILE]` and `slipdock import <file.json>` on a shell.

    **This is not the wiki export above.** That one writes Markdown, for
    reading your writing somewhere else; this one moves a board, and only this
    one can be read back into a board.

    Three things to know before using it.

    **It only ever carries boards you own.** A board shared with you is
    somebody else's to hand on. Asking for one by name is a 403.

    **An import never merges.** A document always becomes *new* boards, even
    when a board of that name is already here — deciding per card whether "the
    same card" means the same title is how an import quietly destroys work. A
    board code that is taken is reissued (`del` → `del-2`) and the answer says
    so. So importing the same file twice gives two copies, which is a fact
    about the tool rather than a bug to work around.

    **Automation rules do not fire on an import.** Four hundred cards arriving
    would otherwise run every rule four hundred times. An import is history
    arriving, not things happening.

    **A document is checked before anything is built.** A body may be at most
    8 MB (the Account page's upload too); a sub-board may be claimed by one card
    only and never be the root; and no one kind of row — lists, folders,
    checklist items, comments and so on — may run past
    #{Slipdock.Portable.max_rows()} in a tree. Any of those is a 422 and nothing
    is imported.

    What a document does **not** hold, each for a reason: attachments (bytes
    rather than structure — they stay on the server they were uploaded to),
    votes (a person's budget spent, which means nothing on another server),
    wiki page history and activity (a record of one server's past, which
    another cannot honestly adopt), and public share tokens (a secret that
    would otherwise be valid in two places). `leaving_behind` in the export
    response says how much of each was left, and says nothing when there was
    nothing.

    Two things cannot travel verbatim and are handled rather than ignored.
    Page codes (`W-31`) are unique across a server, so imported pages get
    fresh ones — and `[[W-31]]` inside the imported bodies is rewritten to the
    code that page now has, so a wiki still links to itself. A board's
    shortcut key is also server-wide, so it does not come with the document.

    One thing genuinely does not survive: `#412` written inside a **page body**
    points at a card id on the server the document came from, and there is
    nothing in the document to match it against. Card-to-card links and
    dependencies *are* preserved — those travel as refs — but a card id typed
    into prose is not. A dependency on a card in another board tree (one not
    under the same root) cannot travel as a ref: the export's warnings count
    them, and an import drops any whose other card is not in the file and
    says how many.

    People travel as email addresses, because an id from another server names
    nobody. An imported board is yours alone until you share it, and a card
    is only ever assigned to somebody who can open it, so everybody but you
    lands unassigned and is named in the answer ("… can't see this board
    yet") — the same words whether or not they have an account here — rather
    than failing the import on the last card. Status updates are signed as
    you, with their original author written into the text.

    The card limit is answered once, for the whole document, before anything is
    built: a file that will not fit is refused outright rather than stopping
    half way.

    ### From Trello

    `POST /api/import` (and `slipdock import`) also takes a **Trello board's
    JSON export** as it is — recognised by its shape, or named with
    `?from=trello` (`--from trello`); an unknown `from` is a 422 rather than a
    guess. The answer carries `"source": "trello"`. Open lists, cards (archived
    ones archived), labels as tags, checklists, comments, dates and attachments
    as web links come across; a list named like *Done* or *Doing* gets that
    category. Members do **not**: Trello's export has no email addresses, so
    cards arrive unassigned and `skipped` says so — tell the person rather than
    assigning anyone yourself. Archived lists and custom fields stay behind,
    and are named in `skipped` too. The rules above — new boards only, no rules
    firing, the limit answered first — apply unchanged.
    """
  end

  defp vocabulary_section do
    v = vocabulary()

    """

    ## Vocabulary

    Generated from this server's code, so it is current:

    - **priority** — #{Enum.join(v.priorities, " · ")} (highest first:
      #{Enum.join(v.priority_order, " > ")})
    - **flags** — #{Enum.join(v.flags, " · ")}
    - **list categories** — #{Enum.map_join(v.list_categories, " · ", fn c -> if c.key == "", do: "(none)", else: "`#{c.key}` #{c.label}" end)}
    - **link kinds** — #{Enum.map_join(v.link_kinds, " · ", & &1.key)}
    - **stated health** — #{Enum.join(v.health, " · ")}
    - **date precision** — #{Enum.join(v.date_precisions, " · ")} (a card can be
      scheduled to a quarter, not just a day)
    - **colours** — #{Enum.join(v.colors, " ")}
    """
  end

  defp endpoints_section do
    """

    ## Every endpoint

    ```
    #{endpoints() |> Enum.map_join("\n    ", fn {verb, path} -> String.pad_trailing(verb, 7) <> path end)}
    ```

    `:board` accepts an id, a board's `code`, or a name. Bodies are documented by the recipes
    above; the fields a card accepts on create and update are `title`,
    `description`, `priority`, `flags`, `tags`, `add_flags`, `remove_flags`,
    `add_tags`, `remove_tags`, `start_date`, `due_date`, `date_precision`,
    `completed`, `percent_complete`, `color`, `column`, `assignee` and `fields`.
    """
  end

  defp boards_section(nil, _token) do
    """

    ## Your boards

    Not shown: this request carried no token. Re-read the guide with one and
    this section lists the boards you can see, every list on them, and which
    list is the ready list, the backlog, the one in progress and the one for
    done work.
    """
  end

  defp boards_section(user, token) do
    boards =
      user
      |> Access.list_boards(activity: true, token: token)
      |> Boards.sort_boards(user.board_sort)

    archived = Access.list_boards(user, archived: true, token: token)

    body =
      if boards == [] do
        "You cannot see any boards yet. `POST /api/boards {\"name\": \"…\", \"code\": \"…\", \"template\": \"Slipdock\"}` makes one (leave `code` out and one is made from the name)."
      else
        Enum.map_join(boards, "\n", &board_line(&1, user))
      end

    """

    ## Your boards right now

    #{body}

    The name in backticks after each board is its `code` — the short name for
    it, and the one to use when you address a board by anything but its id.

    Sub-boards are not listed here — they hang off their epic's `sub_board`.
    #{archived_note(archived)}
    """
  end

  defp archived_note([]), do: ""

  defp archived_note(archived) do
    """

    #{length(archived)} board#{if length(archived) == 1, do: " is", else: "s are"} archived and left
    out of the list above: #{Enum.map_join(archived, ", ", &"##{&1.id} #{&1.name} (`#{&1.code}`)")}.
    An archived board is put away, not deleted — every card on it still reads
    and writes as usual, and `GET /api/boards?archived=all` lists them
    alongside the rest. Take it as a strong signal, though: work on an archived
    board is work the person has set aside, so ask before you pick any of it
    up, and put anything new on a board that is still in play.
    """
    |> String.trim_trailing()
  end

  defp board_line(board, viewer) do
    full = Boards.get_board!(board.id)

    lists =
      Enum.map_join(full.columns, " · ", fn col ->
        open = Enum.count(col.cards, &(not &1.completed))
        "#{col.name} (#{role_note(full.columns, col)}, #{open} open of #{length(col.cards)})"
      end)

    epics =
      full.columns
      |> Enum.flat_map(& &1.cards)
      |> Enum.count(& &1.sub_board)

    roles =
      [
        {"take work from", ready_list(full.columns)},
        {"then", backlog_list(full.columns)},
        {"in progress", list_of_role(full.columns, :doing)},
        {"done", list_of_role(full.columns, :done)}
      ]
      |> Enum.reject(fn {_, col} -> is_nil(col) end)
      |> Enum.uniq_by(fn {_, col} -> col.id end)
      |> Enum.map_join(" · ", fn {role, col} -> "#{role}: “#{col.name}” (##{col.id})" end)

    """
    - **##{board.id} #{board.name}** (`#{board.code}`) — #{length(board.cards)} top-level cards, #{Enum.count(board.cards, & &1.completed)} done#{if epics > 0, do: ", #{epics} of them epics with subcards"}#{shared_note(board, viewer)}
      - lists: #{lists}
      - #{if roles == "", do: "nothing on this board says which list means what — ask before choosing work from it", else: roles}
    """
    |> String.trim_trailing()
  end

  # A board somebody else owns, said on the line that names it: an agent
  # reporting on it should name whose it is rather than call it "your board".
  defp shared_note(%{owner_id: owner_id} = board, %{id: id})
       when owner_id != nil and owner_id != id,
       do: ", owned by #{owner_label(board)} and shared with you"

  defp shared_note(_board, _viewer), do: ""

  defp owner_label(%{owner: %Slipdock.Accounts.User{} = owner}),
    do: Slipdock.Accounts.User.display_name(owner)

  defp owner_label(_board), do: "somebody else"

  defp role_note(columns, col) do
    case role(columns, col) do
      nil -> "uncategorised"
      role when is_binary(col.category) and col.category != "" -> role
      role -> "#{role} by name only"
    end
  end

  @doc """
  What a list means: its `category` when it has one, else what its name says.
  Older boards (and boards made by hand) often carry no categories at all, and
  an agent still has to choose work from them.
  """
  def role(columns, %Column{} = col) do
    cond do
      Enum.member?(~w(todo doing done dropped), col.category) -> col.category
      named?(col, ["in progress", "doing", "wip", "started", "active"]) -> "doing"
      named?(col, ["done", "complete", "shipped", "finished"]) -> "done"
      named?(col, ["dropped", "won't", "wont do", "cancelled", "rejected"]) -> "dropped"
      named?(col, todo_names() ++ backlog_names()) -> "todo"
      # An uncategorised list on a board that has no categories at all: assume
      # work can come from it, since the board offers nothing better.
      Enum.all?(columns, &Enum.member?([nil, ""], &1.category)) -> "todo"
      true -> nil
    end
  end

  @doc """
  Which of a board's lists plays which part, by the same reading the guide
  gives under "Your boards right now": the ready list work is taken from, the
  backlog behind it, the list in progress and the one for done work. Any of
  them may be nil.
  """
  def list_roles(columns) do
    %{
      ready: ready_list(columns),
      backlog: backlog_list(columns),
      doing: list_of_role(columns, :doing),
      done: list_of_role(columns, :done)
    }
  end

  defp list_of_role(columns, want) do
    want = Atom.to_string(want)
    Enum.find(columns, &(role(columns, &1) == want))
  end

  # The `todo` list work is drawn from first: the one whose name says "ready",
  # else the earliest that isn't a holding pen.
  defp ready_list(columns) do
    todo = todo_lists(columns)

    Enum.find(todo, &named?(&1, todo_names())) ||
      Enum.find(todo, &(not named?(&1, backlog_names()))) ||
      List.first(todo)
  end

  defp backlog_list(columns) do
    todo = todo_lists(columns)
    ready = ready_list(columns)
    rest = Enum.reject(todo, &(ready && &1.id == ready.id))

    Enum.find(rest, &named?(&1, backlog_names())) || List.first(rest)
  end

  defp todo_lists(columns), do: Enum.filter(columns, &(role(columns, &1) == "todo"))

  defp todo_names, do: ["to do", "todo", "to-do", "now", "ready", "selected", "next", "this week"]

  defp backlog_names, do: ["backlog", "later", "icebox", "someday", "parking", "ideas", "inbox"]

  defp named?(%Column{name: name}, words) do
    name = String.downcase(name)
    Enum.any?(words, &String.contains?(name, &1))
  end

  ## The endpoint list, from the router itself ---------------------------------

  defp endpoints do
    SlipdockWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.filter(&String.starts_with?(&1.path, "/api"))
    |> Enum.map(fn route -> {route.verb |> Atom.to_string() |> String.upcase(), route.path} end)
  end
end
