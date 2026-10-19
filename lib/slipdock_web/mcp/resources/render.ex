defmodule SlipdockWeb.MCP.Resources.Render do
  @moduledoc """
  A resource `SlipdockWeb.MCP.Resources` has found, as Markdown for the model
  to start from. The lines are the prompts' (`SlipdockWeb.MCP.Prompts.Context`)
  and the card is `get_card`'s, so a resource, a prompt and a tool say the
  same thing about the same card.

  Each kind has a size cap. Anything cut off ends with a line naming the tool
  that gets the rest: a resource is a starting point, not the whole board.
  """

  alias Slipdock.{Boards, Swimlanes, Wiki, Work}
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Prompts.Context

  # Characters, at about four to a token: what a client puts in front of the
  # model before the person has said anything.
  @caps %{board: 40_000, card: 40_000, page: 100_000, view: 40_000, work: 40_000}
  @comments 10

  @doc "The size cap for a kind, in characters."
  def cap(kind), do: Map.fetch!(@caps, kind)

  @doc "The Markdown for a resolved resource."
  def render({:board, board}, _context) do
    roles = Context.roles(board)

    lists =
      Enum.map_join(board.columns, "\n\n", fn col ->
        part =
          Enum.find([:ready, :backlog, :doing, :done], &(roles[&1] && roles[&1].id == col.id))

        {done, open} = Enum.split_with(col.cards, & &1.completed)

        "## #{col.name}#{if part, do: " (#{part})"}\n" <>
          lines(Enum.map(open, &card_line/1)) <>
          if(done == [], do: "", else: "\n- …and #{length(done)} done")
      end)

    """
    # #{Context.board_heading(board)}
    #{blank_or(board.description)}
    #{lists}
    """
    |> cut(:board, "get_board with board #{board.code || board.id}, or list_cards")
  end

  def render({:card, card}, context) do
    json = V.card(card)
    docs = Wiki.pages_for_card(card, context.user)

    [
      "# #{Context.card_line(card)}",
      "Board: #{card.board.name} · list: #{json.column}" <>
        if(card.completed, do: " · completed", else: "") <>
        if(card.archived_at, do: " · archived", else: ""),
      facts(json),
      section("Handoff", Context.handoff_text(card)),
      section("Waiting", Context.wait_text(card)),
      section("Description", blank_or(card.description)),
      section("Checklist", checklist(json.checklist)),
      section("Subcards", Context.open_subcards(context, card, 30)),
      section("Recent comments", comments(json.comments)),
      section("Wiki pages", docs(docs))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> cut(:card, "get_card with card #{card.id}")
  end

  # An encrypted note is returned as it is stored: the ciphertext is the
  # page, and the passphrase never reaches the server.
  def render({:page, page}, _context) do
    note =
      if page.encrypted,
        do:
          "> This page holds Meld Encrypt ciphertext. It is shown as stored; " <>
            "the server cannot decrypt it.\n\n",
        else: ""

    (note <> (page.front_matter || "") <> (page.body || ""))
    |> cut(:page, "read_page with page #{page.code}")
  end

  def render({:view, board, view}, _context) do
    config = view.config |> Config.from_map() |> Config.sanitize(board)
    grid = Swimlanes.grid(board, config)
    many_cols? = length(grid.cols) > 1

    rows =
      Enum.map_join(grid.rows, "\n\n", fn row ->
        cells =
          grid.cols
          |> Enum.zip(row.cells)
          |> Enum.reject(fn {_col, cards} -> cards == [] end)
          |> Enum.map_join("\n", fn {col, cards} ->
            head = if many_cols?, do: "### #{col.label}\n", else: ""
            head <> lines(Enum.map(cards, &card_line/1))
          end)

        "## #{row.label} (#{row.count})\n" <> if(cells == "", do: "- none", else: cells)
      end)

    """
    # #{view.name}
    Saved view on #{Context.board_heading(board)}.

    #{if rows == "", do: "Nothing matches this view.", else: rows}
    """
    |> cut(:view, "list_cards with board #{board.code || board.id}")
  end

  def render(:work, context) do
    sections =
      context
      |> Context.my_work(nil)
      |> Work.group(false)
      |> Enum.map_join("\n\n", fn s ->
        "## #{s.label}\n" <>
          lines(Enum.map(s.items, &"#{card_line(&1.card)} — #{Context.path_line(&1)}"))
      end)

    """
    # My work
    The cards assigned to me on every board, by when they are due (today is #{Context.today(context)}).

    #{if sections == "", do: "Nothing is assigned to me.", else: sections}
    """
    |> cut(:work, "list_cards with assignee \"me\"")
  end

  # A card on a board, view or My work: the prompts' line, with who has it.
  # A view shows the wiki pages placed on the board beside the cards.
  defp card_line(%Slipdock.Wiki.Page{} = page), do: "#{page.code} #{page.title} (wiki page)"

  defp card_line(card) do
    who =
      case card |> Boards.Card.assignees() |> Enum.map(&(&1.name || &1.email)) do
        [] -> ""
        names -> " — #{Enum.join(names, ", ")}"
      end

    Context.card_line(card) <> who
  end

  defp facts(json) do
    [
      json.assignees != [] && "Assigned: #{Enum.map_join(json.assignees, ", ", &who/1)}",
      json.tags != [] && "Tags: #{Enum.join(json.tags, ", ")}",
      json.start_date && "Starts #{json.start_date}",
      json.blocked_by != [] && "Blocked by: #{Enum.map_join(json.blocked_by, ", ", &"##{&1.id}")}",
      json.blocks != [] && "Blocks: #{Enum.map_join(json.blocks, ", ", &"##{&1.id}")}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp who(%{name: name}) when is_binary(name), do: name
  defp who(%{email: email}), do: email
  defp who(_), do: "someone"

  defp checklist(%{items: []}), do: nil

  defp checklist(%{items: items}),
    do: Enum.map_join(items, "\n", &"- [#{if &1.done, do: "x", else: " "}] #{&1.text}")

  defp comments([]), do: nil

  defp comments(comments) do
    # Newest first as loaded; the newest few, read top to bottom.
    shown = comments |> Enum.take(@comments) |> Enum.reverse()
    older = length(comments) - length(shown)

    if(older > 0, do: "(#{older} older, in get_card)\n\n", else: "") <>
      Enum.map_join(shown, "\n\n", fn c ->
        by = if c.author, do: who(c.author), else: "someone"

        "**#{by}**, #{Calendar.strftime(c.inserted_at, "%Y-%m-%d %H:%M")} UTC:\n#{String.trim(c.body || "")}"
      end)
  end

  defp docs([]), do: nil

  defp docs(links),
    do:
      Enum.map_join(links, "\n", fn l ->
        "- #{l.page.code} #{l.page.title}#{if l.pinned, do: " (pinned)"}"
      end)

  defp section(_title, nil), do: nil
  defp section(_title, ""), do: nil
  defp section(title, body), do: "## #{title}\n#{body}"

  defp lines([]), do: "- none"
  defp lines(items), do: Enum.map_join(items, "\n", &("- " <> &1))

  defp blank_or(nil), do: ""
  defp blank_or(text), do: String.trim(text)

  @doc """
  `text` held to the kind's cap. Past it the text is cut and ends with a line
  naming `tool`, which gets the rest.
  """
  def cut(text, kind, tool) do
    max = cap(kind)
    text = String.trim(text) <> "\n"

    if String.length(text) <= max do
      text
    else
      note = "\n\n…cut at the size cap: use #{tool} for the rest.\n"
      String.slice(text, 0, max - String.length(note)) <> note
    end
  end
end
