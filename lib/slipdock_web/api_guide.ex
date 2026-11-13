defmodule SlipdockWeb.APIGuide do
  @moduledoc """
  The document `GET /api/guide` serves: how an agent should use these boards to
  track its own work — the model, the epic/subcard convention, how to choose
  what to do next, and what to write back as it goes.

  Anything that could drift from the code — the vocabularies, the endpoint
  list, the reader's own boards — is generated at request time; the rest is
  prose. Keep it that way: a guide that lies is worse than no guide.

  The prose is Markdown, one file per section in `lib/slipdock_web/api_guide/`
  (#2800), compiled into this module as EEx templates: `<%= @base %>` and the
  like are the generated parts, which this module works out and passes in.
  Edit a section there, not here. `test/slipdock_web/api_guide_golden_test.exs`
  holds the rendered guide to `test/support/fixtures/api_guide/`; a change to its text
  regenerates them with `GOLDEN=1 mix test` on that file.
  """

  require EEx

  alias Slipdock.Access
  alias Slipdock.Boards
  alias Slipdock.Boards.{Card, CardLink, Column, StatusUpdate}

  # Each section's prose, `api_guide/<name>.md`, as a clause of `md/2`.
  @templates_dir Path.join(__DIR__, "api_guide")
  @templates @templates_dir |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()

  for path <- @templates do
    name = path |> Path.basename(".md") |> String.to_atom()
    @external_resource path

    defp md(unquote(name), var!(assigns)) do
      _ = var!(assigns)
      unquote(EEx.compile_file(path))
    end
  end

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
      |> Enum.reject(fn {key, _, _} -> key == "intro" or Enum.member?(@core, key) end)
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
    md(:intro, %{base: base})
  end

  defp getting_in(base, user) do
    who =
      case user do
        nil ->
          md(:getting_in_anonymous, %{})

        user ->
          md(:getting_in_signed_in, %{
            email: user.email,
            name: if(user.name, do: " (#{user.name})")
          })
      end

    md(:getting_in, %{base: base, who: String.trim(who)})
  end

  defp model do
    md(:model, %{})
  end

  defp epics do
    md(:epics, %{})
  end

  # Moved out of *Epics and subcards* (#2042) to keep the short guide, which
  # carries that section whole, under its budget.
  defp sprints do
    md(:sprints, %{})
  end

  defp choosing(base) do
    md(:choosing, %{
      base: base,
      priority_order: Enum.join(~w(critical high medium low none), " > ")
    })
  end

  defp working do
    md(:working, %{})
  end

  # Semantic search is the one thing here an agent cannot work out from the
  # endpoint list, because the endpoint list doesn't say *when* to reach for it.
  defp finding(base) do
    md(:finding, %{base: base})
  end

  defp recipes(base) do
    md(:recipes, %{base: base})
  end

  # Automations: the one part of the API that goes on working after the agent
  # has gone, so it needs saying plainly what a rule will and won't do.
  defp automations do
    v = Slipdock.Automations.Spec.vocabulary()
    allowances = Slipdock.Automations.Runner.allowances()

    md(:automations, %{
      max_recipients: Slipdock.Automations.Spec.max_recipients(),
      max_actions: Slipdock.Automations.Spec.max_actions(),
      max_rules: Slipdock.Automations.max_rules(),
      emails_per_hour: allowances.emails_per_hour,
      callbacks_per_minute: allowances.callbacks_per_minute,
      triggers: Enum.map_join(v.triggers, " · ", & &1.type),
      condition_fields: Enum.join(v.condition_fields, ", "),
      condition_ops: Enum.join(v.condition_ops, ", "),
      actions: Enum.map_join(v.actions, " · ", & &1.type),
      placeholders: Enum.join(v.placeholders, " ")
    })
  end

  # Deploys and DORA metrics (#1134). The setup prompt is the wizard's own,
  # so an agent with the tools can wire a repository up itself.
  defp deployments(base) do
    {:ok, defaults} = Slipdock.Deployments.Setup.normalise(%{})

    md(:deployments, %{
      setup_prompt: Slipdock.Deployments.Setup.prompt(defaults, %{base_url: base})
    })
  end

  defp health_monitor do
    md(:health_monitor, %{})
  end

  defp runners do
    md(:runners, %{trust_contract: Slipdock.Machines.TrustContract.markdown()})
  end

  defp wiki do
    md(:wiki, %{})
  end

  # The handbook (#1261, W-1934): what a pass reads before building and
  # updates before closing, on boards that keep one.
  # The section pages' titles, from the Tool itself (#2045).
  defp handbook_titles, do: Enum.map_join(Slipdock.Handbook.sections(), ", ", & &1.title)

  defp handbook do
    md(:handbook, %{handbook_titles: handbook_titles()})
  end

  # Code sweeps (#1793, W-2310 §Sweeps and static checks), under the
  # handbook: a section of its own would lengthen the short guide's index.
  defp sweeps do
    md(:sweeps, %{})
  end

  defp findings_section do
    md(:findings, %{})
  end

  # Moving a whole board somewhere else. Distinct from the wiki's Markdown
  # export above, and the guide says which is which, because an agent asked to
  # "export the board" could reasonably reach for either.
  defp portable do
    md(:portable, %{max_rows: Slipdock.Portable.max_rows()})
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
    md(:endpoints, %{
      endpoints:
        Enum.map_join(endpoints(), "\n    ", fn {verb, path} ->
          String.pad_trailing(verb, 7) <> path
        end)
    })
  end

  defp boards_section(nil, _token, _limit) do
    md(:boards_anonymous, %{})
  end

  defp boards_section(user, token, limit) do
    boards =
      user
      |> Access.list_boards(activity: true, token: token)
      |> Boards.Arrangement.sort_boards(user.board_sort)

    archived = Access.list_boards(user, archived: true, token: token)

    body =
      if boards == [] do
        "You cannot see any boards yet. `POST /api/boards {\"name\": \"…\", \"code\": \"…\", \"template\": \"Slipdock\"}` makes one (leave `code` out and one is made from the name)."
      else
        {shown, rest} = if limit, do: Enum.split(boards, limit), else: {boards, []}
        Enum.map_join(shown, "\n", &board_line(&1, user)) <> more_boards(rest)
      end

    md(:boards, %{
      body: body,
      housekeeping: housekeeping_note(limit),
      archived: archived_note(archived, limit && @short_archived)
    })
  end

  # The Housekeeping list (#2777), in the whole guide only: the short one is
  # at its cap, and its board lines already mark the list.
  defp housekeeping_note(nil) do
    md(:housekeeping, %{})
  end

  defp housekeeping_note(_limit), do: ""

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

      md(:verified_work, %{steps: steps})
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
      md(:lanes, %{})
    else
      ""
    end
  end

  # Profiles (#1951): described only when one of the reader's boards has them on.
  defp profiles_section(nil, _token), do: ""

  defp profiles_section(user, token) do
    if user |> Access.list_boards(token: token) |> Enum.any?(& &1.profiles) do
      md(:profiles, %{})
    else
      ""
    end
  end

  defp verified_step(:ship) do
    md(:verified_ship, %{})
  end

  defp verified_step(:bar) do
    md(:verified_bar, %{})
  end

  defp verified_step(:evidence) do
    md(:verified_evidence, %{})
  end

  # The docs places (SPEC-10) come from `Slipdock.Verified.docs_places/0`
  # (#2763), so a place added there is in the guide too.
  defp verified_step(:verify) do
    places = Slipdock.Verified.docs_places()

    md(:verified_verify, %{
      docs_places_count: count_word(length(places)),
      docs_places: Enum.map_join(places, "; ", fn {name, files} -> "#{name}: `#{files}`" end)
    })
  end

  @count_words ~w(no one two three four five six seven eight nine ten eleven twelve)
  defp count_word(n) when n < length(@count_words), do: Enum.at(@count_words, n)
  defp count_word(n), do: Integer.to_string(n)

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

      nil when col.category == "housekeeping" ->
        "housekeeping: worked by runners after the ready list; pick from it only when the " <>
          "ready list has nothing"

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
      Enum.member?(~w(triage scheduled housekeeping), col.category) ->
        nil

      Enum.member?(~w(todo doing done dropped), col.category) ->
        col.category

      named?(col, ["in progress", "doing", "wip", "started", "active"]) ->
        "doing"

      named?(col, ["done", "complete", "shipped", "finished"]) ->
        "done"

      named?(col, ["dropped", "won't", "wont do", "cancelled", "rejected"]) ->
        "dropped"

      named?(col, todo_names() ++ backlog_names()) ->
        "todo"

      # An uncategorised list on a board that has no categories at all: assume
      # work can come from it, since the board offers nothing better.
      # A Triage list (#1793), a Scheduled one (#2100) or a Housekeeping
      # one (#2777) doesn't count:
      # adding one keeps that reading.
      Enum.all?(
        columns,
        &Enum.member?([nil, "", "triage", "scheduled", "housekeeping"], &1.category)
      ) ->
        "todo"

      true ->
        nil
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
      scheduled: Enum.find(columns, &Column.scheduled?/1),
      housekeeping: Enum.find(columns, &Column.housekeeping?/1)
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
