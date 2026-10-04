defmodule Slipdock.Importers.Trello do
  @moduledoc """
  A Trello board, from the JSON Trello writes under *Menu → Print, export and
  share → Export as JSON*.

  What comes across: the board's name and description, its open lists in
  order, every card on them (archived ones archived), labels as tags,
  checklists, comments, due and start dates, "due complete" as completed, and
  attachments as web links.

  What does not, and the report says so when it applies:

  - **People.** Trello's export names members but carries no email address,
    and an address is the only thing that can match somebody here. Cards come
    in unassigned; who wrote each comment is kept in its text.
  - **Uploaded files.** They are links to Trello, which needs a Trello login to
    open, so they come in as links rather than as attachments.
  - **Archived lists**, and the cards on them: a Slipdock list cannot be put
    away, and dropping a closed list's cards into an open one would bring back
    work somebody finished with.
  - **Custom fields, stickers and power-up data**, which have no single meaning
    to map onto.

  Comments only go back as far as Trello's export does — it holds the most
  recent thousand actions, so an old, busy board loses its oldest comments
  before they ever reach this module.
  """

  @behaviour Slipdock.Importers

  alias Slipdock.Importers

  @impl true
  def key, do: "trello"

  @impl true
  def label, do: "Trello"

  # Trello's board export is a board object with its lists and cards inside
  # it. Lists-and-cards alone would match too much, so it also has to carry
  # one of the things only Trello writes.
  @impl true
  def recognises?(%{"lists" => lists, "cards" => cards} = doc)
      when is_list(lists) and is_list(cards) do
    trello_url?(doc["url"]) or trello_url?(doc["shortUrl"]) or Map.has_key?(doc, "labelNames") or
      Map.has_key?(doc, "idOrganization")
  end

  def recognises?(_), do: false

  defp trello_url?(url) when is_binary(url), do: String.contains?(url, "trello.com")
  defp trello_url?(_), do: false

  @impl true
  def to_portable(%{"lists" => lists, "cards" => cards} = doc)
      when is_list(lists) and is_list(cards) do
    {open_lists, closed_lists} = lists |> by_pos() |> Enum.split_with(&(!&1["closed"]))
    # A card on a closed list (or on no list in the file) has nowhere to go.
    open_ids = ids(open_lists)
    {cards, lost_cards} = Enum.split_with(cards, &MapSet.member?(open_ids, &1["idList"]))

    {tags, tag_refs} = tags(doc["labels"] || [])
    checklists = Enum.group_by(doc["checklists"] || [], & &1["idCard"])
    comments = comments(doc["actions"] || [])

    done_lists =
      open_lists |> Enum.filter(&(Importers.guess_category(&1["name"]) == "done")) |> ids()

    portable_cards =
      cards
      |> Enum.group_by(& &1["idList"])
      |> Enum.flat_map(fn {_list, on_list} ->
        on_list
        |> by_pos()
        |> Enum.with_index()
        |> Enum.map(fn {card, position} ->
          card(card, position, %{
            tags: tag_refs,
            checklists: checklists,
            comments: comments,
            done_lists: done_lists
          })
        end)
      end)

    tree = %{
      root: %{
        ref: "b1",
        name: blank_to_nil(doc["name"]) || "Trello board",
        description: blank_to_nil(doc["desc"]),
        lists:
          open_lists
          |> Enum.with_index()
          |> Enum.map(fn {list, position} ->
            %{
              ref: "l:" <> list["id"],
              name: blank_to_nil(list["name"]) || "List #{position + 1}",
              position: position,
              category: Importers.guess_category(list["name"])
            }
          end)
      },
      boards: [],
      cards: portable_cards,
      tags: tags
    }

    document = %{slipdock_portable: Slipdock.Portable.format_version(), boards: [tree]}
    {:ok, document, notes(doc, cards, closed_lists, lost_cards)}
  end

  def to_portable(_), do: {:error, :not_a_trello_export}

  ## Cards -----------------------------------------------------------------------

  defp card(card, position, ctx) do
    %{
      ref: "c:" <> card["id"],
      board: "b1",
      list: "l:" <> card["idList"],
      title: blank_to_nil(card["name"]) || "Untitled",
      description: blank_to_nil(card["desc"]),
      position: position,
      start_date: Importers.iso_date(card["start"]),
      due_date: Importers.iso_date(card["due"]),
      completed: card["dueComplete"] == true or MapSet.member?(ctx.done_lists, card["idList"]),
      archived: card["closed"] == true,
      tags:
        (card["idLabels"] || [])
        |> Enum.map(&ctx.tags[&1])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq(),
      checklist: checklist(Map.get(ctx.checklists, card["id"], [])),
      comments: Map.get(ctx.comments, card["id"], []),
      urls: urls(card["attachments"] || [])
    }
  end

  # Slipdock has one checklist per card and Trello has any number, so several
  # are laid end to end, each item saying which list it came from. One
  # checklist keeps its items exactly as they were.
  defp checklist([]), do: []

  defp checklist([single]), do: items(single, nil)

  defp checklist(many) do
    many |> by_pos() |> Enum.flat_map(&items(&1, blank_to_nil(&1["name"])))
  end

  defp items(checklist, prefix) do
    (checklist["checkItems"] || [])
    |> by_pos()
    |> Enum.map(fn item ->
      text = item["name"] || ""
      %{text: if(prefix, do: "#{prefix}: #{text}", else: text), done: item["state"] == "complete"}
    end)
  end

  # A Slipdock comment has no author and is dated when it is written, so who
  # said it and when go into the text — otherwise every comment on an imported
  # board would read as the importer's, today.
  defp comments(actions) do
    actions
    |> Enum.filter(&(&1["type"] == "commentCard"))
    |> Enum.sort_by(&(&1["date"] || ""))
    |> Enum.reduce(%{}, fn action, acc ->
      case get_in(action, ["data", "card", "id"]) do
        nil ->
          acc

        card_id ->
          body = byline(action) <> "\n\n" <> (get_in(action, ["data", "text"]) || "")
          Map.update(acc, card_id, [%{body: body}], &(&1 ++ [%{body: body}]))
      end
    end)
  end

  defp byline(action) do
    who =
      get_in(action, ["memberCreator", "fullName"]) ||
        get_in(action, ["memberCreator", "username"]) || "Somebody"

    case Importers.iso_date(action["date"]) do
      nil -> "*#{who}, on Trello*"
      date -> "*#{who}, on Trello, #{date}*"
    end
  end

  defp urls(attachments) do
    attachments
    |> Enum.filter(&is_binary(&1["url"]))
    |> Enum.map(&%{url: &1["url"], title: blank_to_nil(&1["name"])})
  end

  ## Labels ----------------------------------------------------------------------

  # A Trello label may have no name (colour is the whole point of some), and
  # two may share one; a Slipdock tag needs a name that is unique on the board
  # and at most 30 characters. So unnamed labels are named after their colour,
  # and labels that end up with the same name become one tag.
  defp tags(labels) do
    {tags, refs} =
      Enum.reduce(labels, {[], %{}}, fn label, {tags, refs} ->
        name = label |> label_name() |> String.slice(0, 30)
        ref = "t:" <> String.downcase(name)

        tags =
          if Enum.any?(tags, &(&1.ref == ref)),
            do: tags,
            else: tags ++ [%{ref: ref, name: name, color: colour(label["color"])}]

        {tags, Map.put(refs, label["id"], ref)}
      end)

    {tags, refs}
  end

  defp label_name(label) do
    blank_to_nil(label["name"]) ||
      (label["color"] && String.capitalize(String.replace(label["color"], "_", " "))) ||
      "Label"
  end

  # Trello's colours, light and dark shades included, onto this palette.
  defp colour(nil), do: "slate"

  defp colour(colour) when is_binary(colour) do
    case colour |> String.split("_") |> hd() do
      "green" -> "emerald"
      "yellow" -> "amber"
      "orange" -> "orange"
      "red" -> "red"
      "purple" -> "violet"
      "blue" -> "indigo"
      "sky" -> "sky"
      "lime" -> "lime"
      "pink" -> "fuchsia"
      _ -> "slate"
    end
  end

  ## What could not come -----------------------------------------------------------

  defp notes(doc, cards, closed_lists, lost_cards) do
    [
      closed_lists != [] &&
        "#{count(closed_lists, "archived list")} on Trello stayed behind, with the " <>
          "#{count(lost_cards, "card")} on them.",
      Enum.any?(cards, &((&1["idMembers"] || []) != [])) &&
        "Trello's export has no email addresses, so its members couldn't be matched to " <>
          "anybody here and every card came in unassigned.",
      Enum.any?(cards, &Enum.any?(&1["attachments"] || [], fn a -> a["isUpload"] end)) &&
        "Files uploaded to Trello came in as links to Trello; opening them needs a Trello login.",
      (doc["customFields"] || []) != [] &&
        "Trello custom fields were left out."
    ]
    |> Enum.filter(&is_binary/1)
  end

  ## Small things ----------------------------------------------------------------

  # Trello orders by `pos`, a number with gaps in it; the gaps mean nothing.
  defp by_pos(items), do: Enum.sort_by(items, &(&1["pos"] || 0))

  defp ids(items), do: MapSet.new(items, & &1["id"])

  defp count([_], noun), do: "1 #{noun}"
  defp count(items, noun), do: "#{length(items)} #{noun}s"

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil
end
