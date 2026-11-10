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
      sprints(),
      choosing(base),
      finding(base),
      working(),
      recipes(base),
      automations(),
      runners(),
      health_monitor(),
      deployments(base),
      wiki(),
      handbook() <> sweeps(),
      findings_section(),
      verified_work(user, Keyword.get(opts, :token)),
      lanes_section(user, Keyword.get(opts, :token)),
      profiles_section(user, Keyword.get(opts, :token)),
      portable(),
      vocabulary_section(),
      endpoints_section(),
      this_server(user),
      boards_section(user, Keyword.get(opts, :token), Keyword.get(opts, :board_limit))
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
    "Sprints" => "sprints",
    "Choosing what to do next" => "choosing",
    "Finding something nobody can name" => "finding",
    "Working a card" => "working",
    "Recipes" => "recipes",
    "Automations and alerts" => "automations",
    "Runners" => "runners",
    "Health monitor" => "health",
    "Deployments" => "deployments",
    "The wiki: writing things down" => "wiki",
    "The handbook" => "handbook",
    "Findings" => "findings",
    "Verified work" => "verified",
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

  # How many boards the short guide describes in full, then names, then only
  # counts: someone with fifty boards still gets a guide that fits in one tool
  # result. The whole guide lists every one.
  @short_boards 10
  @short_board_names 20
  @short_archived 5

  @doc """
  The guide cut at its `##` headings: `{key, title, markdown}` in document
  order, the text before the first heading under the key `"intro"`. The
  `### Over MCP` part of *Getting in* is offered on its own as well, as `"mcp"`.
  Takes the same options as `markdown/1`, and `:markdown` to cut that text
  instead of the generated guide.

  A heading line inside a fenced code block (the wiki section's example
  meeting page has `## Recording` in one) is part of the example, not a
  section: only lines outside a fence are cut on (see `split_at_headings/2`).
  """
  def sections(opts \\ []) do
    [{_, _, intro} | rest] =
      opts
      |> Keyword.get_lazy(:markdown, fn -> markdown(opts) end)
      |> split_at_headings(["## "])
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
    text
    |> split_at_headings(["## ", "### "])
    |> Enum.find_value(fn
      "### Over MCP\n" <> _ = part ->
        {"mcp", "Over MCP", String.replace_prefix(part, "###", "##")}

      _ ->
        nil
    end)
  end

  @doc """
  Cuts `text` before every line that starts with one of `marks` (`"## "`, say)
  and is outside a fenced code block, keeping every character: the pieces
  join back to `text`. The first piece is what comes before the first such
  line, `""` when `text` starts with one. A fence opens on a line of three or more backticks or
  tildes (indented at most three spaces) and closes on a line of the same
  character, at least as many, and nothing else; one never closed runs to the
  end, so nothing after it is cut.
  """
  def split_at_headings(text, marks) do
    {pieces, current, _fence} =
      text
      |> String.split(~r/(?<=\n)/)
      |> Enum.reduce({[], [], nil}, fn line, {pieces, current, fence} ->
        cond do
          fence -> {pieces, [line | current], close_fence(fence, line)}
          String.starts_with?(line, marks) -> {[current | pieces], [line], nil}
          true -> {pieces, [line | current], open_fence(line)}
        end
      end)

    [current | pieces]
    |> Enum.reverse()
    |> Enum.map(&(&1 |> Enum.reverse() |> IO.iodata_to_binary()))
  end

  defp open_fence(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})/, line) do
      [_, run] -> run
      nil -> nil
    end
  end

  # Still inside the fence (`fence`, the run that opened it) after `line`?
  defp close_fence(fence, line) do
    <<char::binary-size(1), _::binary>> = fence

    case Regex.run(~r/^ {0,3}(#{Regex.escape(char)}+)[ \t]*\r?\n?$/, line) do
      [_, run] when byte_size(run) >= byte_size(fence) -> nil
      _ -> fence
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
    all = opts |> Keyword.put_new(:board_limit, @short_boards) |> sections()
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

      Each section below is one call away: `get_guide` with `section` set to
      its name, or `GET /api/guide?section=<name>` (`all`, or the plain URL,
      is the whole guide):

      #{others}
      """
  end

  @doc """
  One section of the guide by key (see `sections/1`), `"all"` for the whole
  thing, `"short"` for `short/1`. `{:error, message}` names the keys there
  are, `short` and `all` with them, when `key` is not one.
  """
  def section("all", opts), do: {:ok, markdown(opts)}
  def section("short", opts), do: {:ok, short(opts)}

  def section(key, opts) do
    all = sections(opts)

    case Enum.find_value(all, fn {k, _, text} -> k == key && text end) do
      nil ->
        keys = all |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Kernel.++(["short", "all"])
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

    This guide is long. `GET #{base}/api/guide?section=short` is the part
    needed to work a board, ending with the names of the rest, and
    `?section=<name>` is one of those (`all`, or no `section`, the whole
    guide; an unknown name is a `404` listing them).

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

    The `slipdock` CLI installs on Windows the same way, from here, Erlang and
    all (elsewhere it is built from the repository's `cli/`):

        irm #{base}/cli/install.ps1 | iex

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

    **Comment access** (#863) sits between read and write: a board, card,
    page or folder can be shared at `comment`. A commenter reads, and may
    comment (`POST …/comments`), report a status (`POST …/status`), vote with
    a comment, and delete their own comments — nothing else. Every change to
    the card or page itself (fields, list, checklist, links, attachments,
    dependencies, sub-board, archive, delete) is a `403 you don't edit this
    card`; a reader commenting gets `403 you don't comment on this card`.

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
    than the whole API: `whoami`, `get_guide` (this text, short; `section` for the
    rest), `list_boards`,
    `get_board`, `list_cards` (`full: true`: every card as `get_card`
    gives it, so a whole board reads in one call), `get_card`, `search`, `ask` (a
    model call, so slower), `read_page`, `list_pages`, `page_info`, `page_history`, `activity` (a
    board's log, or one card's), `download_file` (a file, by
    attachment id; `link: true`, a URL to curl), `list_automations`, and for
    writing `create_card`, `update_card` (fields, flags, tags, assignees,
    dependencies, the checklist, recurrence, snooze), `move_card` (to another board too),
    `comment`, `leave_handoff`, `upload_file` (onto a card or page;
    a shell: `link: true`), `complete_card`, `status_update` (a card's stated health, with
    a note: the progress report on an epic),
    `archive_card` (and restore), `delete_card`,
    `create_list`, `create_tag`, `delete_list`, `create_board`, `archive_board` (and
    restore), `delete_board`, `write_page`, `update_page` (a page's
    title, summary, parent, position and folder, archiving and restoring it,
    and pinning it to a card) and `revert_page` (a page
    back to a revision, as a new one, against `base_hash`),
    `manage_automation` (owner only), `list_tools`, `install_tool`, `garden` and
    `garden_decide` (tidy-up suggestions), and `claim_job`,
    `job_progress` and `finish_job` to take runner jobs from a board's
    queue (see "Runners" below). Archiving can be undone; the
    deletes can't, so `delete_card`
    needs `confirm: true`, `delete_board` needs `confirm` set to the board's
    code, and `delete_list` refuses a list holding cards unless
    `with_cards: true`. A read-only
    token, or a connection the person approved read-only, can call the read
    tools, and a write tool answers it with an error saying so. The conventions in this guide apply the same way through
    either door. Prompts: `plan-my-day`, `weekly-review`, `triage`, `resume`,
    `leave-handoff`, `tidy-board`. Resources, which the
    person attaches: `slipdock://card/42`, `board/`, `page/`, `view/`, `work`.

    ### The AI key, and which model answers

    Anything that asks a language model — the written answer from
    `POST /api/ask`, writing an automation rule in English, the chat and edit
    panels, the narrative — runs on the **account holder's own** key or
    endpoint, kept on the server, never shared.

    **Search is the exception.** `GET /api/search` (the MCP `search` tool,
    `slipdock search`), the index behind it and scheduled automations run on
    the **server's** AI: one admin's settings, chosen by an admin under
    Configuration → AI for search and automations. An index is searched with
    the model that built it, so it can't be yours. Your own key,
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
               "embed_model": null, "fallback_models": []}

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
      `show_age: false` leaves the age chip off the list's cards (`--no-show-age`),
      and `show_images: false` their front image (`--no-show-images`),
      whatever anyone's card views say.
    - **Card** — one unit of work: title, description, `priority`, `flags`,
      `tags`, `start_date`, `due_date`, `completed`, `percent_complete` (0–100,
      or null when nobody has said), `assignees` (everybody it is assigned to,
      lead first) and `assignee` (the lead alone), `position` within its list.
      `archived_at` is set on archived cards. `flag_attention` says who clears
      each of its flags (#2624): `{"review": {"attention": "auto", "why": "A
      verifier agent checks it and decides."}}`, where `person` means somebody
      has to act, `auto` that the board's own processes clear it (a blocker
      still open, a verify pool's verifier) and `none` a mark that asks
      nothing (`starred`). The board draws a `person` flag filled and an
      `auto` one outline only.
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
    - **Flags** — `flagged`, `blocked`, `review`, `waiting`, `starred`, `stuck`.
      Hand-set labels, independent of the computed `blocked` — except that a
      card flagged `blocked` loses the flag when the last card it depends on is
      completed or archived. `stuck` is the health monitor's (see *Health
      monitor*).
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
    - **Attachments** (`attachments`) — files the board holds, up to 250 MB
      each (a proxy in front of the server may refuse one request well before
      that: Cloudflare's free and pro plans stop at 100 MB, with a 413 that
      never reaches Slipdock — a person can still upload it in the browser,
      which sends it in chunks). Upload one as the multipart field `file`:
      `curl -H "$H" -F file=@shot.png B/api/cards/:id/attachments` (an optional
      `filename` field renames it, and an optional `sha256` field, the hex
      SHA-256 of the file, makes a file that arrives different a 422
      `sha256_mismatch` with nothing stored; `slipdock attach` always sends it;
      `replace=true` deletes the card's older files of the same name once it
      is stored, their ids in `replaced`, so a rebuild leaves one copy). The 201 carries the `attachment` with its
      `url`, its `size` and `sha256` as stored (every attachment listing has
      them, so checking a file needs no download) and a ready-made `markdown` — `![shot.png](/attachments/5/shot.png)`
      for an image, a plain link otherwise — to put in the description or a
      comment, where an image shows inline. `GET /api/cards/:id/attachments`
      lists them; `DELETE /api/cards/:id/attachments/:attachment_id` removes
      one (over MCP, `delete_attachment`). `GET /api/attachments/:attachment_id` is one file's details (with
      the `card` or `page` it is on), and `GET /api/attachments/:attachment_id/file`
      its bytes, with a token — the `url` is the web app's, which needs a
      browser session. A screenshot of what you changed is worth attaching. Pages take the
      same three at `/api/pages/:id/attachments`. With MCP but no token to hand,
      `upload_file` or `download_file` with `link: true` gives a single-use,
      ten-minute `/api/upload/:secret` or `/api/download/:secret` URL that
      needs none (#1147). A card's first image is the
      thumbnail on its front; `hide_on_card: true` (on the upload, or
      `PATCH /api/cards/:id/attachments/:attachment_id`) keeps one off it — do
      that for a log or a diagram nobody needs to see at a glance. A recording
      (`audio/…`) can be transcribed, when the server has a transcription server
      set up and an admin has given you *Transcription* (else 403): `POST /api/cards/:id/attachments/:attachment_id/transcribe` answers
      202 and works in the background; the attachment's `transcript_status`
      goes `running` → `done` (with `transcript`) or `failed` (with
      `transcript_error`). Read the transcript before summarising a call.
      PDFs and images are read for text by themselves, and search finds it:
      the attachment's `text_status` says how far that has got,
      `GET /api/attachments/:id/text` (MCP `download_file` with `text: true`)
      is the words, and `POST .../attachments/:attachment_id/read-text` tries
      again.
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
      board, a list, a card, a saved view or a wiki page. They are *personal*, so
      `GET /api/favourites` is the token holder's own set and nobody else's,
      and it is worth reading at the start of a session: it says where this
      person actually works, which a list of boards does not. Each entry gives
      a `kind`, a `name`, its `board` and the `url` that opens it. Add one with
      `POST /api/favourites {"kind": "card", "id": 42}` (`kind` is `board`,
      `column`, `card`, `view` or `page`) and remove it with
      `DELETE /api/favourites/:kind/:id`. Favouriting changes nothing about the
      thing itself, so read access is enough — and never favourite on someone's
      behalf unless they asked.
    - **Hotkeys** — `Ctrl+Shift` and a digit opens a board in the web app.
      The digits are the token holder's own, like favourites:
      `GET /api/hotkeys` lists them, and
      `PUT /api/boards/:board/hotkey {"digit": 1}` gives a board one (taking
      it off any other board) or `{"digit": null}` takes it away. Read access
      is enough. Set one only when the person asks. The wiki takes a digit
      too, and a switcher key: `PATCH /api/wiki {"hotkey": 2, "shortcut": "nt"}`.
    - **Header links** — boards and the wiki pinned as icons left of quick
      add, the token holder's own: `GET /api/header-links` (with the `icons`),
      `POST /api/header-links {"board": "ops", "icon": "star"}` (or
      `{"wiki": true, "icon": …}`),
      `PATCH /api/header-links/:id {"move": "left"}`, `DELETE` to unpin.
      Pin only when asked.
    - **Card views** — what the token holder sees of a card in the web app:
      each element of its front (`tags`, `due_date`, `handoff_note`…), of the
      opened card (`open.*`) and of its sidebar, properties included
      (`side.*`: `side.assignees`, `side.due`…), by global, board
      and list, each level stating only what it changes. They are personal,
      and your own output never follows them. `GET /api/card-views` lists the
      named ones and every element; `POST` and `PATCH /api/card-views/:id`
      take `name` and `show`, `hide`, `inherit` (lists) or `elements`
      (`{"comments": false}`, `null` to inherit); `DELETE` answers with
      `levels_now_inheriting`, the levels that applied it. A level is `GET`, `PUT` or
      `DELETE /api/card-views/level?board=ops&list=Done` (no `list` for the
      board's, neither for global); `PUT` also takes `card_view` (a named
      view to apply, `null` for none) and, on a board, `show_all`. `GET
      /api/card-views/applied?board=ops&list=Done&view=Sprint` is what a card
      there shows, each element with the level that decided it. Change them
      only when the person asks. CLI: `slipdock card-views`, `slipdock
      card-view set --board B --hide comments`; MCP: `card_views`.
    - **Skills registry** — skills fetched from outside Slipdock (#2059): the
      token holder's sources and the seeds. `GET /api/skill-sources` lists them
      with each skill's metadata and `content_hash`; `POST /api/skill-sources
      {"url": "https://github.com/owner/repo"}` fetches one (a refusal, such as
      an address that isn't public or a file over the cap, is a 422 with its
      sentence), and `"seed": true` makes it everyone's (admins only, else a
      403; a new server seeds `mattpocock/skills`); `GET /api/skill-sources/:id`, `POST
      /api/skill-sources/:id/refresh` (answers with `changes`: added, changed,
      removed) and `DELETE` are for its owner, an admin for a seed. `GET
      /api/skill-entries/:id` is one skill in full (`body`), where it is
      enabled (`enabled_on`, each with its `status` and, when it changed
      upstream, the `diff`) and the Playbook stages naming it. A board writer
      enables one with `POST /api/boards/:board/skills {"entry": 12, "hash":
      "<content_hash>"}`, pinned to that text (any other hash is refused),
      re-pins it with `PATCH /api/boards/:board/skills/:name {"hash": …}` and
      takes it off with `DELETE`. `GET /api/skill-stages` lists every Playbook
      stage you can read that names a skill and what it gets (`flagged` when
      nothing does). Only when the person asks. CLI: `slipdock registry`; MCP:
      `skill_registry`. What the board's agents get is `GET
      /api/boards/:board/skills` (a reader is enough; a board you can't read
      is a 404): each enabled skill's `name`, `source_name`, `licence`,
      `pinned_hash`, `status` (`current`, `changed`, `removed`) and its pinned
      `text`, never newer. CLI: `slipdock skills board <board> [<name>]`; MCP:
      `get_guide` with `board`, whose answer adds the same list as `skills`.
      `slipdock-plan` uses it for a Playbook stage that names a skill: enabled
      on the board, else installed, else its own text.
    - **Passkeys** — `GET /api/me/passkeys` lists the token holder's own
      passkeys (`id`, `name`, `created_at`, `last_used_at`; never the key), and
      `DELETE /api/me/passkeys/:id` removes one so it can no longer sign in.
      Adding one needs the person's device, so it happens only in a browser,
      on their account page. Remove one only when the person asks: it is a way
      into their account, not clutter.
    - **Inbound email** — when the server receives mail (W-1933),
      `GET /api/inbound/log` lists the token holder's last 50 messages to its
      inbound addresses, newest first: `kind`, `subject`, `outcome`
      (`accepted`, `rejected` = bounced, `dropped` = automatic, ignored), the
      `reason`, and a `link` to what it made. 404 while inbound mail is off.
      Look here when someone says they emailed something and nothing happened.
      `GET /api/boards/:board/inbound` is the holder's own `card` address for
      a board they can write to (`?folder=` a wiki folder's own `page`
      address), `GET /api/me/inbound` their personal `add`
      (Quick Add) address and `ack`; `POST …/rotate` replaces one, and the old
      bounces; `POST /api/me/inbound {"ack": true}` mails a link back per card.
      A board's `card` address also takes mail from its permitted senders
      (`senders` in that answer; the owner sets them with `PATCH
      /api/boards/:board {"inbound_senders": [...]}`, `[]` clears): added as
      the address's owner, opening "Sent by …", never answering a wait.
      Emails about a card (mentions, waits, rule emails) can be replied to: the
      reply is a comment by that person, or answers a wait on them; so is mail
      to a board's `card` address whose subject starts `[#42]`, on card 42.
    - **Recurring cards** — a card can repeat ("every Monday: review
      invoices"). Its `recurrence` says how (`rule`, `summary`, `next_on`,
      `next_at`, the next three in `upcoming`); `null` when it doesn't.
      `series_id` marks every instance a series made, and a single card's
      read (`GET /api/cards/:id`, `get_card`) names the one it was copied
      from as `copied_from` (`{id, title}`). The next instance is a copy of
      the current one made on the server's clock, in the board's ready
      list, starting clean: no assignees, flags, percent, handoff, waits,
      evidence or bar lock from the last one; one still open when the next is due has its due date moved
      on rather than a second made. Set it with
      `PUT /api/cards/:id/recurrence` (Recipes, below) or `update_card`'s
      `recurrence`, and never on a card the person didn't ask to repeat.
    - **Snoozed cards** — a card can be hidden until a day (W-1803). Until
      `snoozed_until` it is left out of the board's lists, `list_cards`,
      My work and the runners' picks; then it wakes at the top of its list,
      or sooner when someone else comments on it or assigns it. `snooze`
      says until when and why (`null` when it isn't snoozed). `GET
      /api/cards/:id` and search still find it, an epic still counts it as
      open, and `?snoozed=include` (or `only`) lists them. Snooze rather than
      flag `waiting` when the wait has a date (Recipes, below).
    - **Copying a card** — `POST /api/cards/:id/copy` makes a copy as it is
      now (checklist unticked, subcards reopened; no comments, dates or
      files), straight after it unless `board`, `column` or `at` say otherwise.
    - Also on a card, and safe to ignore until you need them: `status_updates`
      (a stated `on_track` / `at_risk` / `off_track` with a note), custom
      `fields` and formula `scores`, `votes`, `attachments`, `milestones` on the
      board, and saved views.

    The parts of a card's JSON that matter while you are working:

    ```json
    {
      "id": 42, "board_id": 1, "column_id": 4, "column": "To Do", "position": 0,
      "title": "Query parser", "description": "…",
      "handoff": {"next_step": "Wire the parser into search", "body": "State: …",
                  "via": "mcp", "by": {"id": 1, "name": "You"}, "at": "…"},
      "recurrence": null, "series_id": null, "snoozed_until": null, "snooze": null,
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
    task from an epic. `handoff` is where the card was left (`null` if
    nobody left one): read it before the comments. A finished card read on
    its own (`GET /api/cards/:id`, `get_card`) carries `outcome` instead:
    its `text` (*Done 6 Nov 14:32 · accepted by runner verifier · merged PR
    #215 (def5678)*, in your time zone), `done_at`, `accepted_by`, `pr`,
    `merge_sha` and `commit`. The handoff written before it finished is
    history then: it moves to `last_handoff` (`before_finish: true`) and
    `handoff` is `null`. One left after it finished, for what is still to
    do, stays the `handoff`.
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

    **Card shape.** How a one-sentence ask becomes a card, the same way
    whichever agent writes it:

    - **One card** when the ask fits one sitting, one agent and one PR and
      was said in a sentence; an epic with subcards only when it doesn't.
      Never an epic with one subcard, nor subcards the person didn't imply.
    - **Where:** under the epic it serves if there is one (search first);
      otherwise top level, without making an epic to hold it.
    - **Three things in the description**, each in proportion: what, in the
      person's words; where, if known; and a **done-when** line, the stop
      condition the evidence answers. One or two lines; no Given/When/Then
      unless the board's Playbook asks for it.
    - **Don't add** an estimate, priority, tags, a due date or an assignee
      unless the person said so or the board's convention does.
    - **Don't repeat the repo's rules** (tests, every door, the handbook
      line): whoever builds it reads those from the handbook and the repo.
    - **Two readings:** write the obvious one and note the other in the
      description; ask only when they differ materially, once, before filing.
    - **A bar item made moot** by a later, cited decision or rule: read it
      the obvious way and say so. Not a wait.
    - **Dependencies:** `blocked_by` means *can't start until*, not *should
      come after*: set it where a card builds on another's code, schema or
      decision, and use list position for mere preference. A one-card ask
      gets none unless the person said "after X". None on a simple board.

    A board's handbook can override these: the `## Card shape` section of
    its Playbook page wins wherever it says otherwise.

    Give an epic its subcards, then fill them:

        POST /api/cards/42/subboard        {"template": "Simple"}
        POST /api/boards/9/cards           {"title": "Query parser", "column": "To Do"}

    A new board takes its lists from `template`, or sets its own out with
    `POST /api/boards {"name": "Hiring", "columns": ["Applied", "Interview",
    "Done"], "save_template": "Hiring"}` — names like To Do, In Progress and
    Done get those roles, and `save_template` (a name, or `true` for the
    board's) keeps the lists as a new template in the same request.

    `GET /api/templates` lists the named sets of lists a new sub-board can be
    built from: the built-ins (`"system": true`, read-only to all: 403) and
    your own. The response to `POST …/subboard` includes the new board, whose
    `id` is what you add cards to. `DELETE /api/cards/42/subboard` removes the
    sub-board **and every card on it**, so treat it as a delete.

    **Stand-ins.** A card whose `stand_in_for` is set marks where a card
    went into a sprint. It is not work: do not pick it up, edit it or count
    it, act on the card it names. Sprints are their own section
    (`sprints`).

    **Simple boards.** A board with `"simple": true` is a plain to-do list
    (`PATCH /api/boards/:board {"simple": true}`, `slipdock set-board B
    --simple`; a new sub-board takes it from its parent). The web app hides
    % complete, start dates, health, time tracking, votes and dependencies
    on its cards, and leaves Timeline and Prioritise out of its views; a
    board's JSON lists the hidden card fields as `hidden_facets`, which no
    person's card views bring back. The API
    still reads and writes all of them — nothing is deleted — but on a
    simple board, keep to what the person can see: do not set `--percent`,
    start dates, estimates or dependencies there unless asked to.


    Tags live on the root board and are shared by the whole tree, so a tag made
    anywhere below it is available everywhere — but a tag must exist before a
    card can wear it (`POST /api/boards/:board/tags`, `slipdock new-tag`, or the MCP
    tool `create_tag`). Renaming an epic renames
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

  # Moved out of *Epics and subcards* (#2042) to keep the short guide, which
  # carries that section whole, under its budget.
  defp sprints do
    """

    ## Sprints

    A board whose `kind` is `"sprints"` (made from the "Sprint
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
    need to choose. Snoozed cards are not in it: they are not ready until the
    day they wake. If `paused` is set, take nothing and stop.

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

    Read the card's `handoff` first: where it was left, and the next step.

        POST  /api/cards/57/move        {"column": "In Progress"}
        PATCH /api/cards/57             {"assignee": "you@example.com"}
        POST  /api/cards/57/comments    {"body": "Starting. Plan: …"}

    A card can have several people on it. `assignee` (or `assignees`, a list)
    replaces whoever is there; to join a card somebody else already holds
    without taking it off them, send `{"add_assignees": ["me"]}`, and
    `remove_assignees` to step off. `"me"` is whoever the token belongs to.
    Only somebody who can open the card can be put on it: share the board
    with them first. Anybody else is the same `404 user …`, account or not.

    Move the epic above it into its own `doing` list too, so the top of the
    board reads true while you are inside the tree. `move` takes an optional
    `index`: `"top"`, `"bottom"` (the default) or a number.

    ### While you work

    - **Every decision, surprise or dead end → a comment.** In Markdown, for
      someone reading it in a month: a bold first line, then short bullets —
      what you chose, what you rejected, the commit or file — never one dense
      paragraph. The part people value, and the part agents skip.
    - **A long job → say so while it is still running.** Anything that will
      take more than a short sitting — a big refactor, a migration, a build you
      are babysitting — gets interim comments at its milestones, not one
      write-up at the end: what has landed, what is left, whether the shape of
      it has changed. Move the number with it, so the board reads true without
      anyone opening the card:

          PATCH /api/cards/57             {"percent_complete": 40}
          POST  /api/cards/57/comments    {"body": "Parser done, codegen next; …"}

      A card sitting in `doing` for hours with nothing newer than the move on
      it looks abandoned.
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
      to be in flight. When #7 is done the board takes the flag off by itself,
      with a comment, and the card is ready again.
    - **Stuck on a person** — a decision, a credential, an approval: open a
      wait, `POST /api/cards/57/wait {"needs": "…"}` (MCP `update_card`
      `wait`), naming exactly what you need, and stop. The answer comes back.
      Several questions go as `{"questions": ["…", "…"]}`, one each, never
      one block: each gets its own numbered answer box.
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

    Re-read the card before committing, and its comments once the build
    starts: anything new is still this card. A done card's handoff is only
    what the person must do or check; else `{"clear": true}`.

    In a git repository, commit before closing: one commit (or PR) per card,
    naming it (`#57`). Link the commit or PR in the closing comment (no
    remote: the short hash and branch).

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

    Only when its subcards really are all done (`rollup.done == rollup.total`,
    `rollup.blocked == false`): comment what the epic delivered, mark it
    `completed` and move it to `done`. Else leave it in `doing` and take the
    next subcard. An agent closing it over open (not done, not archived)
    subcards is refused, 422, naming them.

    ### Ending a session mid-card

    Leave a handoff whenever you stop with the card unfinished: the one next
    step and a short note (State, Gotchas, Open, Pointers).

        POST  /api/cards/57/handoff  {"next_step": "…", "body": "State: …"}

    Then leave it in `doing` if you are coming straight back, else move it
    back to the ready list. Never leave a card in `doing` with no comment
    newer than the move — nobody can tell whether it is alive.

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
    - **Do not complete an epic with open subcards, or reopen a done card**;
      never move a card to `done` without `completed: true` (or the reverse).
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
      meant. `POST /api/boards/welcome` builds a fresh one.
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
    card, comment, status update and recording transcript on every board you can
    see, so the words in
    the query need not appear anywhere in the result. Reach for it when:

    - the person describes a thing rather than naming it — "the card about the
      refund rounding problem", "whatever we said about the vendor contract";
    - the answer is likely in a **comment** or a status update rather than a
      title, which is where most of what a team actually decided ends up;
    - you do not know which board to look on. Substring search is per board;
      this is across all of them at once.

    Each result is a card (or a wiki page), with `matches`: the chunks that matched, each with
    its `kind` (`card`, `comment`, `status_update`, `transcript`, …), the text
    and a `url` that lands on that chunk rather than the card —
    `…/cards/12?at=comment-7`, `…/cards/12?at=transcript-5-part-2`. Read the
    match, not just the title — it is why the card came back — and give the
    person the match's `url` when you point them at it. Then
    `GET /api/cards/<id>` for the whole thing before acting on it.

    Archived cards are left out unless you pass `archived=true` (each card
    result says `archived`). A card's id (`#123`) or its link as `q` finds that
    one card first, archived or not, if you can read it — a link returns only
    the card, and works even where semantic search isn't set up.

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
    asked a question in words and wants an answer rather than a list. Over
    MCP it is the `ask` tool (`question`, and `board` to keep to one).

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

    # record something already finished with: "archived": true (or "true") files it
    # away at once. A field a new card doesn't take, a typo like "archved", is a 422
    # naming it, and no card is made
    curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/cards \\
         -d '{"title": "Old release notes", "archived": true}'

    # claim, comment, tick, finish
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/move \\
         -d '{"column": "In Progress"}'
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/comments \\
         -d '{"body": "Parser handles quoted phrases; see lib/slipdock/search.ex"}'
    curl -s -X POST -H "$H" B/api/checklist/11/toggle
    # reorder its checklist: item 13 before item 11 ({} or "before": null puts it
    # last); answers the checklist in its new order. A before from another card
    # or page is a 404 (CLI: slipdock move-check 13 --before 11)
    curl -s -H "$H" -H 'content-type: application/json' B/api/checklist/13/move \\
         -d '{"before": 11}'
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/cards/57 \\
         -d '{"completed": true, "remove_flags": ["blocked"]}'

    # what happened on this board lately
    curl -s -H "$H" "B/api/boards/1/activity?limit=20"

    # its flow numbers: in progress, waiting, done this week, time to done,
    # moves forward and back, each list's in/out (MCP: get_board pulse: true)
    curl -s -H "$H" B/api/boards/1/pulse

    # its flow day by day over 7, 30 or 90 days, and how its runners are doing
    # (MCP: get_board history: true / runners: true)
    curl -s -H "$H" "B/api/boards/1/flow?days=30"
    curl -s -H "$H" B/api/boards/1/runner_stats

    # how well agent work goes over ?days= (30 unless given; CLI: slipdock
    # quality): verified.first_time_right of verified.accepted (accepted with
    # no rejection and never reopened), rejections per accepted card, areas
    # (each card under the handbook page covering most of its lane paths, or
    # "unmapped"), jobs (timeouts, failed, requeues, gave_up, each per_100
    # finished jobs) and health (incidents fixed, flagged, cleared, open);
    # previous is the window before's verified numbers. rejections counts the
    # verifiers' rejections in parts: by_part (ask, bar, rules, suite,
    # handbook_line, mutants), by_rule (id, count, severity and page, most broken
    # first), disputed_lines and unparted (naming no part); audits counts
    # audits agreed and disagreed. slipdock quality --rules lists every rule
    curl -s -H "$H" "B/api/boards/1/quality?days=30"

    # the ledger: what shipped on the tree since ?since= (days, a date or an
    # ISO time; 07:00 yesterday in the board's timezone by default), by day:
    # each card completed, accepted, merged or deployed, with accepted_by
    # (person or agent), audit, the evidence's first line, should_broken
    # rules, pr, deploys, lead_time phases and cost (model_seconds,
    # tool_seconds, jobs, and tokens only when a log carried usage), an
    # epic's subcards and the card's
    # url (its panel, at the chat). CLI: slipdock ledger <board> [--since S];
    # MCP: activity view: "ledger"
    curl -s -H "$H" "B/api/boards/1/ledger?since=1"

    # cards past their list's usual stay, and who holds them (driver=all|agent|human)
    curl -s -H "$H" "B/api/boards/1/cards?stuck=true&driver=agent"

    # waiting on a person: open a wait, answer it (text, a choice from 1, or both),
    # withdraw it (MCP: update_card wait / answer_wait; CLI: slipdock wait, answer)
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait \
         -d '{"needs": "Which region?", "on": "dana@example.com", "choices": ["eu", "us"]}'
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait/answer \
         -d '{"choice": 1, "answer": "eu, for the data rules"}'
    curl -s -X DELETE -H "$H" B/api/cards/57/wait

    # several questions at once, numbered (CLI: slipdock wait 57 --question … --question …);
    # answered one per question ("" leaves one), or skipped; then every one the card asked
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait \
         -d '{"questions": ["Which region?", "How many seats?"]}'
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait/answer \
         -d '{"answers": ["eu", "12"]}'
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait/answer \
         -d '{"skip": true}'
    curl -s -H "$H" B/api/cards/57/waits

    # who gets asked (#1949): give a wait its question kind (product, ux,
    # security, release, other; other by default) and leave "on" out: it goes
    # to the first person the board routes that kind to (the rest are told),
    # else the owner. The owner sets wait_routes, each a list of the board's
    # users ([] takes one off). CLI: slipdock wait 57 "…" --kind product;
    # slipdock set-board 1 --route product=dana@example.com --no-route ux.
    # MCP: update_card wait question; update_board wait_routes
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait \
         -d '{"needs": "Which pricing tier ships first?", "question": "product"}'
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/boards/1 \
         -d '{"wait_routes": {"product": ["dana@example.com"], "release": []}}'

    # what is waiting on you, oldest first, then your cards by due (?board=1, ?done=true)
    curl -s -H "$H" B/api/work
    # off your own Waiting on you (#2069): dismiss one item, held on its cause
    # (a new cause shows again), list and undo; mute a board's tree, unmute.
    # CLI: slipdock work --dismiss 57 / --dismissed / --undismiss 57 / --mute ops / --unmute ops
    # MCP: update_card waiting_list dismiss|undismiss; update_board waiting_list mute|unmute
    curl -s -H "$H" -H 'content-type: application/json' B/api/work/dismissed -d '{"card": 57}'
    curl -s -H "$H" B/api/work/dismissed
    curl -s -X DELETE -H "$H" B/api/work/dismissed/57
    curl -s -H "$H" -H 'content-type: application/json' B/api/work/muted -d '{"board": "ops"}'
    curl -s -X DELETE -H "$H" B/api/work/muted/ops

    # the top 5 cards of lists from several boards, by board, list or grid
    # (lists: ids or board/list; none: the view saved on the Multiboard page)
    curl -s -G -H "$H" B/api/multiboard --data-urlencode 'lists=12,ops/To Do' -d top=5 -d by=grid
    # saved multiboards: named views on your home page (GET one = its cards)
    curl -s -H "$H" B/api/multiboards
    curl -s -X POST -H "$H" -H 'content-type: application/json' B/api/multiboards \
      -d '{"name":"Ops queue","color":"rose","lists":"ops/To Do,12","top":3}'
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/multiboards/4 -d '{"color":"teal"}'

    # the boards themselves (owner only; ask before doing either)
    curl -s -X POST -H "$H" B/api/boards/1/archive    # put a board away, keeping everything on it
    curl -s -X POST -H "$H" B/api/boards/1/restore    # and bring it back
    curl -s -X POST -H "$H" B/api/boards/welcome      # the Getting Started tour board, again
    curl -s -X POST -H "$H" -H 'content-type: application/json' B/api/boards/order \
         -d '{"boards": ["roadmap", "qvm-v1-rem", 3]}'   # your own order for the index
    ```

    Keep titles short: about 60 characters at most, a series as
    `<Series> <n>: <what>`, the detail in the description. Things written in
    numbers need titles that tell them apart, and nothing written for a card
    needs to repeat the card's title: its folder says that already.

    A long title gets a short name by itself (`short_name`, for tight spaces
    and the card's folder on disk): over 40 characters one is made on save, by
    the cheapest model when there is a key. `short_name` on a card write sets
    your own, and `""` hands it back.

    A page written for a card lives in the card's folder,
    `<Board>/Cards/<card>/`, made on first use and tied to the card by id, so
    renaming the card renames it: `POST /api/cards/:id/pages`, or `card` on
    `POST /api/boards/:b/pages` and MCP `write_page`. Attaching an existing
    page (`pin_card`) is a link, and moves nothing. A page there titled like
    the card, as "write it up" makes, keeps that title and takes the card's
    short name on disk: `Cards/<short>/<short>.md`. A pass log is
    `Pass <n> (<YYYY-MM-DD HH.MM>)`, there too.

    ### Waits, pauses and a card's state

    **A wait** is a card waiting on a person: what it `needs`, who it is
    `on` (a person, or `null` for anyone), optional `choices`, and when and by
    whom it was opened. A card has at most one open one, shown as its `wait`.
    Opening one flags the card `waiting` and comments the question; removing
    that flag by hand withdraws it; answering posts the answer as a comment
    from whoever answered and clears the flag if the wait set it. An agent
    cannot answer a wait it opened itself. Completing or archiving the card
    closes it. A wait opened from a runner job parks the job, and the answer
    sends the card to its rule again (see Runners). Prefer a wait to a bare
    `waiting` flag: the flag has no clock, no owner and no way back.

    **When to wait, and when not.** A wait is for readings that differ
    materially in cost or in what the person sees, for decisions the
    Playbook or the board routes to a person (product, ux, security,
    release), and for anything a rule says is a person's step (merging,
    changing a handbook rule, deploying). A locked bar item that a later,
    cited decision or rule has made moot is not one: read it the obvious
    way, say so on the card (what you read, why, the citation) and leave
    the judgement to the verifier, who accepts a noted reading and rejects
    one that wasn't noted. A wait offering choices and a proposed answer is
    an approval and should be rare; when raised, it names the default you
    would take as `default` (the choice's number, from 1; CLI `--default
    N`), so the answer can be one click.

    **A moot wait clears itself.** Sent a card (or its epic) with an open
    wait, check first that it is still live: the question answered
    elsewhere, the bar or description edited since, the cited rule or
    decision now in place, the card rejected or accepted since. Withdraw a
    moot one with why, `DELETE /api/cards/:id/wait?reason=…` (MCP
    `update_card` `wait: null` with `wait_reason`; CLI `slipdock wait <id>
    --withdraw --reason "…"`), and carry on to the obvious reading. Any
    agent may, not only the one that opened it, but an agent withdrawing a
    wait it didn't open is refused (422) without a reason; the comment
    carries it. A board's `wait_default_after` (off unless set: `4h`,
    `90m`, `2d`) lets an approval wait, of kind `other` with choices and a
    `default`, go unanswered that long and then resolve to its default:
    the card says so, the person asked is told, and the card moves on as
    on an answer. Never for a product, ux, security or release question,
    nor a wait with no default.

    **Several questions** go in one wait as `questions` (at most 20), never
    as one block in `needs`: each is shown numbered with its own answer box,
    and `needs` becomes the line in front of them (a `needs` written as a
    numbered list `1. … 2. …` is split the same way). Answer with `answers`,
    one per question in order (or `{"2": "…"}` by number; `""` leaves one
    unanswered), kept on the wait as `answers`. `{"skip": true}` skips them
    all: the wait closes as `skipped` and the card moves on as it would on
    an answer, a runner job's card going to its rule again told to use its
    own judgement. `GET /api/cards/:id/waits` (MCP `get_card` `waits: true`,
    CLI `slipdock waits <id>`) lists every wait the card has had, newest
    first, with the answers.

    **Waiting on you.** `GET /api/work` (MCP: the `plan-my-day` prompt;
    CLI: `slipdock work`) answers `waiting`, oldest
    first, each with its reason and how long it has waited — open waits on
    you or on anyone on your cards, your cards flagged `review` or
    `waiting`, cards the runner gave up on or whose newest job failed on
    boards you own, cards in a doing list for over an hour with nobody
    on them, and cards still in a Scheduled list after the end of their due
    day (`scheduled_missed`) — then `sections`, your cards by when they are due.
    A card awaiting verification on a tree you own (reason `verify`) is on
    you only when no runner has it in hand: not while a verify job for it
    is claimed or running, nor, for 15 minutes after it was submitted, while
    one is queued or a runner of its board's verify pool is online. Past
    that with no verify job started it comes back; with no verifier it is
    on you at once. You can accept or reject it by hand either way. A merge
    job that failed on something a rebase fixes (a conflict, a head that
    moved) is left out while a build job is claimed or running on the card
    or a card above it; any other failure shows as before. The
    overseer's open conditions (reason `overseer`, each with its
    `condition`: `check`, `why`, `todo`) come first; cards on a *Getting
    Started* tour board never come at all. `GET /api/me` and `whoami` carry
    the count as `waiting_on_you`, and the overseer's conditions among them
    as `overseer`.

    **What in an epic's tree waits on you.** `GET /api/cards/:id` (MCP
    `get_card`) carries `waiting_on_me` for the card's sub-board tree, and
    `GET /api/boards/:board` (MCP `get_board`) for the board's whole tree,
    with each epic in its lists carrying its own: `{count, cards,
    on_others, line}`. `count` is the items on you; `cards` those items,
    each exactly as `GET /api/work` gives it plus `short` (`a question`,
    `3 rejections`, `a failed job`); `on_others` the open waits in the tree
    on someone else by name, never counted; `line` the tile's glance line
    (`Waiting on you: #2063 (a question) and 1 on someone else`), null when
    nothing waits. A card with no subcards has `count` 0. A wait on you
    (or a card past the rejection limit) also raises an alert only you see,
    and its email, each on by default and off in account settings.

    **Off your own list.** Each item has a `cause` (`job:812`, `wait:40`,
    `flag:review:<unix time>`, …). `POST /api/work/dismissed` (`card`) takes the
    card off your list for that cause only: a new cause (a second failed job,
    a new wait) shows it again, and a card with another reason shows for
    that one. `POST /api/work/muted` (`board`) keeps a board's whole tree off
    it. The board works as before for everyone. Both are yours alone and
    need only read access. `GET /api/work` says what is hidden:
    `dismissed_count`, `muted_count` (cards a mute keeps off) and
    `muted_boards`. `GET /api/work/dismissed` lists the dismissed items,
    `DELETE /api/work/dismissed/:card` undoes one and `DELETE
    /api/work/muted/:board` unmutes. Over MCP, `update_card` and
    `update_board` take `waiting_list` on its own, and `whoami` carries
    `waiting_hidden`. Never dismiss for a person what they haven't asked
    you to.

    **A pause.** While a board tree or one of its runner pools is paused,
    `GET` of the board and its cards, `get_board` and `list_cards` carry
    `paused`: a list of `{scope, reason, by, line, paused_at}`. If it is
    set, take nothing and stop; resuming is a person's (see Runners).

    **A card's state**, worked out from what is already recorded and left
    out when there is nothing to say: `state` (one line: "Waiting on Dana ·
    41m", "Held · paused by David: bad deploy", "Running · runner-2 · 7m"),
    `held` (why its queued job waits), `loop` (`{runner, kind, job_id}`
    while a runner job holds it: shown beside the assignees, never one, so
    a runner's agent doesn't assign the card), `driver` (`agent` while a
    runner job holds it, else who last moved it — runner boards only), `in_list_since`
    and `age` (seconds in its list), `usual_stay` (the list's 85th-percentile
    stay), `over_usual` and `stuck` (past it). The `stuck` and `driver`
    filters read the same values.

    **Who made a card and who changed it last**, on a single card (`GET
    /api/cards/:id`, MCP `get_card`, `slipdock card`): `created_by` and
    `updated_by`, each `{kind, name, user_id}` with `kind` one of `person`,
    `agent`, `runner` (with `job_id`, named for its loop: "Dev server
    loop") or `automation` (the rule's name), or null when nobody was
    recorded; never a guessed name. `updated_at` there is the last change
    of any kind (comments, checklist, attachments and flags too): the later
    of the newest activity entry and the card's own `updated_at`.

    **A card's timeline**: `GET /api/cards/:id/timeline` (MCP `get_card`
    with `timeline: true`, CLI `slipdock timeline <id>`) gives `stays` (each
    list it sat in, with `how` it got there and who), `waits` and `jobs`,
    each with `from`, `to`, `seconds` and `open`; `unsure` marks a stay the
    ledger can't vouch for.

    **Its lead time and cost** (#1954): `GET /api/cards/:id` and MCP
    `get_card` carry `lead_time` on a card a runner job was sent on, and on
    an epic (any other card leaves it out). It has `seconds` and `ends` (`deployed`,
    `completed` or `open`), `phases` (each phase with any time, in seconds)
    and `cost`, which is what its jobs spent, from their logs. `cost` has a
    `total` and the `phases` the jobs ran in (build, rework, verify, merge).
    Each gives `model_seconds`, `tool_seconds`, `jobs`, and `tokens`
    (`input`, `output`, `cache_read`, `cache_write`, `total`) only when a
    log carried `usage`. `cost` is null when no job sent a log. On an epic,
    `rollup` adds its subcards: `subcards`, their `seconds` added up, and
    the `cost` of theirs and the epic's own jobs together. No prices: what
    tokens cost is yours to work out. CLI: `slipdock card` (`Lead time:`).

    ### What comes back

    The samples below are real responses, trimmed: every field shown is
    there, and the real thing carries more. URLs inside them are relative to
    the server (`/boards/3/cards/57`), not absolute.

    **A whole board.** Each list carries its own `cards` (and the wiki
    `pages` placed in it), in order, so one call draws the board; a card
    inside a list has `column: null`, since the list it sits in says that.
    Reach for `/boards/1/cards` when you want a filter, not to fill the lists.

    ```sh
    curl -s -H "$H" B/api/boards/1
    ```

    ```json
    {"board": {"id": 1, "name": "Delivery", "code": "delivery", "simple": false,
      "columns": [{"id": 9, "name": "To Do", "category": "todo", "position": 0,
                   "cards": [{"id": 57, "title": "Refund rounding", "column": null,
                              "column_id": 9, "position": 0, "completed": false}],
                   "pages": []}],
      "tags": [{"id": 4, "name": "api", "color": "sky"}]}}
    ```

    **One card.** A comment is `id`, `body`, `author` and `inserted_at`. The
    `author` is who wrote it, `{id, name, email}` as an assignee is; it is
    `null` on comments written before authors were kept and on the ones the
    server writes itself (automations, runner notes). A status update names
    its writer by `user_id`. A checklist item is `id`, `position`, `done` and
    `text`.

    ```sh
    curl -s -H "$H" B/api/cards/57
    ```

    ```json
    {"card": {"id": 57, "title": "Refund rounding", "column": "To Do", "column_id": 9,
      "completed": false, "stated_health": "at_risk",
      "checklist": {"done": 0, "total": 1,
                    "items": [{"id": 11, "position": 0, "done": false, "text": "Write the test"}]},
      "comments": [{"id": 1411, "body": "Rollback was blocked on approvals",
                    "author": {"id": 2, "name": "Ada", "email": "ada@example.com"},
                    "inserted_at": "2026-10-13T00:41:41Z"}],
      "status_updates": [{"id": 7, "health": "at_risk", "body": "Waiting on finance",
                          "user_id": 2, "inserted_at": "2026-10-13T00:50:00Z"}]}}
    ```

    **A stated health.** `POST /api/cards/:id/status` takes `health` —
    `on_track`, `at_risk` or `off_track` — and an optional `body` of up to
    4000 characters. It answers `201` with the whole card, the new update
    first in `status_updates` and `stated_health` set from it; any other
    `health` is a `422`. Over MCP it is the `status_update` tool.

    **Step statuses.** The server posts the routine ones itself, as an
    `on_track` update with no user (`user_id: null`, shown as *Slipdock*),
    at each step an agent-worked card goes through: a build job claimed
    (`Writing code`, or `Reworking after verify failed` after a
    rejection), a wait opened (`Waiting for human`), submitted (`Verifying`
    with a verify pool, else `Waiting for human to accept`), rejected
    (`Verify failed; queued for rework`), over the rejection limit
    (`Waiting for human (rejection limit)`), held for a person (`Waiting
    for human (held before merge)`), accepted on a pull-request board
    (`Accepted; merging`), merged (`Merged`), completed (`Done`), reopened
    (`Reopened`) and deployed (`Shipped to production`). The same text is
    never posted twice in a row, and these tell no watcher: they write no
    activity line. Don't post them yourself; post one only to add what the
    server can't know (a risk, a slip), and a person's update tells
    watchers as it always did.

    ```sh
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/status \\
         -d '{"health": "at_risk", "body": "Waiting on finance"}'
    ```

    ```json
    {"card": {"id": 57, "title": "Refund rounding", "stated_health": "at_risk",
      "status_updates": [{"id": 7, "health": "at_risk", "body": "Waiting on finance",
                          "user_id": 2, "inserted_at": "2026-10-13T00:50:00Z"}]}}
    ```

    ```json
    {"error": "validation failed", "details": {"health": ["is invalid"]}}
    ```

    **A handoff.** Where the card was left, for whoever picks it up next.
    `POST /api/cards/:id/handoff` takes `next_step` (one line, at most 280,
    required) and an optional `body` of up to 8000, or `{"clear": true}`;
    anyone who may comment on the card may write one. Each write is a new
    row: the newest is the card's `handoff` (`null` when there is none or it
    was cleared), and `GET` gives it with every earlier one as `history`,
    newest first. A runner job that ends with its card open writes its
    summary as one (`via: "runner"`) unless the agent wrote one during the
    job, or the card is already accepted (merging, held or accepted): a
    verifier's summary isn't the next step. `DELETE /api/cards/:id/handoff` deletes the current one outright
    (its author, or anyone who can edit the card): it answers `deleted` and
    the `handoff` now current, the one before it or `null`. Over MCP it is
    the `leave_handoff` tool (`delete: true` deletes). A board can call it
    something other than "Left off" in the web app and give the web app's
    Auto generate its own instructions: `PATCH /api/boards/:board
    {"handoff_label": "Parked", "handoff_prompt": "…"}` (`""` for the
    defaults; the board's `GET` answers both). Agent-facing text keeps
    "Left off:".
    A board's *Verified work* switches (`bar_required`,
    `evidence_required`, `verify_work`, `verify_pool`, `ship_via`) are set the same
    way; the *Verified work* section describes them when one of your boards
    has one on. So is `profiles` (`true` gives each card an agent starts one
    word of profile, #1951); the *Profiles* section describes it then.

    ```sh
    curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/handoff \\
         -d '{"next_step": "Write the rounding test", "body": "State: fix is in, untested"}'
    ```

    ```json
    {"card": 57, "handoff": {"id": 3, "next_step": "Write the rounding test",
      "body": "State: fix is in, untested", "cleared": false, "via": "api",
      "job_id": null, "by": {"id": 2, "name": "Ada", "email": "ada@example.com"},
      "at": "2026-10-18T09:12:00Z"}}
    ```

    **A recurring card.** `PUT /api/cards/:id/recurrence` makes the card
    repeat, or changes how: `rule` is a phrase (`every mon`, `weekday`,
    `2w mon thu`, `month 1`, `month last fri`, `year`, `3d after` — three
    days after the last one is done) or an RRULE subset
    (`FREQ=WEEKLY;BYDAY=MO`); with it `at` (`"07:00"`, the time each one is
    made), `timezone` (the token holder's by default), `lead_days` (make it
    that many days before it is due), `on_missed` (`bump`, the default: an
    instance still open has its due date moved on; `skip`; or `stack`),
    `ends` (`never`, `on` with `ends_on`, `after` with `count`), `column`
    (the list each one is made in: without it, the board's Scheduled list
    when it has one, else its ready list) and `paused`. Only `rule` is
    needed to start one; a card with no due
    date becomes the first occurrence. `GET` reads it (from an older
    instance too, with `current: false`), `DELETE` stops it, and
    `POST …/recurrence/skip` lets the next one go. Every occurrence keeps the
    title and gets the short name `<title or short name> <YYYY-MM-DD>`, its
    due date, so their folders tell themselves apart.
    `GET /api/boards/:board/recurring` lists a board's. Over MCP it is
    `update_card`'s `recurrence` (`null` stops it, `skip: true` skips one).

    ```sh
    curl -s -X PUT -H "$H" -H 'content-type: application/json' B/api/cards/57/recurrence \\
         -d '{"rule": "every mon", "at": "08:00"}'
    ```

    ```json
    {"card": 57, "recurrence": {"id": 4, "card_id": 57, "kind": "fixed",
      "rule": "FREQ=WEEKLY;BYDAY=MO", "summary": "Every week on Mon, 08:00 Europe/London",
      "at": "08:00", "timezone": "Europe/London", "lead_days": 0, "on_missed": "bump",
      "ends": "never", "made": 1, "next_on": "2026-10-26", "next_at": "2026-10-26T08:00:00Z",
      "upcoming": ["2026-10-26", "2026-11-02", "2026-11-09"], "paused": false}}
    ```

    **Snoozing a card.** `POST /api/cards/:id/snooze` hides it until
    `until`: a date (`2026-11-02`, midnight in the token holder's timezone),
    a datetime, or a phrase (`tomorrow`, `mon`, `next week`, `in 3 days`).
    With it `note` (why, at most 280 characters), `notify` (alert the board
    when it wakes) and `wake_on_activity` (default `true`: someone else's
    comment or assignment wakes it). The past, a completed card and unknown
    fields are refused. `DELETE` wakes it now. Both answer the card, with
    `snoozed_until` and `snooze`. `GET /api/boards/:board/cards?snoozed=only`
    lists what is asleep. Over MCP it is `update_card`'s `snoozed_until`
    (`null` wakes it) and `snooze_note`, and `list_cards`' `snoozed`.
    Snooze when the person says a card can wait until a day, or when what
    it waits for has a date; flag it `waiting` when it doesn't.

    ```sh
    curl -s -X POST -H "$H" -H 'content-type: application/json' B/api/cards/57/snooze \\
         -d '{"until": "next week", "note": "waiting for the quote"}'
    ```

    **Tidying up a board.** The gardener (W-1807) looks a board and every
    board beneath it over for rot — epics done but open, Done cards never
    completed, completed cards outside Done, cards stuck in progress, epics
    with no next step, long-overdue and abandoned cards, likely duplicates,
    pages nothing links to, `[[links]]` that nearly match a page, cards
    closed on a handbook board without a `Handbook:` line, and on a
    handbook board long handbook sections (`long_section`), `covers:` that
    match everything (`broad_covers`), `must` rules left to `judgement`
    and rule ids used twice (`rule_without_check`), and decisions that
    supersede one without linking back or aren't titled `Decision:`
    (`stale_decision`), and rules an agent added, reworded or removed since
    a person approved them (`rule_changed`: apply reverts them, dismiss
    keeps them) — and keeps a suggestion for each. `POST /api/boards/:board/garden` (optionally
    `check`) looks it over now; `GET` lists the open suggestions, the last
    run and every check's settings. A suggestion has `check`, `explanation`,
    `cards`, `pages`, `proposal` (its steps), `alternatives` and
    `needs_keep`. `POST /api/garden/suggestions/:id/apply` (`choice`: an
    alternative by name; `keep`: the card that stays, for a duplicate),
    `…/dismiss` and `…/undo` decide one (each takes `confirm: true`, the
    person's say-so: see below); `PATCH
    /api/boards/:board/garden/settings` sets a check's `enabled` and
    thresholds. Over MCP it is `garden` and `garden_decide` (`confirm: true`).
    Show the person the suggestions and apply only what they approve; never
    dismiss one on your own, since a dismissal is remembered until its
    subject changes. A suggestion applied can be undone, unless something has
    moved on since.

    ```sh
    curl -s -X POST -H "$H" B/api/boards/ops/garden
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/garden/suggestions/41/apply -d '{"choice": "snooze"}'
    ```

    **Proposing a handbook edit.** Describe freely, but don't rewrite a
    rule or a decision on your own say: propose it, and a person applies,
    dismisses or undoes it. `POST /api/boards/:board/garden/proposals`
    (`slipdock garden propose <board> <file.json | ->`) takes
    `explanation`, `steps` and the evidence as ids, `findings` and `cards`.
    A step is `edit_section` (`page`, as an id or a code; `section`, its
    heading path; `body`, the new text, as `slipdock page section` writes
    it; `base`, filled in from the section as it is now when left out),
    `comment` (`card`, `body`) or `file_page` (`page`, `folder`); any
    other op is refused. It answers `201` with the suggestion (check
    `proposal`, `person_only: true`, its `findings`), or `200` and
    `created: false` with the one already filed: the same proposal again,
    even one a person dismissed, makes nothing new. Applying it refuses a
    section changed since `base`, and undoing it refuses a page edited
    since. An agent can't apply, dismiss or undo a proposal, or any
    suggestion with an `edit_section` step, over REST or the CLI: only a
    person can, on the Tidy-up page (which shows the section's diff) or with
    `slipdock garden apply <id>`. Under Claude Code the CLI says it is an
    agent, so a person deciding a proposal from Claude Code adds `--confirm`
    (`slipdock garden apply|dismiss|undo <id> --confirm`, REST `confirm:
    true`): their say-so makes the decision theirs, as `garden_decide`'s
    `confirm: true` does over MCP. A runner job's confirm is refused, and so
    is a bare script token's: only a person's own session decides one.

    ```sh
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/boards/ops/garden/proposals -d '{
           "explanation": "UX-4 keeps breaking: name the tokens",
           "steps": [{"op": "edit_section", "page": "W-12", "section": "UX & UI/Rules",
                      "body": "- **UX-4** must · judgement · Design tokens only."}],
           "findings": [31, 34]}'
    ```

    **Search.** `GET /api/search` takes `q`, and optionally `board` (id,
    code or name), `kind` (`cards`, `pages` or `all`), `limit` (default 20,
    at most 50) and `archived=true`. A result is either a card or a page:
    `kind` says which, `subject` has the title and URL whichever it is, and
    the other of `card`/`page` is `null`. Read the title from `subject`.

    ```sh
    curl -sH "$H" --get --data-urlencode 'q=staging rollback' -d board=delivery -d limit=5 \\
      B/api/search
    ```

    ```json
    {"query": "staging rollback", "count": 1,
     "results": [{"kind": "card", "score": 0.5422,
       "subject": {"title": "Refund rounding", "url": "/boards/1/cards/57"},
       "card": {"id": 57, "title": "Refund rounding", "completed": false, "priority": "none",
                "due_date": null, "archived": false, "tags": [],
                "board": {"id": 1, "name": "Delivery", "code": "delivery"},
                "column": {"id": 9, "name": "To Do"}, "url": "/boards/1/cards/57"},
       "page": null,
       "matches": [{"kind": "comment", "source_id": 1411, "section": null, "score": 0.5422,
                    "text": "Comment on card “Refund rounding” (Delivery), 2026-10-13:\\nRollback was blocked on approvals",
                    "url": "/boards/1/cards/57?at=comment-1411"}]}]}
    ```

    **Ask.** `POST /api/ask` takes the question as `q` or `question`, an
    optional `board` (id, code or name) to keep the assistant to one board,
    and an optional `history` (`[{"role": "user"|"assistant", "content":
    "…"}]`) to carry a conversation on. It answers **synchronously**, in the
    same response, after the model has finished — allow it a minute.
    `GET /api/ask?q=…` is the same call, not a poll. The prose is in
    `answer` (Markdown), the cards and pages it read in `sources`, and the
    searches it ran in `searches`. A token confined to some boards is a
    `403`; a model failure is a `400` with the reason.

    ```sh
    curl -s -H "$H" -H 'content-type: application/json' B/api/ask \\
         -d '{"q": "What is happening with refunds?", "board": "delivery"}'
    ```

    ```json
    {"question": "What is happening with refunds?",
     "answer": "Finance are waiting on the refund rounding card (#57).",
     "searches": ["refund rounding"],
     "sources": [{"kind": "card", "id": 57, "title": "Refund rounding", "board": "Delivery",
                  "found_by": "refund rounding", "url": "/boards/1/cards/57"}]}
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

  # Deploys and DORA metrics (#1134). The setup prompt is the wizard's own,
  # so an agent with the tools can wire a repository up itself.
  defp deployments(base) do
    {:ok, defaults} = Slipdock.Deployments.Setup.normalise(%{})

    """

    ## Deployments

    A board can record its project's deploys and report how it delivers — the
    DORA numbers: deployment frequency, lead time for changes, change failure
    rate, time to restore and rework rate, and idea to production (a card first
    in progress → the first deploy whose commits name it). Off on every board
    until its owner turns **Delivery metrics** on (settings, PATCH
    `delivery_metrics`, `slipdock set-board B --delivery-metrics`); while off,
    deploys are refused and the report says so.

    Deploys are a ledger, not cards. CI records them with the board's **deploy
    token** (`sdd_…`, which records deploys and can do nothing else), usually by
    wrapping the deploy command: `slipdock deploy run --env production --
    ./deploy.sh`. The token goes to `GET /api/deployments/last?environment=E`,
    `POST /api/deployments` (with an optional `note`, a line up to 500
    characters such as how the suite passed: `slipdock deploy run --note`) and
    `PATCH /api/deployments/:id` only. Commits name
    cards as `#123` (or the board's `card_ref_pattern`); a card a succeeded
    deploy names gets a **Shipped to production** line (`shipped` on
    `get_card`, each with its `text`: *Shipped to production · 1a2b3c4 · 6
    Nov 14:32*, the time in your time zone) and the step status *Shipped
    to production*.

    Incidents are ordinary cards tagged `incident` (the board's `incident_tag`),
    optionally linked to the deploy that caused them: `POST
    /api/cards/:id/incident-of {"deployment": N}`, `slipdock incident-of`. A
    deploy is a failed change when it failed, was rolled back, has an incident
    linked, or was followed within the hotfix window (24h) by a deploy naming an
    incident card.

    Read the numbers with `get_board` `dora: true` (`environment`, `days`),
    `GET /api/boards/:board/dora` or `slipdock dora B`. Set a board up with
    `POST /api/boards/:board/deployments/setup {"ci": "github"}` (owner; turns
    the switch on and returns a new token once, with the step to paste) or
    `slipdock deploy setup B`. To wire a repository up yourself, this is the
    brief:

    #{Slipdock.Deployments.Setup.prompt(defaults, %{base_url: base})}
    """
  end

  defp health_monitor do
    """
    ## Health monitor

    Every few minutes the server looks each board tree with runners or rules
    over for work stuck in ways only a person would otherwise notice (W-2310):
    jobs nobody takes, deadlocks, verification and merges that stall, cards and
    waits nobody is moving. Each finding is an **incident**. Where a safe fix
    exists it is tried (a few times at most, each attempt a comment on the
    card); otherwise, or once the fixes run out, it is **flagged**: the card
    gets the `stuck` flag and a comment saying what was found and tried, or the
    board gets an alert when no card is involved. Fixes touch only jobs, the
    queue, flags and comments; nothing is deleted, merged or closed.

    - **A card flagged `stuck`** needs a person. Don't work around it or take
      the flag off yourself: say on the card what you know, and leave it.
      Taking the flag off marks the incident handled, and the same state is
      not flagged again.
    - **Hearing about it:** the `health_flagged` trigger (`detector` narrows
      it), or the preset *The health monitor needs a person*, with an email.
    - **Reading it:** `GET /api/boards/:board/health` (open and flagged
      incidents, recent ones, the last run, each detector's settings);
      `POST` the same path runs it now (write access); `PATCH
      /api/boards/:board/health/settings {detector, enabled?, max_attempts?, …}`.
      The CLI's `slipdock health <board>`; the board's Health page, linked from
      Runners.

    **Right now** (#2103): `GET /api/boards/:board/now` (or MCP `get_board`
    `now: true`) says what is happening on the board's tree at this moment:
    each runner (`online`, `session`) and the jobs it holds with their latest
    `step`; every card in progress with its `board`, `list`, `parent` epic,
    state line, `loop` and what `holds` it (`waiting`, `verifying`, `merging`,
    `blocked`, `review`, `stuck` for the health monitor's flag, `over_usual`
    for a card merely past its list's usual stay); the jobs `queued` and why
    each is `held`;
    and the `counts`. Read access to the board and its tree's root. The
    board's Right now page (`/boards/:id/now`) shows the same, and so does
    `slipdock now <board>` (`--json` for this JSON).

    **The overseer** (#2068) watches outcomes rather than plumbing, once its
    root board's owner turns it on. Every minute it checks the tree for work
    going round (`looping`: a second rejection, or a third runner pass of
    one card), a person as the only bottleneck (`waiting_idle`: a wait or
    review open and no job open), `slow` cards (past the board's P85 time
    to done for their profile) and jobs (a live heartbeat, the same step
    for 30 minutes), `idle_capacity` (free ready cards and runners idle for
    `idle_minutes`, or two or more jobs queued behind one card's lane) and
    `no_way_forward` (an epic in progress with every open subcard blocked).
    Each condition fires once, as a warning alert on the root board and an
    email to the owner with why and what to do, heads the owner's waiting
    (reason `overseer`, with its `condition`), and clears itself, alert and
    all, when it ends. A runner job of kind `overseer` goes, at most one at
    a time, only to a runner whose claims list `overseer` in
    `X-Runner-Kinds`; its prompt carries the conditions, the pulse and the
    activity counts and nothing else, and its answer, one line of JSON
    `{"health", "digest", "look_now"}`, is kept as a status update on the
    root board's *Overseer* card. Passes come every `min_minutes` (10)
    while anything is in flight, 30 when only ready lists have cards, and
    `max_minutes` (120) when nothing does; a rejection, a wait or a job
    ending brings the next forward. `GET /api/boards/:board/overseer`
    (read access on the board and on its tree's root, whose overseer a
    sub-board answers with: a 403 otherwise) gives its settings, `conditions`, `cleared_last_day`,
    `last_digest` and `next_run_at`; `PATCH` the same path `{enabled?,
    pool?, min_minutes?, max_minutes?, idle_minutes?, email?}` (the owner;
    bounds 5 to 1440 minutes, min no more than max). MCP: `get_board`
    `overseer: true`, `update_board` `overseer: {…}`. CLI: `slipdock
    overseer <board> [--on|--off] [--min-minutes N] [--max-minutes N]`.
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
      card has at most one open job from any rule (jobs no rule queued, such
      as verify, merge and overseer, aside), answering a wait sends the card
      as one job rather than one per rule, and a `list_top` rule passes
      over a card any job is open on, so two of them (one per pool) can work
      one list side by side. It passes over a card its lane would hold too,
      and withdraws a queued job of its own that a lane holds when another
      card could start, so a held card never keeps its pool idle.
    - **The claim moves the card.** When a runner claims a `list_top`
      rule's job, the server moves the card to the top of its board's doing
      list (the one this guide names), assigns nobody and says so in the
      card's activity; moving it there yourself afterwards changes nothing.
      A card without a bar on a board that asks for one, or on a board with
      no doing list, stays put and the activity says why. The claimed job's
      prompt names the list the card is in and the doing list's own name:
      use that name if you move the card by hand.

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
    comment; `step` (what you're doing now, ≤ 300 characters) is kept on the
    job only, as its `step` and `step_at`, and shows on the Runners panel and
    in `slipdock job`/`jobs`. Every step is also kept on the job with its time
    (the job JSON's `steps`, the newest 200), which the card's chat reads as
    the job's milestones (and its lead time by phase: a step that mentions CI
    starting, going green or red marks a CI run), so report each one as it happens. The agent a runner started for a job may report
    on it too, sending the job's id as `x-slipdock-job` (the CLI does, from
    `$SLIPDOCK_JOB_ID`). Finishing the job does not close the card, so close it as usual.
    The session shows in the board's runner list as `<token label> (session)`.

    **Parking on a question.** A job whose agent needs something only a
    person can give asks it as a wait (`update_card` `wait`, `POST
    /api/cards/:id/wait`, `slipdock wait <card> … --job <id>`) and stops:
    the job ends `parked` whatever it reports. The card is the job's own or
    one beneath it: an epic's job asks about a subcard on the subcard, and
    the answer sends the epic again, naming the subcard. `finish` with `{"outcome":
    "waiting", "wait": {"needs": "…", "choices": […]}}` asks and parks in one
    step, both or neither. A list_top rule puts the parked card back on top
    of its list, flagged waiting, without spending a `requeue_stuck` retry, so
    the next card goes. Answering sends the card to the same rule again — at
    once, or once the rule's job that a runner has taken has closed — with
    the question, the answer, who answered and the handoff on top of the
    prompt. A job the rule queued for another card that nobody has taken yet
    gives way: it is withdrawn (`cancelled`, `recovery: "withdrawn"`, with a
    comment on its card), and its card keeps its place and goes next. The claim
    answer carries them as `wait` and `handoff` too (a runner's: `X-Wait-Id`,
    `X-Handoff-Id`). The wait's `requeue_state` says what happened:
    `queued`, `pending`, `skipped` (the rule is off or gone, the card closed
    or moved tree) or `failed` (the queue refused), with a comment on the card.

    **Seeing and stopping jobs** needs read access to the card, and
    cancelling one write: `GET /api/cards/:id/jobs`, `GET
    /api/boards/:board/jobs?status=open`, `GET /api/jobs/:id`, `GET
    /api/jobs/:id/transcript` (its live log, below), `POST
    /api/jobs/:id/cancel`. A queued job is cancelled at once; a running one
    is asked to stop, and its runner hears so on its next heartbeat.

    **Pausing.** The board's owner can hold its tree's runner work, or one
    pool's, with a reason: `POST /api/boards/:board/pause` with `reason`
    (required) and `pool` (none: the whole tree), MCP `manage_automation`
    `pause`, `slipdock pause <board> [--pool P] --reason "…"`. It is kept on
    the root, so it holds every board in the tree. While paused no job is
    claimed and no list_top rule sends a card; jobs still queue, and running
    ones finish. `get_board`, `list_cards` and `GET` of the board and its
    cards carry `paused` while it lasts: an agent seeing it stops. Resuming
    (`DELETE /api/boards/:board/pause[?pool=P]`, `slipdock resume`) is a
    person's, in the app or the CLI outside an agent; over MCP or with the
    agent header it is refused. It lets off exactly that scope and wakes
    every waiting runner and rule at once.

    **Held work says why.** An empty claim answers with `held` (the
    runner protocol: an `X-Held` header), and a queued job's `waiting_on`
    says the same, one reason in this order: `paused by David: bad deploy`,
    `WIP full: In Progress 3/3`, `#123 is in progress`, `No runner online
    for pool dev` (none seen in three leases; never told to a runner that
    is asking). `#123 is in progress` (and a lane's `Lane: overlaps #12, in
    progress`) only ever names a card a runner job is working on: one with
    a job queued, claimed or running on it or its epic. A card in progress
    with no open job holds nothing back. WIP full applies when the owner turns on `automation_wip`
    (the Agentic Building page, `PATCH /api/boards/:board`, `slipdock set-board
    --automation-wip`): while the first in-progress list is at its WIP
    limit, jobs and list_top sends for cards not already in progress wait.
    People can still drag cards in.

    **Connecting one** is easiest with the wizard, which the board's
    Automations panel shows as *Connect a runner*: `POST
    /api/boards/:board/runners/setup` with `scenario` (`daemon`, `loop`,
    `cloud`, `chatgpt`), which is `daemon` when not given, and `pool`,
    `cwd`, `permission_mode`, `where` and `repo`, and `column` to add a rule sending that list's cards. It
    answers with `setup.steps` — exactly what to paste — and, for `daemon`,
    a one-time `enrolment_key`; `runner` and `token` are null. `server` and
    `windows`, the shell and PowerShell runners, were retired (#2582) and
    answer 422 saying to use `daemon`; every path under `/runner/`, where
    they were served, answers 410 Gone. `GET …/runners/:id` is one runner
    in full (`created_by`, a session's `api_token`, `current_job`,
    `job_counts`, `recent_jobs` up to `limit`, and the `rules` sending to
    its pool; `machine_id` for a machine's runner). For a runner with a
    token of its own (a retired shell runner's), `GET …/runners/:id/setup`
    gives the steps to move it onto a machine and `POST …/runners/:id/token`
    a new token; `PUT …/runners/:id/setup` and `GET …/runners/:id/hook-prompt`
    answer 410. A machine's runners are set with `/api/machines/:id/runners`.
    Standing `instructions` (and a `verbosity`) and `before_job`/`after_job`
    hooks are answers too: they are written into the generated prompt,
    never sent with a job.
    Every job's prompt ends by telling the agent nobody will answer questions.
    `slipdock runner new` prints the same. What a job does to its card and
    repository is seven booleans, all false unless given, in every scenario:
    `in_progress`, `assign`, `commit` (only in a git repository), `push`
    (refused without `commit`; `commit` is refused for `chatgpt`, which has no
    repository), `move_done`, `complete` and `percent_100`.
    Each is said in the prompt, on or off. `verbosity` is `nothing` (the default: no comments, `job_progress`
    with no note), `quiet`, `normal`, `verbose`, or `""` for whatever the
    skill says. Answers saved as #511's `commit` and `close` carry over. A
    session with no job tools (a connector added before they existed keeps its
    old tool list) is told to stop and say so rather than work the lists.

    **Runners themselves** are the board owner's to make and revoke: `GET`,
    `POST` (`{"name", "pool"}`, answering with the runner's token, once, for
    a client of the protocol you write yourself) and `DELETE
    /api/boards/:board/runners[/:id]`. A runner's token (`sdr_…`), or a
    machine's key (`sdm_…`) naming its runner in `X-Runner-Id`, works only
    on the runner protocol, which is plain text so a machine with nothing
    but `sh` and `curl` can speak it:

    ```
    POST /api/runner/claim?wait=25             204, or 200 with X-Job-Id, X-Job-Kind, X-Card-Id,
                                               X-Card-Ref, X-Card-Url, X-Lease-Seconds; prompt as body
    POST /api/runner/jobs/:id/heartbeat        body = log tail  → ok | cancel
    POST /api/runner/jobs/:id/finish?exit=N&status=S   body = last output → ok
    POST /api/runner/jobs/:id/transcript?from=N  body = transcript lines from N → ok L | capped L
    ```

    **A job's live log.** While a job runs, its runner sends the agent's
    Claude Code transcript about once a minute, and once more as the job
    ends: `POST /api/runner/jobs/:id/transcript?from=N`, the body the
    transcript's whole lines from line `N` (0-based). The answer `ok L` is
    the lines the server now holds and where the next send starts, so a
    failed send is simply sent again and one that arrives twice is trimmed;
    a `from` past them answers 409 `from L`. A send is read up to 1 MB (the
    rest comes next time), a line over 32 KiB is kept as
    `{"type":"slipdock_cut","bytes":N,"limit":L}`, and once the log holds
    8 MB a last `{"type":"slipdock_capped",…}` line says so and the answer
    is `capped L`: nothing more is kept. Tokens are taken out before it is
    stored: the runner's, any `sd…_` token, and the usual secret shapes
    (cloud and GitHub keys, private keys, bearer headers, `password=…`).
    Read it back with read access to the card: `GET
    /api/jobs/:id/transcript?from=N` answers JSON Lines from line `N`, with
    `X-Transcript-Lines` (the `from` for the next read) and
    `X-Transcript-Capped`; the job itself says `transcript_lines`,
    `transcript_capped` and `transcript_at`.

    To watch a job, read it as lines: `GET /api/jobs/:id/log?from=N`
    answers `{job: {id, card_id, status, open}, from, next, capped, entries}`, one
    entry per message, tool call or tool result (`kind` `prompt`, `message`,
    `tool`, `result`, `error` or `note`, with `at`, `text`, `detail` (the
    whole of what `text` shortens) and `line`, the entry as one line of
    text). Read again with `from` = `next` until `job.open` is false.
    `slipdock job <id> --follow` does this; over MCP it is `job_log`
    (`job`, `from`), which answers the same with `log`, as text, for `entries`.

    A log is deleted a set time after its job ends, unless kept: the top
    board's `job_log_hours` (24) or, for a failure, `failure_log_hours`
    (168), both set with `PATCH /api/boards/:board`. A failure is a job
    that failed, timed out or was cancelled, or whose card was later
    rejected, flagged `stuck` or put back; its time runs from then. The job
    says `transcript_expires_at` (nil while it runs or once kept),
    `transcript_failure`, `transcript_page_id` and `transcript_deleted_at`.
    `POST /api/jobs/:id/keep` (write access to the card) writes the ended
    job's log as a page `Pass <card> (<date>)` in the card's folder, links
    it from the job and stops it expiring, answering `{job, page}`; again
    gives the same page; 422 while it runs or once the log is gone.
    `slipdock job <id> --keep`; MCP `keep_job_log`.

    A server stopping for a deploy answers every open claim at once with a
    204 and `Retry-After: 1`: wait that many seconds, then claim again, and
    the new server answers. A 502, 503 or 504 on a claim is a deploy too
    (the proxy lost it): claim again a second later. The runner daemon
    does this and logs it only when it goes on.

    The runner daemon (`slipdock-runner`, from Slipdock's signed releases)
    speaks it for every runner of its machine: see *Machines*. One machine
    runs as many runners as are added on its page — one per board, say.

    `slipdock runner ls|new|rm`, `slipdock jobs`, `slipdock job`,
    `slipdock cancel-job`, `slipdock claim-job`, `slipdock job-progress`,
    `slipdock finish-job`, `slipdock pause` and `slipdock resume` are the
    same on a shell.

    `update_board` changes a board you own (its name, description, colour,
    simple mode, default view, handoff label and the Verified work
    switches), as `PATCH /api/boards/:board` and `slipdock set-board` do.
    `agentic_building` (`--agentic-building on|off`) shows or hides the web
    app's Agentic Building page, where a person sets these switches; it
    changes none of them, and turning it off with any still set answers
    with `warnings` naming them.
    On a board that verifies work, `verify_card` (`slipdock verify`) is how a
    second agent accepts or rejects a card another one submitted: see
    *Verified work*, which appears when one of your boards has it on. With
    `verify_pool` set, each submitted card is queued for that pool as a job
    of kind `verify`, which a machine's runner takes with its own agent.
    `merge` jobs (merging an accepted card's pull request) are built into
    the runner daemon, and go only to runners whose claims list `merge`
    in `X-Runner-Kinds`; the runners list's `missing_kinds` says what the
    board needs that a runner lacks. Claims also say what the machine has installed (`X-Runner-Skills`, each
    slipdock skill's `SKILL.md` SHA-256; `X-Runner-CLI`, the CLI's), and
    each runner's `drift` compares them with what this server serves:
    `skills` current, drifted (`drifted_skills` names them) or unknown,
    `cli` current, old, none or unknown. A drifted runner raises one
    alert, cleared once it is current. A daemon clears it itself: before
    each agent job it puts the server's skills in place (under the `user`
    executor the job account unpacks them; `no_skills_update` turns it
    off) and, when `/cli/SHA256SUMS` differs from its CLI, fetches
    `/cli/slipdock.escript`, checks its SHA-256 and its signature
    (`/cli/slipdock.escript.sig`, which the release job makes for each
    `v*` tag) against the release key built into it, and puts it in its own
    `bin`, first on the job's PATH; a CLI with no signature that verifies
    is kept out unless `local.json` sets `cli_checksum_only`
    (`no_cli_update` in `local.json` turns that off), so its next claim
    reports it current. For skills it doesn't update and
    a CLI it doesn't write, run the install one-liner on the machine again,
    as the account the jobs run as. A skill's one source is the server,
    never a hand-edited copy.

    **The server keeps an epic's record.** As each subcard starts, is
    submitted, rejected, accepted, merged, fails a build, waits on a person
    or ships, the server posts a line on the epic with its done count (lines
    within seconds share a comment), and the epic's % complete follows its
    subcards unless a person set it by hand. Don't repeat those: comment on
    the epic what only you know, your decisions, surprises, dead ends and
    changes of plan.

    **Machines** (#2570). A machine
    running `slipdock-runner` enrols once and gets a **machine key**
    (`sdm_…`), bound to the account that approved it. By device code:
    `POST /api/machines/enrol` with `hostname`, `os`, `arch` and
    `fingerprint` answers a `user_code` and a `device_code`; a person
    approves at `/account/machines/approve`, seeing the hostname, system and
    fingerprint and choosing the boards it may serve (or over the API:
    `GET /api/machines/enrolment?user_code=…` shows the machine, `POST
    /api/machines/enrolment/approve` with `user_code` and `boards`, or
    `…/refuse`); `POST
    /api/machines/enrol/token` with the `device_code` answers
    `authorization_pending` until then, and the key once after. Or with a
    one-time `enrolment_key` (`POST /api/machines/enrolment-keys` with
    `boards` and an optional `label`, shown once, good for 24 hours) and the
    machine's description on the same token endpoint; the key's `label` is
    the name the machine enrols under (its hostname without one), and `PATCH
    /api/machines/:id` with `name` renames it later, keeping its hostname
    (#2666). The key reaches `GET /api/machine` and is
    no API token: every other route refuses it, and revoking the machine
    (`DELETE /api/machines/:id`, or Account › Machines) refuses it at once.
    `GET /api/machines` lists yours; a token confined to some boards is
    refused them. CLI: `slipdock machines`, `machine
    show|rename|revoke|enrolment|approve|refuse|enrol-key`.
    Not over MCP: enrolling and revoking a machine is the account's owner's
    call, made where they sign in, not an agent's.

    **A machine's runners** (#2571). A runner the daemon runs belongs to its
    machine and is configured as data: `POST /api/machines/:id/runners` with
    `board` (one the machine serves), `pool`, an optional `name` and a
    `config`; `PATCH /api/machines/:id/runners/:runner_id` changes `pool`,
    `name` or any config field; `DELETE …/runners/:runner_id` removes it (the
    daemon finishes its job, then stops it). The config is closed and typed:
    `agent`, `directory`, `permission_mode` (`plan`, `default`, `acceptEdits`,
    `bypassPermissions`), `timeout_minutes`, `model`, `worktree` (`auto`,
    `on`, `off`), `verbosity`, `instructions`, `executor` (`me`, `user`,
    `confined`, `container`), the names of a `before_hook`, `after_hook`
    and `probe_hook`, and under `container` an `image` (required: a name
    only, which the machine runs only if it matches its own allow-list,
    `container_images` in its ceiling) and `network` (`on`, `off`). There is no command field: an unknown key, `command`
    included, is refused, and every name resolves in the machine's own local
    file. The daemon, with its machine key, long-polls `GET
    /api/machine/config?version=N&wait=S` (its runners' configs and the
    machine's `version`, at once when newer than `N`, else when one changes,
    else 204), reports its machine's ceiling with `PUT /api/machine/ceiling`
    (`roots`, `agents`, `max_permission_mode`, `max_timeout_minutes`,
    `boards`, `executors`, from its own local file: the server only shows it)
    and says what it did with each config: `POST
    /api/machine/runners/:runner_id/report` with `version` and `outcome`
    `accepted`, or `rejected` and a `reason` (a stale version answers 409).
    `GET /api/machines/:id` shows the ceiling, the runners with what falls
    outside it, and the log of accepted and rejected changes. The runner
    protocol takes the machine key with `X-Runner-Id`, for that machine's own
    runners only; each runner keeps its own identity, so a verify job still
    goes to a runner other than its builder.

    **The Machines page** (#2572). Each machine has a page at `/machines/:id`,
    opened from Account › Machines: whether it is online, its system, the
    executors and ceiling it reported (read-only), its runners with their
    state and current job, each refusal with its reason and the limit it
    crossed, and the log of accepted and rejected changes. Its owner adds,
    changes, pauses and removes runners there (a field outside the ceiling is
    marked with the limit), asks it to update now and revokes it. Members of
    a board it serves see it, with only their boards' runners, and change
    nothing. Over the API: `GET /api/machines` lists yours and, as `shared`,
    the machines serving a board you're on; `GET /api/machines/:id` shows
    either (`yours` says which); `POST
    /api/machines/:id/runners/:runner_id/pause` and `…/resume` (a paused
    runner is handed no job until resumed, and its config says `paused`);
    `POST /api/machines/:id/update` asks the daemon to look for a newer signed
    release now (its config carries `update_requested_at`). A member's write
    is a 403. CLI: `slipdock machine
    add-runner|set-runner|pause-runner|resume-runner|rm-runner|update`.
    **Set up this machine with Claude** (#2579): `GET
    /api/machines/:id/setup-prompt` (the owner's; `slipdock machine
    setup-prompt <id>`, and the machine's page) answers `prompt`, for Claude
    Code on the machine, run as the account its jobs run as. It names each
    served board's machine-setup page (the handbook's Testing & tooling
    §Local setup), and asks for a check, the installs, a proof (a clean
    clone, set up from the page, its suite run) and the page corrected. The
    daemon fetches the same with its machine key, `GET
    /api/machine/setup-prompt`, and `slipdock-runner init` (or `setup`)
    offers to launch Claude with it. The
    board's **Connect a runner** offers *A machine with the daemon* first: its
    steps make a one-time enrolment key for the board (`scenario` `daemon` on
    `POST /api/boards/:board/runners/setup`, answered as `enrolment_key`,
    refused to a token confined to some boards).

    **The probe** (#2580). A probe checks a machine runner's setup: a job of
    kind `probe` with no card, sent to that one runner and taken ahead of its
    pool's queue (never by another runner of the pool), leased, heartbeated,
    finished and kept like any job. The owner sends one with `POST
    /api/machines/:id/runners/:runner_id/probe` (201; 200 with the one already
    on its way; 422 for a paused runner). `GET` on the same path is the
    runner's latest, or `probe: null`, for the owner and a member of the
    runner's board; `GET /api/machines/:id` gives each runner's as `probe`,
    with `result` `green` (it ended `done`), `red` (any other end) or
    `pending`, its `status`, `finished_at` and `log`. Over the runner
    protocol it comes as `X-Job-Kind: probe` with no `X-Card-*` headers, only
    to a daemon whose claim lists the `probe` kind; its body is the server's
    drift verdict (`skills: current`, `cli: old`). CLI: `slipdock machine
    probe <machine> <runner> [--wait]`. Not over MCP, as the rest of a
    machine's management isn't.

    **The trust contract** (#2581). What a server can and cannot make a
    machine do, what each executor stops, and what nothing here bounds, is one
    text, `daemon/internal/contract/contract.md`. The daemon embeds it, and
    `slipdock-runner show` prints it after the machine's own limits (its
    ceiling, the executors it allows and who a job runs as under each). The
    server reads the same file when it is built and shows it on each machine's
    page and in Help › Agents; the manual's Machines page carries a copy held
    equal to it. It is not over the API on its own, as it is the same for
    every machine: this guide carries it, here.

    #{Slipdock.Machines.TrustContract.markdown()}
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
    curl -s -H "$H" "B/api/boards/1/pages?recent=true" # newest edit first, the newest 100
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
    curl -s -H "$H" "B/api/boards/1/tree?folder=Design"   # one level: rows and counts, no bodies
    curl -s -H "$H" "B/api/boards/1/pages/switch?q=acme+call"   # the quick switcher: fuzzy title, alias, path; &vaults=all: your whole wiki
    # to another board of your wiki, keeping its code; dry_run says what would stay behind
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/move -d '{"board": "projects", "folder": "Acme", "dry_run": true}'
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' \\
         "B/api/boards/1/folders/Design" -d '{"sort": "name"}'   # manual, name, modified, created; board follows the board's (by name unless chosen)
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' \\
         B/api/boards/1/tree -d '{"sort": "modified"}'           # the top of the tree, and the folders following it; write access
    # a whole folder to another board you can write to: subfolders, pages (codes and history kept)
    # and files; "parent" a folder there, "contents": true moves only what is in it, dry_run reports
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' \\
         "B/api/boards/1/folders/Projects" -d '{"to_board": "projects", "dry_run": true}'

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
    # Organise what is filed in a folder: mode date|ai|tag|flatten. date takes
    # parent (a path; the folder itself when absent, "" for the top), granularity
    # (month, year, year_month, day) and source (auto: created:/date: front matter
    # first; added). ai: a cheap model suggests homes under existing top-level
    # folders. dry_run returns the plan; "only": ["page:12"] files just those keys.
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/boards/1/organise -d '{"folder": "Inbox", "mode": "date", "parent": "Meetings", "dry_run": true}'
    # → {"dry_run": true, "plan": [{"key": "page:12", "title": "Standup", "from": "Inbox", "to": "Meetings/2026-10"}]}
    # without dry_run → {"plan": [...], "moved": 1, "folders_made": 1, "skipped": []}
    ```

    **One page, several folders.** `folder_id` is a page's **home**; it can be
    **also filed in** other folders, as a symbolic link would be — one body,
    one history. `POST /api/pages/W-31/folder {"also": "Ideas"}` adds one
    (made if new), `{"not_in": "Ideas"}` takes it away, `board` names another
    board's folder, and a wiki path (`"/Projects/Notes"`) reaches any board of
    the wiki. A path uses the folders that are there and makes only
    the levels that aren't, for a folder's `also` as well, if you write on both
    boards. A page's JSON lists them as `also_in`; a folder's
    listing (`?folder=`, `/folders`) includes them marked `"also": true`, each
    page once. Archiving keeps them; deleting a folder drops its own.

    **One folder, several places.** A folder can be also filed in other
    folders too (#808), and shows there with everything in it; its `parent_id`
    stays its home. `PATCH /api/folders/4 {"also": "Ideas"}` (or
    `/api/boards/1/folders/<path>`) adds one, `{"not_in": "Ideas"}` takes it
    away; the other folder is named by path, by id, on `in_board`, or by wiki
    path. Same rules as pages: same board or wiki, write on both, never its
    home parent, and never inside its own subtree (through placements too) —
    each refusal is a 422 saying why. A folder's JSON lists them as `also_in`;
    `GET /api/boards/1/folders/<path>` reads one; listing a folder adds the
    pages under folders placed there, marked `"also": true`. Sync writes a
    folder once, at home. MCP: `file_folder`.

    **Sharing a page or a folder** (#813) hands it to somebody who need not
    see the board: a person by email (a stranger is invited) or a group of
    yours, `read`, `comment` or `write`. A folder share covers everything whose *home*
    is in its subtree (pages, files, drawings, subfolders), never what is only
    also filed there. Only the board's writers share.

    ```bash
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/grants -d '{"email": "sam@example.com", "level": "write"}'
    # → 201 {"grant": {"id": 9, "level": "write", "user": {"email": "sam@example.com"}, "group": null}}
    curl -s -H "$H" B/api/folders/4/grants            # who has it
    curl -s -X DELETE -H "$H" "B/api/folders/4/grants?group=Ops"   # take it back
    curl -s -H "$H" B/api/shared                      # what is shared with you, by owner
    ```

    What is shared with you reads and edits by its code like any page
    (`GET`/`PATCH /api/pages/W-31`); make things inside a shared folder with
    `POST /api/folders/:id/pages` and `/api/folders/:id/folders`, and read one
    with `GET /api/folders/:id`. **A sharee's limits:** with write they edit,
    rename, make pages, files, drawings and subfolders inside the share, and
    move things within it; new things are the owner's, on the owner's board
    and quota. They never delete, archive or restore, move anything out (to
    the top, another folder, another board), move the shared folder itself,
    organise, re-share or publish, or encrypt; a page shared on its own is
    edited and renamed, not moved. Each refusal is a **403 with a code**:
    `shared_read_only`, `shared_no_delete`, `shared_no_move`,
    `shared_no_move_out`, `shared_no_create`, `shared_no_reshare`,
    `shared_no_encrypt`, `shared_no_organise` — stop, and tell the person; a
    retry won't help. A sharee can also file a shared item in a folder of
    their own (`also`); a wiki sync then gets **stubs** — one line, a link —
    never the content. MCP: `share` (`off: true` to take it back; neither
    `with` nor `group` to list), `list_pages {"shared": true}`.
    CLI: `slipdock page share <page> <email|group> [--write] [--off]`,
    `slipdock folder share <board> <folder> …`, `slipdock shared`.

    **File it, don't nest it.** Making a parent page called "Design" that
    exists only to hold other pages is the mistake folders are for: the page
    is about nothing, and it has to be read to be got past. A folder is a
    place, and a place costs nothing.

    On a shell: `slipdock wiki`, `slipdock folder ls|show|new|mv|rm [--purge]`,
    `slipdock folder file <board> <folder> --also F | --not-in F`, and
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

    ### The wiki: your Knowledge Base and every board, as one tree

    Your wiki is one folder tree of Markdown (and other) files, made the first
    time it is wanted and derived rather than configured. At the top is your
    **Knowledge Base**, first always: a wiki and nothing else (underneath, a
    board of kind `wiki`, on no list of boards and counted against no limit).
    Then every root board you own is a folder at `/<board name>`, in the order
    your home page keeps by hand, and a sub-board sits in its epic's folder,
    `<Board>/Cards/<Epic>/`. Everything in a board's wiki is in its folder.
    Boards shared with you by someone else are not in it. A new or renamed
    board needs no call. Board names that clash, case aside, are numbered,
    the oldest plain. A board with **nothing written** on it or below it (no
    page or file) is left out of the web's tree; the listing and
    `wiki.boards` still have it, with `"empty": true`, so a mirror keeps its
    folders: leave it out of a tree you draw. Its first page brings it in.

    An **archived board is out of the tree**: not in `boards`, the sync
    listing or the feed, which says only that it was archived (a `board`
    change, `"action": "archived"`: drop its folder) and, if it comes back,
    restored (list again). Browse it from the archived boards
    (`GET /api/boards?archived=true`) and its own wiki; restore it to have
    its wiki in the tree again. Its pages still answer `[[links]]`.

    ```sh
    curl -s -H "$H" B/api/wiki     # `wiki`: pages, boards, mirrors, knowledge_base; and every board's folders
    curl -s -H "$H" "B/api/wiki/locate?path=/Projects/Acme/Call.md"
    # → {"board": {"id": 7, "path": "/Projects", ...}, "rest": "Acme/Call.md"}
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' \\
         B/api/wiki -d '{"shortcut": "w"}'
    ```

    `wiki.boards` has each board's `id`, `code`, `name`, `path`, `archived`,
    `empty`, `wiki_tree_icons` and `wiki_sort`; `knowledge_base` is `{id, code, name}`.
    `PATCH` takes `shortcut`, `hotkey` and `recordings_folder`; a wiki has no
    name. `locate` answers with the deepest board holding the path, a
    sub-board being inside its parent's folder, and is a 404 at the root or
    in no board. `mirrors` are the folders the wiki is synced to, as far as
    the server knows: each API token that has listed it (`/sync`) or followed
    its feed, by label, with `last_synced_at`. On a shell: `slipdock wiki
    show|set|locate|resolve|wanted|changes|tree`; over MCP, `wiki_info` and
    `manage_wiki`; in the web app, `/wiki`, where a page's address is its
    path (`/wiki/Projects/Roadmap`): give the person that link rather than a
    board's. `/api/vaults/...` answers as `/api/wiki/...` does, for older
    clients; it will go.

    **Links reach across the wiki.** A plain `[[Note]]` tries its own board,
    then the whole wiki: each page has a path (board, folders, parent pages,
    title), the last part of a link matches a title, slug or alias, any parts
    before it the end of the path, and the shortest path wins a tie — so
    `[[X/Note]]` picks one. `GET /api/wiki/resolve?link=X/Note` answers which
    page and its path; `GET /api/wiki/wanted` lists what is linked to and
    unwritten anywhere in it.

    **The change feed.** `GET /api/wiki/changes` gives the cursor to
    start from; `?since=<cursor>` then gives every page, folder, attachment
    and wiki-file change on the wiki's boards after it — each once, as it is now (a page's
    `code`, `title`, `icon`, `color`, `position`, `inserted_at`, `updated_at`,
    `content_hash`, `folder_id`, `archived` and `path`), or `"action": "deleted"` — with the next `cursor` and
    `more`. A new icon or colour is a change too, and leaves the hashes alone.
    Every page, folder, file and board carries `title`, `short_name` (a card
    folder's, else null), `path` (the listing's, from disk names, null for what
    is archived itself) and `archived` (itself, or a card above
    it); a card's folder has `card_id`. A rename of a card, a short name or a
    board comes as `"action": "moved"` with the old path in `from_path` on
    the folder and on everything that moved under it, with `"subject":
    "board"` for a board's own folder: move what you hold, by id, and don't
    delete anything. Moved more than once since your cursor, `from_path` is
    the first path. It isn't in the file, so a moved file's hash is as it was,
    unless the bytes changed too: a page also filed in a folder that moved
    names it in `also-in`, and comes as `changed`.
    Keep a websocket on `/socket/websocket?token=<token>&vsn=2.0.0`, join
    the wiki's `channel` (from `GET /api/wiki`), and a `change` event with
    the cursor says when to ask. The log keeps a window (90 days by
    default): `"resync": true` means your cursor is older than that — list
    the wiki again, then follow on.

    **Sync: the wiki as a folder of files.** `slipdock sync init DIR`
    binds a local folder and `slipdock sync` (or `--watch`, or `slipdock sync
    service install`) keeps it level with the wiki both ways (`slipdock sync
    from-server` or `to-server` for a pass one way only); the folder
    stays a valid Obsidian vault. `slipdock sync status` says what is waiting
    on each side and which conflict copies are left. An existing Obsidian
    vault comes in once with `slipdock wiki import DIR` (try
    `--dry-run` first: what would be created or skipped, and the links,
    embeds and plugin blocks that won't resolve); notes go up byte for byte,
    nothing already in the wiki is overwritten. Underneath is
    `/api/wiki/sync`:

    ```sh
    curl -s -H "$H" B/api/wiki/sync            # every file: kind, id, path, hash; folders; cursor
    curl -s -H "$H" B/api/wiki/sync/pages/412  # one note's file: path, hash, content
    curl -s -X PUT -H "$H" -H 'content-type: application/json' \\
         B/api/wiki/sync/pages/412 -d '{"path": "Projects/Acme.md", "content": "…", "base": "<hash>"}'
    curl -s -X PUT -H "$H" -H 'content-type: application/json' \\
         B/api/wiki/sync/pages -d '{"path": "Ideas/New.md", "content": "…"}'
    curl -s -X DELETE -H "$H" "B/api/wiki/sync/pages/412?base=<hash>"   # archives
    curl -s -H "$H" B/api/wiki/sync/files/9 -o photo.png                # bytes
    curl -s -H "$H" -F path=Img/photo.png -F file=@photo.png B/api/wiki/sync/files
    ```

    Paths are paths of files: a page is `Title.md`, or `Title/index.md`
    when it has children; a title a file name can't hold has its characters
    substituted, and the true title is kept in front matter. A **hash** is the
    sha256 of the exact bytes sync writes (front matter included, `also-in:
    [Path]` for the other folders a page is filed in), so it moves exactly
    when the file would. Every write sends the `base` hash it was made
    against; a stale one is a 409 with the file as it now stands. Writing a
    file at a new path renames or refiles the page; a directory that is no
    folder yet becomes one. Files that are not notes (images, PDFs,
    `.excalidraw`) are kept at their path as wiki files —
    `POST /sync/files[/:id]` multipart, `PATCH /sync/files/:id {path, base}`
    to move, `DELETE` to archive — and `![[photo.png]]` draws them.
    `DELETE /sync/files/:id?purge=true` deletes one and its bytes for good and
    gives the storage back: the board's owner only (403 otherwise), `base`
    guards it as usual (409), and the feed says `deleted`. A
    recorded meeting is a page like any other: see *Meeting pages* below.

    The listing is enough to draw the wiki's tree. Each page has `icon` and
    `color` (names, or null); each page and file has `writable` and
    `shareable`, for you and this token: whether you can write to its board,
    and whether you may share it, which a file never is. `folders` is the
    directories as strings; `folder_details` maps the same paths to
    `{id, board_id, icon, color, writable, shareable}`. With `?stubs=1`, a
    stub carries none of these, and a directory only a stub needs isn't in
    `folder_details`. `boards` lists the boards you can open, each `{id, name,
    title, short_name, path, archived, position, empty}` (`empty`: nothing
    written on it or below it; draw no row for it): `position` is the order
    the top of the tree takes, the one your home page keeps by hand (boards
    you placed by their place, the rest after them, oldest first), so sort
    the top by it and you agree with the web. `folders` takes in the boards'
    directories, and the `Cards` and epic directories a sub-board needs when
    no folder stands for them; `virtual_folders` lists those last as `{path,
    board_id, title, short_name, card_id, archived}`. Every page, file and
    `folder_details` entry also has `title` (whole, however long), `short_name`
    (a card folder's when it has one, else null; a page has none) and
    `archived`: a card above it put it away (an archived board is not listed), and a path never says so. A
    card's folder has its `card_id`. Show titles or short names as the person
    chose: `tree_names` in `GET /api/me`, `full` or `short`, set with `PUT
    /api/me/display {"tree_names": "short"}` or `slipdock names short`. In
    `GET /api/wiki`, each of `wiki.boards`' `wiki_tree_icons` says whether that board's
    tree shows icons and colours at all; turning that off isn't in the change
    feed.

    It is enough to sort that tree as the web app does, too. Each page and file
    has `inserted_at` and `updated_at`, and a page a `position`; a file's is
    null. `folder_details` adds `position`, `sort`, `inserted_at`, `updated_at`,
    and `also_pages` and `also_folders`, the ids of what is also filed there.
    `GET /api/wiki` adds each board's `wiki_sort`. Within a directory, the sort is the folder's
    `sort`, or if that is null its board's `wiki_sort`, which is `name` until
    someone chooses. A page's own directory (no `folder_details`, an `index.md` above
    the rest) is always `manual`. Then draw, in this order:

    1. **Folders at home there.** By `name`, ignoring case, when the sort is
       `name`; otherwise by `position`, then name, whatever the sort.
    2. **Folders also filed there**, in the order of `also_folders`.
    3. **Pages at home there.** `manual`: `position`, then title, then id.
       `name`: title ignoring case, then id. `modified`: `updated_at`, newest
       first, then id, highest first. `created`: the same on `inserted_at`.
    4. **Pages also filed there**, in the order of `also_pages`. A page's
       `position` is its place at home only, and no sort reorders these.
       A stub isn't in `also_pages`.
    5. **Files**, by name ignoring case, whatever the sort.

    `PATCH /api/folders/:id {"sort"}` sets a folder's and
    `PATCH /api/boards/:board/tree {"sort"}` the top of a board's, with write
    access for both. A folder's change is in the feed; a board's isn't. A
    drag names only the page moved in the feed, though its siblings' positions
    change, so take the listing again after a change to redraw in order.

    **Notes tag themselves.** In your wiki, a page's front
    matter `tags` and its inline `#tags` (nested `#area/sub` too; not in code,
    headings or links; an all-digit `#412` is still a card) are its
    `note_tags`, lower-case and apart from the board's card `tags`.
    `GET /api/boards/:board/pages?note_tag=area` lists the notes tagged
    `area` or anything under it, and `GET /api/boards/:board/pages/tags`
    counts them. On a board shared with you, `note_tags` is always empty.

    **A page's board tags.** A page's `tags` are the board's own, the ones
    its cards wear: `PATCH /api/pages/:id` takes `add_tags`, `remove_tags` and
    `tags` (which replaces the set; `[]` clears it), by name, as a card does,
    and so does `update_page` (`slipdock page edit W-31 --tag T`). They live
    on the root board: `GET /api/boards/:board/tags` lists them, and one that
    isn't there is a 422 naming it, with nothing changed. `note_tags` are the
    note's own, edited in its text, and these keys never touch them.

    ### Meeting pages (recordings on Google Drive)

    A recorded meeting is **one page**: the summary, a `## Recording`
    section, and the whole WebVTT transcript in a ```vtt block under
    `## Transcript`. The audio stays on the wiki owner's Google Drive and
    is never stored here; the page names it in front matter:

    ````markdown
    ---
    title: weekly-sync
    date: 2026-09-16T12:08:42+01:00
    type: meeting
    recording: gdrive:Meeting Recordings/2026-09/2026-09-16 12.08.42 weekly-sync.m4a
    recording_drive_id: 1AbCdEf…      # optional; add it once the upload lands
    recording_duration: 3725.4        # optional, seconds
    participants: [Me, Alice]
    ---

    Summary…

    Tags: #important (0:05) #action (12:40)

    ## Recording

    [▶ Play recording and transcript](#recording)

    ## Transcript

    ```vtt
    WEBVTT

    1
    00:00:01.500 --> 00:00:03.250
    <v Alice>Shall we start?
    ```
    ````

    `recording` is `gdrive:` plus the path from the root of My Drive. A
    ```vtt block always reads as the conversation (speakers, times); with
    `recording:` the page also gets a player that streams the audio from
    `GET /wiki-pages/:id/recording` and keeps the transcript in step
    (clicking a line seeks to it). A `Tags:` line of `#tag (m:ss)` entries
    (`h:mm:ss` from an hour) marks moments tagged while recording: each is
    drawn inline in the transcript where it was pressed and becomes a link
    to it in that line, and clicking either plays from that moment. If the transcript itself contains a line
    starting with ```, fence the block with four backticks. Old notes with
    `custom://play` links are left as they are. The whole contract, for
    whatever records and transcribes the meeting (cue timings, speakers,
    audio types, getting the page in, why it won't play), is in the manual:
    docs/manual.md, *Meeting transcripts: what Slipdock expects*.

    It plays when the wiki's owner has connected Google Drive (Account →
    Settings; read-only) and set the wiki's recordings folder, and only for
    files under that folder: `PATCH /api/wiki {"recordings_folder":
    "Meeting Recordings"}` (checked against Drive; `""` clears it), or
    `slipdock wiki set --recordings-folder PATH`. `GET /api/me/drive`
    (`slipdock drive status`) says whether you are connected and your wiki's
    folder. Write the page like any other note, with
    `PUT /api/wiki/sync/pages {"path", "content"}`; add
    `recording_drive_id` later with the `base` hash you got back, and on a
    409 change only that key in the content you are sent back.

    A client with a token plays it from `GET /api/pages/:id/recording`
    (`:id` is an id, a code or `board-code/slug`, with the `/` as `%2F`):
    the audio itself, for a media player or a proxy, never through a model,
    so there is no MCP tool. `Range` is passed on, and the answer is 200 or
    206 with `Content-Range`. It takes read on the board, as in the browser,
    so a page shared alone answers 404; a read-only token may play, and one
    limited to other boards gets a 403. A strict `Accept: audio/mp4` is a
    406, so send `*/*` or leave it out. A refusal is JSON with a `reason`:
    409 `not_connected` / `revoked` / `no_folder` / `no_vault`, 403
    `outside_folder` / `not_audio`, 404 `not_found` / `no_recording`, 502
    `unavailable`.

    A quick note: `POST /api/notes {"text"}`, `slipdock note` or the MCP tool
    `quick_note` saves text to the person's wiki; the server names it, picks
    the folder (the top of their Knowledge Base when nothing fits better), and
    answers with `code`, `title` and `location`.

    The AI tools beside a page: `POST /api/pages/:id/ai {"tool"}`, `slipdock page
    ai <page> <tool>` or the MCP tool `page_tool` run `summarise`, `key_points`,
    `actions`, `titles` or `improve` over the saved page on the caller's AI key,
    and write nothing. `answer.text` is Markdown, `answer.items` the lines of a
    list; `POST /api/pages/:id/cards` makes a card of an action.

    ### Drawings (Excalidraw)

    Obsidian's Excalidraw plugin keeps a drawing as a `.excalidraw.md` page
    (front matter `excalidraw-plugin: parsed`, its text listed under
    `## Text Elements`, the scene in a ```json or ```compressed-json block
    under `## Drawing`) or as a `.excalidraw` wiki file of JSON. Both sync and
    import as they are. In the web app `![[Plan.excalidraw]]` (or
    `.excalidraw.md`) is drawn as a preview, served as SVG from
    `/wiki-drawings/page/:id` or `/wiki-drawings/file/:id` to readers of the
    board. People edit drawings in the Excalidraw editor at
    `/drawings/page/:id` or `/drawings/file/:id`, which saves by itself (a
    couple of seconds after they stop) in the format the drawing came in.
    A drawing may be **live**: several people drawing in it at once, their
    changes merged element by element the way Excalidraw's own collaboration
    merges them (each element's `version`, then `versionNonce`; a deleted
    element is kept with `isDeleted: true`). A write you make while it is
    open — `PATCH /api/pages/:id`, `write_page`, a wiki sync, a `.excalidraw`
    file replaced — lands as usual and is then merged into what they are
    drawing: an element you changed wins only if you bumped its `version`
    past theirs, an element you added stays, and an element you simply left
    out is not deleted (set `isDeleted: true` and bump `version` to delete
    one). Their next autosave holds both sides, and your write stays in the
    page's history. Edit a drawing page's body through the API only if you
    mean to rewrite the plugin's Markdown; the scene is lz-string
    compressed, and a body that no longer holds one shows as Markdown —
    though if the drawing is open, the next change anybody makes there
    saves the drawing back over it. To
    read a drawing, `GET /api/pages/:id/render` gives its words (prose above
    the drawing, then each text element) rather than the scene, and search
    finds a drawing page by those same words.

    ### Encrypted notes (Meld Encrypt)

    A passage can be encrypted in Meld Encrypt's format, the Obsidian plugin's,
    so Obsidian with Meld opens it too. The server only ever holds ciphertext:
    an inline block `🔐β 💡hint💡<base64> 🔐` (or between `%%`, to hide it in
    Obsidian's reading view), or a whole `.mdenc` note kept as a file. It is
    never decrypted here, never indexed for search, and goes through sync and
    import byte for byte. A page holding one says `encrypted` in the tree. The
    format is written up on the wiki of the board that built it.

    Don't decrypt or encrypt by hand through the API: you would be sending the
    plaintext. Do it on your own machine with the CLI, which asks for the
    passphrase (or reads `--passphrase-file`, or `$SLIPDOCK_MELD_PASSPHRASE`):

    ```sh
    slipdock page encrypt W-31 --section Keys --hint "the usual"   # or the whole page
    slipdock page decrypt W-31 --section Keys                       # print it, here only
    slipdock page decrypt W-31 --in-place                           # remove the encryption
    ```

    Text that was on the page before it was encrypted is still in the page's
    earlier revisions. `page encrypt` counts them. With `--purge-history`, the
    board's owner deletes them: the client matches the text against
    `GET /api/pages/W-31/revisions?bodies=all` and sends only the ids, to
    `POST /api/pages/W-31/revisions/purge {"ids": [..]}`. It never touches the
    newest revision, and it is logged. This is the one write that removes
    history, so it is owner-only.

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

    A replace whose body has no heading of the section's level keeps the old
    heading; one that has it renames the section. Rows appended to a section
    ending in a table extend the table. The answer's `note` says which
    (`heading kept`, `heading replaced`, `table extended`, `list extended`,
    `appended`).

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
    [[Retry policy#Backoff]]          a heading of a page; #^a1b2 a block (` ^a1b2` ends it)
    [[#Backoff]]                      a heading on this same page (digits stay a card)
    ![[Retry policy]]  ![[…#Backoff]] the page, or that section, drawn in place
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
    # An image for the page: put the `markdown` that comes back in the body.
    curl -s -H "$H" -F file=@diagram.png B/api/pages/W-31/attachments
    curl -s -H "$H" B/api/pages/W-31/attachments
    curl -s -X DELETE -H "$H" B/api/pages/W-31/attachments/5
    curl -s -X POST -H "$H" -H 'content-type: application/json' \\
         B/api/pages/W-31/vote -d '{"count": 2}'
    curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/pages/W-31 \\
         -d '{"fields": {"effort": 3}}'
    ```

    A board can turn the lot off for its whole wiki: `PATCH /api/boards/:board
    {"page_card_features": false}` (`slipdock set-board B
    --no-page-card-features`), and a board's JSON carries
    `page_card_features`. The web app then leaves status, checklist, links,
    fields, votes and comments off every page of that wiki; tags stay on. Nothing is
    deleted and the endpoints above still answer, so read the flag before
    commenting on such a page: the people reading it will not see the comment.

    **Default view.** A board's JSON carries `default_view`: what opening it
    in the web app lands on — `board`, `swimlanes`, `table`, `timeline`,
    `calendar`, `outline`, `narrative`, `prioritise` or `wiki` — from the
    board list, the switcher and favourites (a favourite board's `url` points
    there). Set it with `PATCH /api/boards/:board {"default_view": "wiki"}`
    (`slipdock set-board B --default-view wiki`); `"board"` or `""` clears it,
    anything else is a 422. A board whose default is `wiki` is mostly read as
    its wiki, so link people to its pages rather than its lists.

    Checklist items and comments are removed through the routes they share
    with cards — `POST /api/checklist/:id/toggle`, `POST /api/checklist/:id/move`,
    `DELETE /api/checklist/:id`,
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
    plus anything passed in `values`, and Obsidian's `{{title}}`, `{{date}}`,
    `{{time}}`, `{{date:YYYY-MM-DD}}` and `{{time:HH:mm}}` (Moment formats,
    UTC), so an Obsidian template works unchanged.

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

    **Front matter is kept exactly.** A page imported from a file keeps that
    file's front matter as written — key order, quoting, comments — and a
    page's JSON carries it as `front_matter`, the YAML between the `---`
    lines (null when there is none). Send `front_matter` on create or
    `PATCH /api/pages/:id` to replace it (`""` clears it; a line of `---` or
    `...` is refused). Export patches only Slipdock's own keys into it.
    Its `aliases` (a list, or Obsidian's older `alias`) become the page's
    `aliases`: `[[Alias]]` and `/api/pages/resolve?title=Alias` find the page
    as its title would, a real title winning over an alias.

    **Publishing freezes the answers.** A published page's live queries show
    what they said when it was published, and its references are plain text:
    there is nobody behind an anonymous request to have permissions, so a
    live query there would be a way to read private cards from the open web.
    The images it embeds (`![[photo.png]]`) are the exception: they are
    shown, served through the page's link while it is published. Publishing
    again refreshes them. A draft cannot be published.

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

  # The handbook (#1261, W-1934): what a pass reads before building and
  # updates before closing, on boards that keep one.
  # The section pages' titles, from the Tool itself (#2045).
  defp handbook_titles, do: Enum.map_join(Slipdock.Handbook.sections(), ", ", & &1.title)

  defp handbook do
    """

    ## The handbook

    A board can keep a **handbook**: wiki pages in its root board's
    `Handbook/` folder describing the project as it is now (#{handbook_titles()}), one page per decision in
    `Handbook/Decisions`, and an Index that lists them. Each page's front
    matter says when to read it (`read_when:`) and which paths it covers
    (`covers:`).

    **Principles and Playbook** (Handbook Tool 1.5.0) say how the project
    decides and plans. Principles are the tie-breakers between two right
    ways: a short paragraph each and a `PRIN-n should · judgement` rule in
    its `## Rules`, which covers every path, so a verifier weighs them like
    any other rule. The Playbook is how an idea becomes cards (when it
    applies, sizing, the stages, card shape, the person's defaults), read
    only by an agent asked to plan, never when a card is made. A board
    makes both its own by editing them. Installing 1.5.0 over an older
    handbook adds the two pages and changes no other.

    ```sh
    slipdock tools install-board handbook --board <board>   # or install_tool {tool: "handbook", board}
    slipdock handbook <board>       # the index and the decisions (GET /api/boards/:board/handbook)
    slipdock handbook <card>        # what that card should read
    ```

    On a handbook board, `get_card` and `GET /api/cards/:id` carry a
    `handbook` key: `index` (code, title, summary, `read_when` of each page)
    and `suggested`, up to five `{page, title, section, why}` to read before
    building: `slipdock page section <page> "<section>"`, or the whole page
    when `section` is null. A subcard gets its root board's handbook.

    **Rules.** Each section page keeps its rules in a `## Rules` section,
    one list item each, parts separated by ` · `:

    ```
    - **UX-4** must · test/app_web/design_tokens_test.exs · No colour literals in templates.
    - **DATA-2** should · scope priv/repo/migrations/** · judgement · Never edit a migration that has run.
    ```

    The id is the page's prefix
    (`SPEC ARCH UX COMP DATA MOD TEST OPS PRIN PLAY`) and a number, never
    reused; `must` means a verifier rejects work that
    breaks it, `should` that it is noted. The optional `scope` globs
    narrow it (default: the page's `covers:`, or everywhere when that is
    empty). The check is the test that enforces it, or `judgement`. Cite a
    rule by its id; tidying a page, keep its rules as they are.
    `slipdock handbook <board>` (its `rules`) counts them and lists any
    item that doesn't parse, with its page and line.

    **The rules for some paths:** `slipdock handbook <board> --paths a,b`
    (REST `GET /api/boards/:board/handbook?paths=a,b`) gives every rule
    whose scope covers them, `must` first, and the pages whose `covers:`
    take them in (`pages`, with how many each); for a whole change,
    `git diff --name-only main | slipdock handbook <board> --paths-from -`. A card with lane `paths` carries
    them in its `handbook` block as `rules` (`rules_more` counts any cut).
    Read them before building and check the diff against them before
    submitting: a verifier uses the same list. A rule is a person's call:
    one a card adds, rewords or drops goes in as a proposal (`slipdock
    garden propose`), not an edit, and an agent's edit to a rule is flagged
    for a person to keep or revert (`rule_changed`).

    **Before closing, the docs gate.** Check the diff against the handbook:

    | The card… | Updates… |
    |---|---|
    | added user-visible behaviour | Specification |
    | changed structure or boundaries | Architecture / Data model |
    | chose between alternatives | a new page in `Handbook/Decisions` |
    | added something reusable | Shared modules / Components |
    | added or changed a UI pattern | UX & UI |
    | changed how to test, build or deploy | Testing & tooling / Operations |

    Edit by section with `--message "#<card> …"`, and put one line in the
    closing comment: `Handbook: updated W-3 §Contexts, new W-41`, or
    `Handbook: no change (<why>)`. A card that names a page ("Document in:
    Architecture") must update it. The gardener flags done cards without
    the line.
    """
  end

  # Code sweeps (#1793, W-2310 §Sweeps and static checks), under the
  # handbook: a section of its own would lengthen the short guide's index.
  defp sweeps do
    """

    ### Code sweeps

    The built-in **Sweep Tool** reads the code one area and one lens a
    night, on a rotation (authorization, duplication, dead code, test
    gaps, old code that breaks a newer rule, secrets and personal details).
    It goes on a board's root:

    ```sh
    slipdock tools install-board sweep --board <board>   # or install_tool {tool: "sweep", board}
    ```

    It adds a `Sweeps` page (the rotation table: areas from the handbook's
    `covers:`, against the lenses, each cell the commit last swept), a
    **Triage** list and a daily *Sweep the code* card whose description is
    the procedure. Installing again adds only what is missing. The card's
    bar names no cell ("Swept the stalest cell of W-…'s Rotation table…"),
    and each new instance starts from that template, not the last run's
    bar: work to the stalest cell on the day, not one a bar names.

    **Never take work from a Triage list.** Its category is `triage`, and
    the boards below mark it `triage: for a person`: it is never the ready
    list or the backlog, a `list_top` feed sends nothing from it, and a
    rule's runner action skips a card that arrives there. What a sweep
    files waits there for a person, who moves what is worth doing into the
    ready list. A sweep files one card per issue (where, why it matters,
    the fix); a security issue gets the `security` tag and stays vague
    anywhere public.
    """
  end

  defp findings_section do
    """

    ## Findings

    What a pass learned that the code and tests don't show, kept on the board
    for every later pass (W-2310). Settled knowledge goes straight into the
    handbook; a **finding** is for the rest: what is uncertain, cuts across
    cards, or shows the handbook was wrong. Write them as a block in the
    closing comment, once, beside the `Handbook:` line (on a board that
    verifies work, the completion's evidence is that comment): never again
    in a wrap-up, a restatement or on the epic.

    ```
    - Handbook: no change (a test-only fix)
    - Findings:
      - gotcha: `mix format` can need two passes
      - rule: every new tool gets a docs test
      - handbook-wrong: W-1950 §Tests says …, but …
      - tooling: …
      - tooling (runner): the installed CLI lacks --paths-from
      - process: …
    ```

    `tooling (runner)` marks an item about the machine the pass ran on (its
    installed CLI or skills), not the project: it is kept with the runner,
    out of the board's default list (`scope=runner` shows them).

    An item already dealt with says where, and is recorded `promoted` with
    that place as its `note`, not left open for triage: `[done: <where>]`
    after its kind when it is settled in the handbook (`- gotcha [done:
    W-1950 §Local setup]: …`), or `→ #<card>` (or `-> #<card>`) at its end
    when a card was filed for it (`- tooling: no test pins it → #2087`).

    A fix is a card, not a finding: a concrete change you could hand to
    someone (a missing test such as "no test pins `slipdock done`'s exit
    codes", a stale moduledoc or doc entry, a tooling bug such as "`page
    section --append -` writes a literal `-`") goes on the board as a card
    now (`POST /api/boards/:board/cards`, `create_card`, `slipdock add`, in
    the backlog) and into the block as `→ #<card>`. A finding is only for
    what is uncertain, cuts across cards, or shows the handbook wrong
    ("`mix format` can need two passes", "W-1950 §Tests says async is safe,
    but the fixture is one user").

    One record per lesson: an item repeating an open finding on the same
    card (after normalising case, whitespace, backticks, trailing
    punctuation, `#id`s and shas, or most of its words in common) adds to
    its `count`; one that restates an open finding on another card of the
    tree (the same normalised text, or mostly the same telling words, any of
    `gotcha`, `tooling` and `process`) is recorded `merged` into it with a
    `note` saying why, and the listing shows that one with every card it
    was said on (`cards`). One that matched nothing is put to the model
    once, with the open findings it could repeat; a match merges it with
    `cause: "same-lesson-ai"` and the model's reason in its `note` (reopen
    it if the model was wrong). `rule` and `handbook-wrong` items are never
    merged across cards.

    The test for one: would a card on a different subject want to know
    this? Never a pointer (`in the evidence`, `recorded on #1819`), an event
    the board records itself (below), something the card fixed, or a fact
    about the card's own code (`Boards.move_card/4 returns :ok`).
    `Findings: none` is the usual answer; filler isn't. A block that only
    points elsewhere records nothing: the evidence is a comment of its own,
    and its block is read there.
    A line with no known kind is kept whole as a `gotcha`. The server also
    records its own (source `rejection`, `verification`, `requeue`, `timeout`, `failed`,
    `merge`, `audit`, `health`, `incident`), counting repeats on a card, on any
    board, handbook or not. A lane refusal is not one (#1968): the refusal, the
    job's log and its held reason already say so. Findings with source `lane`
    from before then are kept. A card's `rejection` findings are dismissed
    when the card is accepted (or merging, on a board that ships by pull
    request), each with a `note` saying the rework was accepted and when: the
    rejection has been dealt with, and the per-rule tally is in `slipdock
    quality --rules`, read from the verdicts. A `verification` finding stays
    open.

    **Incidents** (#1946): a card that broke after something shipped says so
    with `caused_by` (the card whose shipping caused it, any card you can
    read) and `missed_by` (the check that should have caught it: `bar`,
    `rules`, `ci`, `verify`, `audit` or `none`). Set them only when a person
    says so: `PATCH /api/cards/:id {"caused_by": 123, "missed_by": "ci"}`
    (null clears; create takes them too), `update_card`/`create_card`
    `caused_by` and `missed_by`, `slipdock edit ID --caused-by 123
    --missed-by ci` (`--no-caused-by`, `--no-missed-by`; `add` takes both).
    An unknown layer, or a card you can't read, is a `422` naming the field
    in a sentence. `GET /api/cards/:id` and `get_card` show both ends:
    `caused_by_card` (`{id, hidden: true}` when you can't read it) and
    `incidents`, the incidents a card caused, each with its `missed_by`.
    While an incident names both, its cause carries one `process` finding
    with source `incident` ("#456 (incident) was missed by ci"), changed in
    place as the fields change and gone when either clears
    (`slipdock findings <board> --source incident`).

    Findings are kept on the tree's root board, `open` until a person
    triages them: `promoted` (into the handbook, said in `note`),
    `dismissed`, or `merged` into another finding (which takes its count).
    `slipdock findings <board> [--status S] [--kind K] [--days N] [--scope S]` (REST
    `GET /api/boards/:board/findings?status=&kind=&source=&card=&since=&scope=`)
    lists them; `slipdock finding <id> dismiss|promote|reopen [--note …]`
    or `merge --into <id>` (`PATCH /api/findings/:id {action, note, into}`,
    write access) triages one. A card's `findings` (in `get_card` and
    `GET /api/cards/:id`) counts its open ones.

    What the findings leave for a person is the proposals drafted from them,
    not the open list, which triage and the server handle: the listing
    leads with `awaiting`, the open garden proposals whose subject names
    findings (as the garden lists them, each with its `findings`), and
    `slipdock findings` prints "N proposals await you" before the list, each
    by id. MCP `garden` with `findings: true` lists the same, from the
    tree's root (`check: proposal` alone is every open proposal on the board
    given); `garden_decide` (or `slipdock garden apply|dismiss <id>`, and
    from Claude Code `slipdock garden apply|dismiss <id> --confirm`)
    decides one.

    A finding counted to the board's `findings_propose_at` (3 by default, 0
    off; `update_board`, `PATCH /api/boards/:board`, `slipdock set-board
    --findings-propose-at N`) is drafted by the server as a garden proposal
    for a person: a rule on the `## Rules` of the handbook page holding a
    rule the finding names (`DATA-14`), else the page whose prefix that id
    carries, else the page covering its cards' paths (else Specification),
    with that page's next id; `must` citing a check the finding names, else
    `should`. A finding shows it as `proposal_id` and
    `proposed_rule`, never has two open, and is `promoted` when a person
    applies it. Don't file one by hand for a finding that has one.
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

    `GET /api/guide` takes `?section=short|all|<name>`: the short guide, the
    whole one (as with no `section`), or one section by the name the short
    guide lists; `?format=json` carries the chosen text in `guide`.

    `:board` accepts an id, a board's `code`, or a name. Bodies are documented by the recipes
    above; the fields a card accepts on create and update are `title`,
    `description`, `priority`, `flags`, `tags`, `add_flags`, `remove_flags`,
    `add_tags`, `remove_tags`, `start_date`, `due_date`, `date_precision`,
    `completed`, `percent_complete`, `color`, `border_top`, `border_right`,
    `border_bottom`, `border_left` (each edge's own palette colour; `""` takes
    it off), `column`, `assignee` and `fields`.
    Create also takes `archived` (`true` or `"true"`) to file the new card away at
    once, a record of something already finished with; update does not, so an
    existing card is put away with `POST /api/cards/:id/archive` and brought back
    with `POST /api/cards/:id/restore`.
    """
  end

  defp boards_section(nil, _token, _limit) do
    """

    ## Your boards

    Not shown: this request carried no token. Re-read the guide with one and
    this section lists the boards you can see, every list on them, and which
    list is the ready list, the backlog, the one in progress and the one for
    done work.
    """
  end

  defp boards_section(user, token, limit) do
    boards =
      user
      |> Access.list_boards(activity: true, token: token)
      |> Boards.sort_boards(user.board_sort)

    archived = Access.list_boards(user, archived: true, token: token)

    body =
      if boards == [] do
        "You cannot see any boards yet. `POST /api/boards {\"name\": \"…\", \"code\": \"…\", \"template\": \"Slipdock\"}` makes one (leave `code` out and one is made from the name)."
      else
        {shown, rest} = if limit, do: Enum.split(boards, limit), else: {boards, []}
        Enum.map_join(shown, "\n", &board_line(&1, user)) <> more_boards(rest)
      end

    """

    ## Your boards right now

    #{body}

    The name in backticks after each board is its `code` — the short name for
    it, and the one to use when you address a board by anything but its id.

    **Never take work from a Scheduled list.** A list marked `scheduled`
    (category `scheduled`) is where recurring agent work lands: a recurring
    card's next one is made there. Feed rules work it, sending its top card
    to a runner pool. People don't, and nor does an agent asked what to do
    next: it is never the ready list or the backlog, and the boards below
    mark it `scheduled: worked by feed rules`.

    Sub-boards are not listed here — they hang off their epic's `sub_board`.
    #{archived_note(archived, limit && @short_archived)}
    """
  end

  # The boards past the short guide's limit: the next few by name, then a count.
  defp more_boards([]), do: ""

  defp more_boards(rest) do
    {named, uncounted} = Enum.split(rest, @short_board_names)

    "\n- Also: #{board_names(named, uncounted)}. `list_boards` (or `get_board`, " <>
      "`section: \"all\"`) for their lists."
  end

  defp board_names(boards, more) do
    names = Enum.map_join(boards, ", ", &"##{&1.id} #{&1.name} (`#{&1.code}`)")
    if more == [], do: names, else: "#{names} and #{length(more)} more"
  end

  defp archived_note([], _limit), do: ""

  defp archived_note(archived, limit) do
    {named, more} = if limit, do: Enum.split(archived, limit), else: {archived, []}

    """

    #{length(archived)} board#{if length(archived) == 1, do: " is", else: "s are"} archived and left
    out of the list above: #{board_names(named, more)}.
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
        snoozed = if col.snoozed == [], do: "", else: ", snoozed #{length(col.snoozed)}"

        "#{col.name} (#{role_note(full.columns, col)}, #{open} open of #{length(col.cards)}#{snoozed})"
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

    verified =
      case Slipdock.Verified.switches(full) do
        [] ->
          ""

        on ->
          "\n  - verified work: #{Enum.map_join(on, ", ", &verified_name/1)} (see *Verified work*)"
      end

    verified =
      if Slipdock.Boards.Board.ships_by_pr?(full),
        do:
          verified <>
            "\n  - ships by pull request: push `card-<id>` and open a PR, never the default branch (see *Verified work*)",
        else: verified

    verified = verified <> lanes_lines(full)

    verified =
      if full.profiles,
        do: verified <> "\n  - profiles: on — a card an agent starts gets one (see *Profiles*)",
        else: verified

    """
    - **##{board.id} #{board.name}** (`#{board.code}`) — #{length(board.cards)} top-level cards, #{Enum.count(board.cards, & &1.completed)} done#{if epics > 0, do: ", #{epics} of them epics with subcards"}#{shared_note(board, viewer)}
      - lists: #{lists}
      - #{if roles == "", do: "nothing on this board says which list means what — ask before choosing work from it", else: roles}#{verified}
    """
    |> String.trim_trailing()
  end

  defp verified_name(:bar), do: "a bar before work starts"
  defp verified_name(:evidence), do: "evidence on completion"
  defp verified_name(:verify), do: "a second agent verifies"

  # Verified work (#1620): described only when one of the reader's boards
  # has a switch on, and then only the steps that are on somewhere.
  defp verified_work(nil, _token), do: ""

  defp verified_work(user, token) do
    boards = Access.list_boards(user, token: token)
    on = boards |> Enum.flat_map(&Slipdock.Verified.switches/1) |> Enum.uniq()
    on = if Enum.any?(boards, &Slipdock.Boards.Board.ships_by_pr?/1), do: on ++ [:ship], else: on

    if on == [] do
      ""
    else
      steps = Enum.map_join(on, "\n", &verified_step/1)

      """

      ## Verified work

      Some of your boards check what an agent says it finished; each board's
      line under *Your boards right now* says which checks it has on. They
      apply to agents only: a person completes cards as usual.

      #{steps}
      """
    end
  end

  # The board line's lanes items (#1628): on, and its shared paths (#1971).
  defp lanes_lines(%{lanes: true} = board) do
    lanes_line(Slipdock.Lanes.mode(board)) <>
      case Slipdock.Lanes.shared_paths(board) do
        [] -> ""
        shared -> "\n  - shared paths (hold no lane): " <> Enum.map_join(shared, ", ", &"`#{&1}`")
      end
  end

  defp lanes_lines(_board), do: ""

  defp lanes_line("advise"),
    do:
      "\n  - lanes: advise — write a card's paths before starting it; an overlap is " <>
        "told in the job's prompt, not held (see *Lanes*)"

  defp lanes_line(_mode),
    do: "\n  - lanes: on — write a card's paths before starting it (see *Lanes*)"

  # Lanes (#1628): described only when one of the reader's boards has it on.
  defp lanes_section(nil, _token), do: ""

  defp lanes_section(user, token) do
    if user |> Access.list_boards(token: token) |> Enum.any?(& &1.lanes) do
      """

      ## Lanes

      Some of your boards keep agents working side by side out of each
      other's files (`lanes: on` on the board's line). Before moving a card
      into an in-progress list, write the paths its work will touch on the
      card's `paths`: globs relative to the repository, like
      `lib/slipdock/runners/**` or `docs/{manual,agents}.md`
      (`PATCH /api/cards/:id {"paths": ["…"]}`, `update_card` `paths`,
      `slipdock edit ID --paths "a/**,b.md"`; or `paths` when making it:
      `create_card`, `slipdock add --paths`). Moving it in is refused
      (`422`, naming the card in the way) while its paths overlap an open
      card in progress on the board's tree that a runner job is working on
      (a job queued, claimed or running on it or its epic; a card in
      progress with no open job holds no lane), the card's own subcards and
      parents aside, and so are creating one straight into an
      in-progress list and widening an in-progress card's paths onto
      another's. An epic's lane is its subcards': in progress it holds none
      of its own, and it waits only when none of the subcards it could take
      could start. Narrow the paths, take other work, or ask a person: a
      person moving the card overrides it. A runner job for such a card is
      held (`Lane: overlaps #N, in progress`) until the other card is done,
      and a claimed job's prompt lists the card's paths. Verify and merge
      jobs are never held, by lanes or the WIP limit: they finish work. On a board that
      verifies work and ships by push, a card awaiting verification has
      shipped: it frees its lane and no longer blocks the cards that depend
      on it (a dependency stub says `released: true`), until a rejection
      sends it back for rework. On a board that ships by pull request it
      keeps both until the merge. Stage only files
      under them; with several sessions in one repository, work in a git
      worktree of your own.

      **Shared paths.** A board's `shared_paths` (`shared paths` on its
      line; `PATCH /api/boards/:id {"shared_paths": ["docs/manual.md"]}`,
      `update_board` `shared_paths`, `slipdock set-board B --shared-paths
      "docs/manual.md,README.md"`; `[]` or `""` clears) are globs that never
      count toward a lane: a card's path wholly inside one is left out on
      both sides, so an overlap only there holds nobody, while one anywhere
      else still does. A path only partly inside one (`docs/**` when
      `docs/manual.md` is shared) counts in full. Declare the shared files
      you edit honestly: a card's JSON names the board's `shared_paths` and
      its own `paths_shared`, the job's prompt lists them, and the
      lane-check hook lets a staged file under one through. Others may be
      editing them too: keep to your own sections, and rebase on the
      default branch before pushing.

      **Advisory lanes.** A board's `lane_mode` is `off`, `hold` (all of
      the above; `lanes: true` means it) or `advise` (`lanes: advise` on its
      line; `PATCH /api/boards/:id {"lane_mode": "advise"}`, `update_board`
      `lane_mode`, `slipdock set-board B --lane-mode advise`). Under
      `advise` nothing is refused or held: you start the card, and a
      claimed job's prompt carries a *Lanes* block naming each card in
      progress whose paths overlap yours, the globs, and the job and
      runner on it. Before editing those files read that card (`slipdock
      card <id>`) and its branch (`card-<id>`, if pushed), stay out of
      them where you can, and rebase on the default branch before pushing.
      A card's JSON says the overlap as `lane_overlap` (`{card, title,
      mode}`). `lanes: true/false` keeps working and means `hold`/`off`.
      """
    else
      ""
    end
  end

  # Profiles (#1951): described only when one of the reader's boards has them on.
  defp profiles_section(nil, _token), do: ""

  defp profiles_section(user, token) do
    if user |> Access.list_boards(token: token) |> Enum.any?(& &1.profiles) do
      """

      ## Profiles

      Some of your boards give each card a profile, one word for what kind
      of change it is (`profiles: on` on the board's line): `security`,
      `schema`, `feature`, `fix`, `docs` or `spike`. When an agent claims or
      starts a card with none (moves it into an in-progress list, creates it
      in one, or a runner takes its job), the board infers one from its
      paths and tags, strictest first: `security` if tagged so or a path is
      in an auth, access, token or egress module; `schema` for a migration
      or schema file; `spike` if tagged so; `fix` if tagged `bug`; `docs` if
      every path is documentation; else `feature`. Write the card's paths
      before starting it so the inference has them. When you complete it,
      give the change you made (`changed_lines`, added plus removed, and
      `changed_files`: `complete_card`, `PATCH /api/cards/:id`, `slipdock
      done --diff-base origin/main`): a migration raises the profile to
      `schema`, a security path to `security`, and over 400 lines a `fix` or
      `docs` card to `feature` unless a person set it; never lower. Set or clear it
      yourself with `profile` (`PATCH /api/cards/:id {"profile": "fix"}`,
      `update_card`/`create_card` `profile`, `slipdock edit ID --profile
      fix` or `--no-profile`); an unknown name is refused (`422`) with the
      list. It shows in the card's JSON, `get_card`, `list_cards`,
      `slipdock card` and the ledger's lines (`card.profile`). Beside it,
      `profile_source` says where it came from: `inferred`, or set by a
      `person`, an `agent` or a `rule` (nil with no profile, or unrecorded).

      Each profile has a human tier (the board's JSON, `profile_tiers`):
      `none` (`docs`, `fix`, `spike`) and `ledger` (`feature`) let an agent's
      acceptance merge; `before_merge` (`schema`, `security`) holds
      it on a board that ships by pull request: the card goes
      `verify_state: "held"`, no merge job, and a `release` wait asks a
      person to Merge or Send back. An agent can't answer that wait or
      decide a held card (`403`); a person's answer queues the merge or
      returns the card rejected with their reason. A card sent back is
      rework like any rejection. Change a tier on the root board with
      `PATCH /api/boards/:id {"profile_tiers": {"schema": "none"}}`
      (`default` puts one back), `update_board` `profile_tiers` or
      `slipdock set-board B --profile-tier schema=none`.

      A `spike` card (profile `spike`, or no profile and tagged `spike`, on
      any board) answers a question by building, and its code is never
      merged: complete it with `no_code` naming the answer's page and the
      branch its prototype is on (`slipdock done ID --no-code "spike: answer
      on W-…, prototype on card-ID"`), never a pull request. An agent naming
      one is refused (`422`), and accepting it merges nothing. It holds no
      lane, even with paths: nothing is refused or held because of it.
      Spikes come from planning: the `slipdock-plan` skill's Spike stage,
      between Grill and Spec for a feature or a system, turns an open
      question that only building can answer, whose "no" changes the spec
      and costs more found late than the spike does, into a spike subcard of
      the epic once a person confirms it (unattended: one `product` wait),
      its bar the question, and stops. Write the answer as a page pinned to
      the epic: the question, the answer or *inconclusive*, the evidence and
      what it changes in the plan. When the epic's last open spike is
      accepted, the server opens one `product` wait on the epic, "Spikes
      answered (#…): resume planning"; a person resumes, and planning
      writes the Spec from the answers. Nothing resumes by itself.

      A profile also sets the verifier's spend. Completing a `docs` card
      on a verifying board queues no verify job: the server accepts it
      (*Accepted by the server*, `verify_checks.not_verified: "docs"`, the
      evidence's suite as the suite part, so give CI's result as `suite`)
      and its tier decides the merge; a failing suite sends it back. The
      bar is still required. A verify job on a `schema` or `security` card
      adds a defect review: findings as `defect:important|nit|pre-existing=<file>:<line>[:why]`
      checks (`verify_checks.defect_review`); an Important one is a
      rejection, a Nit or a Pre-existing one is reported only. A verify
      job on a `fix`, `feature`, `schema` or `security` card adds a
      mutation review: 3 to 5 changed lines broken on purpose, the card's
      tests run against each, given as
      `mutant:killed|survived|pre-existing=<file>:<line>:<mutation>[:note]`
      checks, or `mutants=n/a:<why>` (`verify_checks.mutants`). A survivor
      on a changed line is a rejection naming the test to write; a
      `pre-existing` one (lines the diff didn't change) is kept as a
      finding; killed ones are carried to a resubmission. A claimed
      job carries its card's `profile` (MCP `claim_job` `profile`, the REST
      claim's `job.profile`, the runner's `x-card-profile` header); a
      runner's own config may pick a model by it (`MODEL_<profile>`), and
      the server never names one.
      """
    else
      ""
    end
  end

  defp verified_step(:ship) do
    """
    **Shipping by pull request** (`ship_via: "pull_request"`, said on the
    board's line). Never push the default branch: push a branch named
    `card-<id>` and open a pull request from it (`gh pr create`, the card id
    in its title), and complete the card with the pull request's URL in
    `evidence_pr` and its head commit in `evidence_commit` (`slipdock done
    ID --pr URL --evidence-commit SHA`, `complete_card` `pr` and `commit`):
    the merge needs both, so a board asking for evidence refuses the
    completion without the PR, and a PR without its commit, a resubmission
    after a rejection too (`422`). **An epic** (a card whose sub-board holds cards)
    has no pull request of its own to name: each subcard ships and merges
    its own. Once they are all accepted and merged, complete the epic
    without `--pr` (`slipdock done ID --evidence "<the subcards' PRs, the
    last merged build>"`), and accepting it completes it with nothing to
    merge (so does one naming a pull request a subcard already merged).
    Only work done on the epic itself goes on its own branch, with a pull
    request named by `--pr`, which the acceptance merges. **A card that
    changes no code** (a sweep, a handbook reconcile, a card that only
    reads and files) has no branch and no pull request, and never a token
    one: complete it with why in `evidence_no_code` (`slipdock done ID
    --no-code "<why>" --evidence "<what you did>"`, `complete_card`
    `no_code`), never beside `--pr` (`422`). The verifier judges the claim
    against the card's ask instead of checking out a commit, and accepting
    it completes it with nothing to merge. The build to watch is the
    pull request's (`gh pr checks <branch> --watch --fail-fast`), and it is
    the full test run: before pushing, run the tests you added or changed
    and the project's own pre-push checks (what its `CLAUDE.md`,
    contributing guide or handbook lists; else formatting and a compile
    that fails on warnings), not the whole suite, and complete the card
    once its checks pass (with no checks on it, run
    the suite yourself). A verifier doesn't run the suite again either: it
    reads the change and checks that the pull request's head is the
    submitted commit and its checks passed. A rejected card's next attempt pushes the same branch,
    so the same pull request updates. A claimed job's prompt and the
    card's `shipping` (in `get_card`) say all this for the card in hand.
    **A card tagged `security`** gets a neutral pull request (`shipping`
    has `neutral: true`): the title `Maintenance (#<id>)` rather than the
    card's, `--body "Card #<id>."` rather than `--fill`, and commits, title
    and body that say what changed in general terms, never the hole, an
    exploit or the affected endpoints. The detail stays on the card until
    the fix is deployed; the closing comment may link it after that.
    Don't merge it: accepting the card sets `verify_state: "merging"` and
    queues a `merge` job for a runner (one idle now first, else the one
    that accepted it), and the merge completes the card
    (its `merge_sha`). A failed merge sends it back rejected, the merge's
    reason as the rejection: rebase the branch and complete it again.
    A pull request already merged at the accepted commit completes the
    card with that merge commit; one merged at another head leaves it
    merging and says which head, and neither counts as a rejection. A
    person can say they merged it by hand (`verify_card` `merged`).
    """
  end

  defp verified_step(:bar) do
    """
    **A bar before work starts.** Before moving a card into an in-progress
    list, write what done means for it in the card's `bar`
    (`PATCH /api/cards/:id {"bar": "…"}`, `update_card` `bar`, `slipdock edit
    ID --bar TEXT`), or when you make it: `bar` and `paths` on
    `POST /api/boards/:board/cards` and `create_card`, `slipdock add --bar
    TEXT --paths "a/**"`, checked as on an update. A planner's bar is better
    than one written at claim time. Moving a card with no bar into an in-progress list is
    refused (`422`), and so is creating one there with no bar. The bar locks when work
    starts (the move, or the card created in progress): changing it after that
    is refused too, and only a person can. Work to the bar as written, and
    say on the card how each part of it was met.

    **Check the bar at pickup**, before building: read each part against
    this guide. If one can't be met as written because it needs a person (a
    handbook rule added, reworded or dropped, a merge, a deploy to prod,
    applying a proposal), stop and ask: open a wait (`slipdock wait ID …`,
    `update_card` `wait`) naming the part and what you could do instead, so
    a person rewords the bar or confirms the alternative. Don't build to
    your own reading of it and leave the conflict to the verifier.

    **Write a bar that can be met.** Each part is something the builder can
    do and show. A rule change is phrased as "proposed as a garden proposal
    (rule id, wording)", never "W-x has rule Y", since a rule is a person's
    call and an agent only proposes it. The same goes for anything else only
    a person does: "pull request open, its CI green", not "merged"; "ready
    to deploy", not "live on prod".
    """
  end

  defp verified_step(:evidence) do
    """
    **Evidence on completion.** Completing a card takes what you checked:
    `evidence` (in words), `evidence_commit` and `evidence_branch`,
    `evidence_tests` (the test files you added or changed) and
    `evidence_suite` (`{"result": "passed"|"failed", "passed": N, "failed":
    N}`). Give what applies: `complete_card` `evidence` / `commit` /
    `branch` / `tests` / `suite`, `slipdock done ID --evidence TEXT
    --evidence-commit SHA --branch B --tests a.exs,b.exs --suite
    passed:38:0`, or the same fields on `PATCH /api/cards/:id` with
    `"completed": true`. The server checks their shape, not their truth: a
    second agent does that. Completing with none of them, moving the card
    into a done list without it, or creating a card already done (in a
    done list, or with `"completed": true`) without it, is refused
    (`422`). So is evidence that is a bare `-` once trimmed, on any board:
    a client that doesn't read stdin sends the dash for `--evidence -`, so
    pass the text itself, or pipe it with `--evidence -` from a CLI that
    reads stdin (evidence that merely starts with `-` goes through). The
    evidence is posted on the card as a comment; reopening the card clears
    it, so the next completion brings its own.
    """
  end

  defp verified_step(:verify) do
    """
    **A second agent verifies.** Completing a card *submits* it: it stays
    open in its list with `verify_state: "pending"` and the `review` flag,
    and isn't done until someone else decides. Moving it into a done list
    yourself is refused, and so is creating a card already done (in a done
    list, or completed): create it in another list and complete it. Don't take a pending card as your next work unless
    you are the verifier. To verify one you did not submit: check out the
    evidence's commit and judge, in order, the ask (does the bar cover what
    the card asks for?), the bar, and on a board with a handbook the rules
    for the diff's paths (`slipdock handbook B --paths-from -`) and the
    closing `Handbook:` line against the docs gate. On a bug, the ask is
    the reported symptom: the check is would the reporter now see it fixed,
    not does the work meet the bar. The builder reproduces the reported
    symptom on the reporter's scenario and posts the repro as its own
    comment; a clean repro that doesn't show it opens a wait saying what was
    seen and asking for a screenshot or steps (which screen, which control),
    never conditions built until something fails. A bug card whose card or
    evidence says the reported symptom or its cause was never seen is a
    rejection (`the ask: …`), however good the tests. A bar item that adds,
    rewords or drops a handbook rule is met by a matching open rule proposal
    (an `edit_section` step on that page's `## Rules`; `slipdock garden B
    --check proposal`): judge the proposal's content, not the live rules,
    and name its id when accepting. A rejection never asks the builder to
    edit `## Rules` directly, only to file or correct the proposal. Then
    `verify_card` (`slipdock verify ID accept|reject --reason TEXT
    --evidence-commit SHA`, `POST /api/cards/:id/verify {"decision":
    "accept"|"reject", "reason": "…", "commit": "…"}`). Accepting completes
    it and moves it to the done list. Rejecting needs the reason, citing the check it fails (`bar 2: …`,
    `the ask: …`, a rule id such as `ARCH-3: …`, or `Handbook line: …`) and
    giving the verdict in parts as `checks` (`ask=ok|misses`, `bar:2=fail:why`,
    `rule:UX-4=pre-existing:lib/x.ex:42` for a rule broken only in lines
    the diff didn't change, never a rejection and kept as a `rule` finding,
    `suite=412:0`, `rule:UX-4=broken`, `handbook_line=ok|disputed`,
    `mutant:killed|survived|pre-existing=<file>:<line>:<mutation>[:note]`,
    `mutants=n/a:<why>`; kept as
    `verify_checks`, and refused without a failing part, or on an accept
    with a broken `must` rule). A rejection names every instance found:
    once a rule is found broken, the verifier looks for every other
    instance of the same break the card could have missed (the same list,
    the same string, the same door) and names them all in one rejection,
    each as its own `rule:<id>=broken:<file>:<line>` check under the one
    rule, and says in the reason that it looked; a rule broken in several
    places is one failing part, its instances listed under it in the
    rejection's comment. A card resubmitted after a rejection is
    judged on what changed: its verify prompt carries the last verdict and
    the commit it judged, the verifier judges the parts that failed and any
    part the commits since touch, and a part that passed then and isn't
    judged again (`bar:1=carried`, or left out) is kept carried, marked
    with that commit (`carried_from`, or `verify_checks.carried` for the
    ask and the Handbook line); a part that failed can't be carried, and an
    audit carries nothing. A rejection goes
    on the card as a comment and in `get_card`'s `rejection` (a claimed
    job's prompt carries it too; the handoff only points there), the
    evidence is cleared, the builder's own assignment comes off, its
    `verify_rejections` counts one more, and it goes back to the top of
    the ready list, next for the runners, so whoever takes it next fixes
    what the reason says and completes it again. The second rejection, or
    one for a rule id an earlier one named, keeps the card flagged
    `review` until it is accepted, comments *Going round in circles* with
    the rounds, alerts and emails the owner, and puts it first in their
    waiting (`circling`): it is still sent for rework. Past the board's
    `verify_rejection_limit` (2 by default, 0 never) the rejection opens a
    wait on the board's owner instead (*Rework as rejected* or *Accept as
    is*, listing the parts that failed each time and asking whether the
    approach, not the fix, is wrong): the card is flagged `waiting`, and only a person answers. A
    board's `verify_audit` (1 in N, 0 none) queues about one card in N an
    agent accepted to the verify pool again as an audit (kind `verify`,
    `audit: true`; never to its builder's or verifier's runner): judge it
    afresh, `should` rules too, and answer `slipdock verify ID agree|disagree
    --reason …` (`verify_card`). The acceptance stands; agree only comments.
    Disagree also files the rework: one card in the ready list, titled
    `Audit of #ID: <reason>`, with the failed parts, the audit comment's
    link, the accepted card's paths, `caused_by` it, and priority `high`
    for a surviving mutant or a broken `must` rule. The owner's alert and
    the `audit` finding name it, and the alert clears itself once that card
    is accepted or completed; a second disagreement comments on that card
    while it is open, its alert clearing with the same rework. The submitter can't
    decide its own card (`403`): a different agent is a different token,
    or a different runner job. A board with a `verify_pool` also queues
    each submitted card for that runner pool as a job of kind `verify`,
    whose prompt carries the card's ask, the bar, the evidence and those
    checks, and asks
    its agent to report each step with `job-progress --step` (no note, so
    the card stays quiet until the decision). The
    runner that built the card never takes it. Whoever decides first
    decides, and the other verify jobs on the card stop.
    """
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
      nil when col.category == "triage" ->
        "triage: for a person, never take work from it"

      nil when col.category == "scheduled" ->
        "scheduled: worked by feed rules, never take work from it"

      nil ->
        "uncategorised"

      role when is_binary(col.category) and col.category != "" ->
        role

      role ->
        "#{role} by name only"
    end
  end

  @doc """
  What a list means: its `category` when it has one, else what its name says.
  Older boards (and boards made by hand) often carry no categories at all, and
  an agent still has to choose work from them.
  """
  def role(columns, %Column{} = col) do
    cond do
      Enum.member?(~w(triage scheduled), col.category) -> nil
      Enum.member?(~w(todo doing done dropped), col.category) -> col.category
      named?(col, ["in progress", "doing", "wip", "started", "active"]) -> "doing"
      named?(col, ["done", "complete", "shipped", "finished"]) -> "done"
      named?(col, ["dropped", "won't", "wont do", "cancelled", "rejected"]) -> "dropped"
      named?(col, todo_names() ++ backlog_names()) -> "todo"
      # An uncategorised list on a board that has no categories at all: assume
      # work can come from it, since the board offers nothing better.
      # A Triage list (#1793) or a Scheduled one (#2100) doesn't count:
      # adding one keeps that reading.
      Enum.all?(columns, &Enum.member?([nil, "", "triage", "scheduled"], &1.category)) -> "todo"
      true -> nil
    end
  end

  @doc """
  Which of a board's lists plays which part, by the same reading the guide
  gives under "Your boards right now": the ready list work is taken from, the
  backlog behind it, the list in progress and the one for done work, and the
  Scheduled list recurring agent work lands in (#2100), which is never the
  ready list. Any of them may be nil.
  """
  def list_roles(columns) do
    %{
      ready: ready_list(columns),
      backlog: backlog_list(columns),
      doing: list_of_role(columns, :doing),
      done: list_of_role(columns, :done),
      scheduled: Enum.find(columns, &Column.scheduled?/1)
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
